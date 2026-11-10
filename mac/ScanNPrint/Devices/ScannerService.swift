import Foundation
import ImageCaptureCore
import Observation
import UniformTypeIdentifiers

enum ScanSource: String, CaseIterable, Identifiable {
    case flatbed, feeder, feederDuplex

    var id: Self { self }

    var title: String {
        switch self {
        case .flatbed: "Flatbed"
        case .feeder: "Document feeder"
        case .feederDuplex: "Feeder, both sides"
        }
    }
}

enum ColorMode: String, CaseIterable, Identifiable {
    case color, grayscale, blackAndWhite

    var id: Self { self }

    var title: String {
        switch self {
        case .color: "Color"
        case .grayscale: "Grayscale"
        case .blackAndWhite: "Black & white"
        }
    }
}

struct ScanRequest {
    var source: ScanSource
    var dpi: Int
    var colorMode: ColorMode
    /// Area to scan from the top-left of the glass, in mm; nil for the whole glass.
    var areaMm: CGSize?
}

struct ScanError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Scanners through ImageCaptureCore: USB, network (AirScan/eSCL, Bonjour) and shared scanners,
/// the same ones Image Capture and Preview see. All callbacks arrive on the main thread.
@Observable
final class ScannerService: NSObject {
    private(set) var scanners: [ICScannerDevice] = []
    private(set) var selected: ICScannerDevice?
    private(set) var sources: [ScanSource] = []
    private(set) var resolutions: [Int] = []
    private(set) var isReady = false
    private(set) var isScanning = false
    private(set) var status = "Looking for scanners…"

    @ObservationIgnored var downloadsDirectory = FileManager.default.temporaryDirectory
    @ObservationIgnored private var browser: ICDeviceBrowser?
    @ObservationIgnored private var pending: ScanRequest?
    @ObservationIgnored private var onPage: ((URL, Double) -> Void)?
    @ObservationIgnored private var onDone: ((Error?) -> Void)?
    @ObservationIgnored private var scanDPI = 300.0
    @ObservationIgnored private var pagesReceived = 0
    @ObservationIgnored private var preferredName: String?

    func start(preferring name: String?) {
        preferredName = name
        browser?.stop()
        browser?.delegate = nil
        selected?.requestCloseSession()
        scanners = []
        selected = nil
        sources = []
        isReady = false
        status = "Looking for scanners…"
        let b = ICDeviceBrowser()
        b.delegate = self
        let mask = ICDeviceTypeMask.scanner.rawValue | ICDeviceLocationTypeMask.local.rawValue |
            ICDeviceLocationTypeMask.shared.rawValue | ICDeviceLocationTypeMask.bonjour.rawValue |
            ICDeviceLocationTypeMask.bluetooth.rawValue
        b.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: mask)!
        b.start()
        browser = b
    }

    func select(_ scanner: ICScannerDevice) {
        guard scanner !== selected, !isScanning else { return }
        selected?.requestCloseSession()
        selected = scanner
        isReady = false
        sources = []
        resolutions = []
        status = "Connecting to \(scanner.name ?? "scanner")…"
        scanner.delegate = self
        scanner.requestOpenSession()
    }

    /// Scans; `onPage` gets each page's file and DPI as it arrives, `onDone` is called once at the end.
    func scan(_ request: ScanRequest, onPage: @escaping (URL, Double) -> Void, onDone: @escaping (Error?) -> Void) {
        guard let scanner = selected, isReady else {
            onDone(ScanError(message: scanners.isEmpty ? "No scanner is connected." : "The scanner isn't ready yet."))
            return
        }
        self.onPage = onPage
        self.onDone = onDone
        pagesReceived = 0
        isScanning = true
        status = "Scanning…"
        let wanted: ICScannerFunctionalUnitType = request.source == .flatbed ? .flatbed : .documentFeeder
        let unit: ICScannerFunctionalUnit? = scanner.selectedFunctionalUnit
        if unit?.type == wanted {
            start(request, on: scanner)
        } else {
            pending = request
            scanner.requestSelect(wanted)
        }
    }

    func cancel() {
        pending = nil
        selected?.cancelScan()
        status = "Cancelling…"
    }

    private func start(_ request: ScanRequest, on scanner: ICScannerDevice) {
        let unit = scanner.selectedFunctionalUnit
        unit.measurementUnit = .inches
        let supported = Array(unit.supportedResolutions)
        let dpi = supported.min { abs($0 - request.dpi) < abs($1 - request.dpi) } ?? request.dpi
        unit.resolution = dpi
        scanDPI = Double(dpi)
        switch request.colorMode {
        case .color:
            unit.pixelDataType = .RGB
            unit.bitDepth = .depth8Bits
        case .grayscale:
            unit.pixelDataType = .gray
            unit.bitDepth = .depth8Bits
        case .blackAndWhite:
            unit.pixelDataType = .BW
            unit.bitDepth = .depth1Bit
        }
        let glass = unit.physicalSize
        var size = glass
        if let area = request.areaMm {
            size.width = min(glass.width, area.width / Units.mmPerInch)
            size.height = min(glass.height, area.height / Units.mmPerInch)
        }
        unit.scanArea = NSRect(origin: .zero, size: size)
        if let feeder = unit as? ICScannerFunctionalUnitDocumentFeeder {
            feeder.duplexScanningEnabled = request.source == .feederDuplex && feeder.supportsDuplexScanning
        }
        scanner.transferMode = .fileBased
        scanner.downloadsDirectory = downloadsDirectory
        scanner.documentName = "scan-" + UUID().uuidString.prefix(8)
        scanner.documentUTI = UTType.png.identifier
        scanner.requestScan()
    }

    private func finish(_ error: Error?) {
        guard isScanning else { return }
        isScanning = false
        pending = nil
        let done = onDone
        onPage = nil
        onDone = nil
        if let error {
            status = "Scan failed: \(error.localizedDescription)"
        } else {
            status = pagesReceived == 1 ? "Scanned 1 page." : "Scanned \(pagesReceived) pages."
        }
        done?(error)
    }

    private func describe(_ unit: ICScannerFunctionalUnit) {
        unit.measurementUnit = .inches
        let common = [75, 100, 150, 200, 300, 400, 600, 1200]
        let supported = Set(unit.supportedResolutions)
        let options = common.filter { supported.contains($0) }
        resolutions = options.isEmpty ? Array(supported).filter { $0 <= 1200 }.sorted() : options
        var list: [ScanSource] = []
        let types = selected?.availableFunctionalUnitTypes.map(\.uintValue) ?? []
        if types.contains(ICScannerFunctionalUnitType.flatbed.rawValue) { list.append(.flatbed) }
        if types.contains(ICScannerFunctionalUnitType.documentFeeder.rawValue) {
            list.append(.feeder)
            if let feeder = unit as? ICScannerFunctionalUnitDocumentFeeder, feeder.supportsDuplexScanning { list.append(.feederDuplex) }
            else if sources.contains(.feederDuplex) { list.append(.feederDuplex) }
        }
        sources = list
    }
}

extension ScannerService: ICDeviceBrowserDelegate {
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let scanner = device as? ICScannerDevice, !scanners.contains(where: { $0 === scanner }) else { return }
        scanners.append(scanner)
        if selected == nil || (scanner.name == preferredName && selected?.name != preferredName && !isScanning) {
            select(scanner)
        }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        scanners.removeAll { $0 === device }
        if selected === device {
            finish(ScanError(message: "The scanner was disconnected."))
            selected = nil
            isReady = false
            sources = []
            if let next = scanners.first { select(next) } else { status = "No scanner found." }
        }
    }

    func deviceBrowserDidEnumerateLocalDevices(_ browser: ICDeviceBrowser) {
        if scanners.isEmpty { status = "No scanner found. Connect one, or import images instead." }
    }
}

extension ScannerService: ICScannerDeviceDelegate {
    func didRemove(_ device: ICDevice) {}

    func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        guard let scanner = device as? ICScannerDevice, scanner === selected else { return }
        if let error {
            status = "Couldn't connect to \(scanner.name ?? "the scanner"): \(error.localizedDescription)"
            return
        }
        let types = scanner.availableFunctionalUnitTypes.map(\.uintValue)
        let first: ICScannerFunctionalUnitType = types.contains(ICScannerFunctionalUnitType.flatbed.rawValue)
            ? .flatbed : ICScannerFunctionalUnitType(rawValue: types.first ?? 0) ?? .flatbed
        scanner.requestSelect(first)
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {}

    func device(_ device: ICDevice, didEncounterError error: (any Error)?) {
        guard device === selected else { return }
        if isScanning { finish(error ?? ScanError(message: "The scanner reported an error.")) }
        else if let error { status = error.localizedDescription }
    }

    func scannerDevice(_ scanner: ICScannerDevice, didSelect functionalUnit: ICScannerFunctionalUnit, error: (any Error)?) {
        guard scanner === selected else { return }
        if let error {
            if pending != nil { finish(error) }
            status = error.localizedDescription
            return
        }
        describe(functionalUnit)
        if !isReady {
            isReady = true
            status = "Ready: \(scanner.name ?? "scanner")"
        }
        if let request = pending {
            pending = nil
            start(request, on: scanner)
        }
    }

    func scannerDevice(_ scanner: ICScannerDevice, didScanTo url: URL) {
        pagesReceived += 1
        status = "Scanned \(pagesReceived) page\(pagesReceived == 1 ? "" : "s")…"
        onPage?(url, scanDPI)
    }

    func scannerDevice(_ scanner: ICScannerDevice, didCompleteScanWithError error: (any Error)?) {
        finish(error)
    }
}
