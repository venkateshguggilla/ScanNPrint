import AppKit
import Observation
import UniformTypeIdentifiers

enum AppMode: String, CaseIterable, Identifiable {
    case scans = "Scans"
    case compose = "Compose"

    var id: Self { self }
}

/// The area selected on a scan: a rectangle in scan pixels, turned by `straighten` degrees about its centre.
struct Selection: Equatable {
    var rect: CGRect
    var straighten: Double = 0

    var tilted: TiltedRect {
        TiltedRect(centerX: rect.midX, centerY: rect.midY, width: rect.width, height: rect.height, angleDegrees: straighten)
    }

    init(rect: CGRect, straighten: Double = 0) {
        self.rect = rect
        self.straighten = straighten
    }

    init(_ t: TiltedRect) {
        rect = CGRect(centerX: t.centerX, centerY: t.centerY, width: t.width, height: t.height)
        straighten = t.angleDegrees
    }
}

enum PrintSize: String, CaseIterable, Identifiable {
    case fit = "Fit to page"
    case actual = "Actual size"

    var id: Self { self }
}

@Observable
final class AppModel {
    static let shared = AppModel()

    static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
    static let margin = 5.0
    static let gap = 3.0

    let scanner = ScannerService()

    // Devices and scan settings, remembered between launches.
    var printers: [String] = []
    var printerName: String? { didSet { defaults.set(printerName, forKey: "printer") } }
    var scanSource: ScanSource { didSet { defaults.set(scanSource.rawValue, forKey: "source") } }
    var dpi: Int { didSet { defaults.set(dpi, forKey: "dpi") } }
    var colorMode: ColorMode { didSet { defaults.set(colorMode.rawValue, forKey: "color") } }
    var scanAreaName: String { didSet { defaults.set(scanAreaName, forKey: "scanArea") } }
    var printSize: PrintSize { didSet { defaults.set(printSize.rawValue, forKey: "printSize") } }

    var mode: AppMode = .scans

    // Scans. Hidden ones were removed from the list but are still used on an output page.
    private(set) var allScans: [ScannedPage] = []
    var selectedScanID: String?
    private(set) var selections: [String: Selection] = [:]

    // Composer.
    private(set) var history: History<Composition>
    var pageIndex = 0
    var selectedClipID: UUID?
    var newPagePaper: PaperSize { didSet { defaults.set(newPagePaper.name, forKey: "paper") } }
    var newPageLandscape: Bool { didSet { defaults.set(newPageLandscape, forKey: "landscape") } }
    private(set) var isDetecting = false

    // Project.
    private(set) var projectURL: URL?
    private(set) var isDirty = false
    var status = ""
    private(set) var lastSaved: [URL] = []

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored let sessionDirectory: URL
    @ObservationIgnored private var scanCounter = 0

    private init() {
        sessionDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScanNPrint-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let d = UserDefaults.standard
        printerName = d.string(forKey: "printer")
        scanSource = ScanSource(rawValue: d.string(forKey: "source") ?? "") ?? .flatbed
        dpi = d.object(forKey: "dpi") as? Int ?? 300
        colorMode = ColorMode(rawValue: d.string(forKey: "color") ?? "") ?? .color
        scanAreaName = d.string(forKey: "scanArea") ?? ""
        printSize = PrintSize(rawValue: d.string(forKey: "printSize") ?? "") ?? .fit
        let paper = PaperSize.named(d.string(forKey: "paper") ?? "") ?? .a4
        let landscape = d.bool(forKey: "landscape")
        newPagePaper = paper
        newPageLandscape = landscape
        history = History(.create(paper, landscape: landscape))
    }

    // MARK: - Lifecycle

    func start() {
        let incoming = sessionDirectory.appendingPathComponent("incoming", isDirectory: true)
        try? FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        scanner.downloadsDirectory = incoming
        refreshDevices()
    }

    func refreshDevices() {
        scanner.start(preferring: defaults.string(forKey: "scanner"))
        printers = NSPrinter.printerNames
        if printerName.map({ !printers.contains($0) }) ?? true {
            printerName = NSPrintInfo.defaultPrinter?.name ?? printers.first
        }
    }

    func cleanUp() { try? FileManager.default.removeItem(at: sessionDirectory) }

    var windowTitle: String {
        let name = projectURL?.deletingPathExtension().lastPathComponent ?? "ScanNPrint"
        return name
    }

    // MARK: - Scanning

    var scans: [ScannedPage] { allScans.filter(\.inScanList) }
    var scansByID: [String: ScannedPage] { Dictionary(uniqueKeysWithValues: allScans.map { ($0.id, $0) }) }

    var selectedScan: ScannedPage? {
        scans.first { $0.id == selectedScanID } ?? scans.first
    }

    var resolutionOptions: [Int] {
        let r = scanner.resolutions.isEmpty ? [150, 200, 300, 600] : scanner.resolutions
        return r.contains(dpi) ? r : (r + [dpi]).sorted()
    }

    var sourceOptions: [ScanSource] {
        scanner.sources.isEmpty ? [.flatbed] : scanner.sources
    }

    func selectScanner(named name: String) {
        guard let s = scanner.scanners.first(where: { $0.name == name }) else { return }
        defaults.set(name, forKey: "scanner")
        scanner.select(s)
    }

    func scan() {
        if !sourceOptions.contains(scanSource) { scanSource = sourceOptions[0] }
        let area = PaperSize.named(scanAreaName).map { CGSize(width: $0.widthMm, height: $0.heightMm) }
        let request = ScanRequest(source: scanSource, dpi: dpi, colorMode: colorMode,
                                  areaMm: scanSource == .flatbed ? area : nil)
        scanner.scan(request, onPage: { [weak self] url, dpi in
            guard let self else { return }
            let info = ImageFile.info(url)
            let fileDPI = info?.dpi.flatMap { $0 >= 50 ? $0 : nil } ?? dpi
            if let page = self.addScan(from: url, dpi: fileDPI, move: true) { self.selectedScanID = page.id }
        }, onDone: { [weak self] error in
            if let error { self?.status = "Scan failed: \(error.localizedDescription)" }
        })
    }

    /// Imports image files as scans. Files without a usable resolution are taken as 300 dpi.
    func importImages(_ urls: [URL]) {
        var added: ScannedPage?
        var failed = 0
        for url in urls {
            if url.pathExtension.lowercased() == "pdf" {
                for page in PDFImporter.render(url, dpi: 300, into: sessionDirectory) {
                    added = addScan(from: page, dpi: 300, move: true) ?? added
                }
                continue
            }
            guard let info = ImageFile.info(url) else { failed += 1; continue }
            let dpi = info.dpi.flatMap { $0 >= 100 ? $0 : nil } ?? 300
            if let page = addScan(from: url, dpi: dpi, move: false) { added = page } else { failed += 1 }
        }
        if let added { selectedScanID = added.id }
        status = failed > 0 ? "\(failed) file\(failed == 1 ? "" : "s") couldn't be opened as images." : ""
    }

    /// Adds an image as a scan, storing it as a PNG in the session folder.
    @discardableResult
    private func addScan(from url: URL, dpi: Double, move: Bool) -> ScannedPage? {
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let target = sessionDirectory.appendingPathComponent(id + ".png")
        do {
            if url.pathExtension.lowercased() == "png", ImageFile.info(url)?.orientation == 1 {
                if move { try FileManager.default.moveItem(at: url, to: target) } else { try FileManager.default.copyItem(at: url, to: target) }
            } else {
                guard let image = ImageFile.loadUpright(url) else { return nil }
                try ImageFile.write([image], to: target, type: .png, dpi: dpi)
                if move { try? FileManager.default.removeItem(at: url) }
            }
        } catch {
            status = error.localizedDescription
            return nil
        }
        scanCounter += 1
        guard let page = ScannedPage(id: id, url: target, dpi: dpi, number: scanCounter) else { return nil }
        allScans.append(page)
        isDirty = true
        return page
    }

    func deleteScan(_ id: String) {
        guard let i = allScans.firstIndex(where: { $0.id == id }) else { return }
        let next = scans.firstIndex { $0.id == id }.flatMap { idx in scans.indices.contains(idx + 1) ? scans[idx + 1].id : (idx > 0 ? scans[idx - 1].id : nil) }
        if composition.usesSource(id) {
            allScans[i].inScanList = false // still printed from; keep the image
        } else {
            try? FileManager.default.removeItem(at: allScans[i].url)
            allScans.remove(at: i)
            selections[id] = nil
        }
        if selectedScanID == id || selectedScanID == nil { selectedScanID = next }
        isDirty = true
    }

    // MARK: - Selecting areas

    func selection(for scan: ScannedPage) -> Selection {
        selections[scan.id] ?? Selection(rect: CGRect(origin: .zero, size: scan.pixelSize))
    }

    var currentSelection: Selection? { selectedScan.map(selection(for:)) }

    func setSelection(_ selection: Selection, for scanID: String) {
        guard selections[scanID] != selection else { return }
        selections[scanID] = selection
    }

    func setStraighten(_ degrees: Double) {
        guard let scan = selectedScan, degrees.isFinite else { return }
        var s = selection(for: scan)
        s.straighten = min(max(degrees, -Clip.maxStraightenDegrees), Clip.maxStraightenDegrees)
        setSelection(s, for: scan.id)
    }

    func selectWholePage() {
        guard let scan = selectedScan else { return }
        setSelection(Selection(rect: CGRect(origin: .zero, size: scan.pixelSize)), for: scan.id)
    }

    func autoDetect() {
        guard let scan = selectedScan, !isDetecting else { return }
        isDetecting = true
        status = "Looking for the content…"
        Task.detached(priority: .userInitiated) {
            let found = ContentDetector.find(in: scan, straighten: true)
            await MainActor.run {
                self.isDetecting = false
                if let found {
                    self.setSelection(Selection(found), for: scan.id)
                    self.status = found.angleDegrees == 0 ? "Found the content; it's straight."
                        : "Found the content, turned \(Self.formatAngle(found.angleDegrees)). Placing it will straighten it."
                } else {
                    self.status = "Couldn't find anything on the scan apart from the background."
                }
            }
        }
    }

    static func formatAngle(_ degrees: Double) -> String {
        let s = String(format: "%.2f", degrees).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
        return s + "°"
    }

    func selectionDescription(for scan: ScannedPage) -> String {
        let s = selection(for: scan)
        let w = Units.pixelsToMm(s.rect.width, dpi: scan.dpi), h = Units.pixelsToMm(s.rect.height, dpi: scan.dpi)
        var text = "\(Units.format(w)) × \(Units.format(h)) mm"
        if s.straighten != 0 { text += " · turned \(Self.formatAngle(s.straighten))" }
        return text
    }

    // MARK: - Composer

    var composition: Composition { history.current }
    var currentPage: ComposedPage { composition.pages[min(pageIndex, composition.pages.count - 1)] }
    var selectedClip: Clip? { selectedClipID.flatMap(currentPage.find) }
    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    private func apply(_ c: Composition) {
        guard c != composition else { return }
        history.apply(c)
        isDirty = true
        pageIndex = min(pageIndex, composition.pages.count - 1)
    }

    private func updateCurrentPage(_ change: (inout ComposedPage) -> Void) {
        var c = composition
        change(&c.pages[min(pageIndex, c.pages.count - 1)])
        apply(c)
    }

    /// Puts the selected area on the current page at actual size (smaller if it doesn't fit), in the first free spot.
    func place() {
        guard let scan = selectedScan else { return }
        let s = selection(for: scan)
        var crop = PixelRect(s.rect)
        if s.straighten == 0 { crop = crop.clamped(width: scan.pixelWidth, height: scan.pixelHeight) }
        var clip = Clip.create(sourceID: scan.id, crop: crop, straighten: s.straighten, dpi: scan.dpi, centerX: 0, centerY: 0)
        let page = currentPage
        let areaW = page.widthMm - 2 * Self.margin, areaH = page.heightMm - 2 * Self.margin
        if clip.width > areaW || clip.height > areaH {
            clip = clip.withScale(min(areaW / clip.width, areaH / clip.height))
        }
        if let spot = AutoPlacement.findFreeSpot(on: page, width: clip.width, height: clip.height, margin: Self.margin, gap: Self.gap) {
            clip = clip.movedTo(x: spot.midX, y: spot.midY)
        } else {
            clip = clip.movedTo(x: page.widthMm / 2, y: page.heightMm / 2)
            status = "There's no free space left, so it was placed in the middle. Drag it where you want it."
        }
        updateCurrentPage { $0.clips.append(clip) }
        selectedClipID = clip.id
    }

    func commit(_ clip: Clip) { updateCurrentPage { $0 = $0.with(clip) } }

    func deleteSelectedClip() {
        guard let id = selectedClipID else { return }
        updateCurrentPage { $0 = $0.without(id) }
        selectedClipID = nil
    }

    func rotateSelected(by degrees: Double) {
        guard let clip = selectedClip else { return }
        commit(clip.rotatedBy(degrees))
    }

    func setSelectedScale(_ scale: Double) {
        guard let clip = selectedClip, scale.isFinite, scale > 0.01 else { return }
        commit(clip.withScale(min(scale, 20)))
    }

    func bringToFront() {
        guard let id = selectedClipID else { return }
        updateCurrentPage { $0 = $0.bringingToFront(id) }
    }

    func sendToBack() {
        guard let id = selectedClipID else { return }
        updateCurrentPage { $0 = $0.sendingToBack(id) }
    }

    func setPaper(_ paper: PaperSize, landscape: Bool) {
        newPagePaper = paper
        newPageLandscape = landscape
        let w = landscape ? paper.heightMm : paper.widthMm, h = landscape ? paper.widthMm : paper.heightMm
        updateCurrentPage {
            $0.widthMm = w
            $0.heightMm = h
        }
    }

    func addPage() {
        var c = composition
        let page = currentPage
        c.pages.insert(ComposedPage(widthMm: page.widthMm, heightMm: page.heightMm), at: pageIndex + 1)
        apply(c)
        pageIndex += 1
        selectedClipID = nil
    }

    func deletePage() {
        var c = composition
        if c.pages.count == 1 {
            c.pages[0].clips = []
        } else {
            c.pages.remove(at: pageIndex)
        }
        apply(c)
        pageIndex = min(pageIndex, composition.pages.count - 1)
        selectedClipID = nil
    }

    func goToPage(_ index: Int) {
        pageIndex = min(max(index, 0), composition.pages.count - 1)
        selectedClipID = nil
    }

    func undo() {
        history.undo()
        afterHistoryJump()
    }

    func redo() {
        history.redo()
        afterHistoryJump()
    }

    private func afterHistoryJump() {
        isDirty = true
        pageIndex = min(pageIndex, composition.pages.count - 1)
        if let id = selectedClipID, currentPage.find(id) == nil { selectedClipID = nil }
    }

    // MARK: - Saving, exporting and printing

    func exportComposition() {
        guard let (url, format) = Dialogs.saveExport(title: "Export Output Pages", name: exportBaseName) else { return }
        do {
            lastSaved = try Exporter.export(composition, scans: scansByID, format: format, to: url)
            status = lastSaved.count == 1 ? "Saved \(lastSaved[0].lastPathComponent)." : "Saved \(lastSaved.count) files."
        } catch {
            Dialogs.showError("The pages couldn't be saved.", error)
        }
    }

    func exportScans(_ pages: [ScannedPage]) {
        guard !pages.isEmpty else { return }
        let name = pages.count == 1 ? pages[0].name : "Scans"
        guard let (url, format) = Dialogs.saveExport(title: "Save Scans", name: name) else { return }
        do {
            lastSaved = try Exporter.export(pages, format: format, to: url)
            status = lastSaved.count == 1 ? "Saved \(lastSaved[0].lastPathComponent)." : "Saved \(lastSaved.count) files."
        } catch {
            Dialogs.showError("The scans couldn't be saved.", error)
        }
    }

    func revealLastSaved() {
        NSWorkspace.shared.activateFileViewerSelecting(lastSaved)
    }

    private var exportBaseName: String {
        projectURL?.deletingPathExtension().lastPathComponent ?? "Output"
    }

    func printComposition() {
        let images = ClipImageSource(scans: scansByID)
        let pages = composition.pages.map { page in
            PrintPage(sizeMm: page.size, fitToPaper: false) { ctx in
                ClipRenderer.drawPage(page, in: ctx, image: images.image(for:))
            }
        }
        PrintController.run(pages, title: exportBaseName, printerName: printerName, in: NSApp.keyWindow)
    }

    func printScans(_ list: [ScannedPage]) {
        let fit = printSize == .fit
        let pages = list.map { scan in
            PrintPage(sizeMm: CGSize(width: scan.widthMm, height: scan.heightMm), fitToPaper: fit) { ctx in
                if let img = scan.loadFullImage() {
                    ctx.interpolationQuality = .high
                    ImageFile.drawYDown(img, in: CGRect(x: 0, y: 0, width: scan.widthMm, height: scan.heightMm), context: ctx)
                }
            }
        }
        PrintController.run(pages, title: list.count == 1 ? list[0].name : "Scans", printerName: printerName, in: NSApp.keyWindow)
    }

    /// Print in whichever view is showing.
    func printCurrent() {
        switch mode {
        case .scans: printScans(scans)
        case .compose: printComposition()
        }
    }

    func exportCurrent() {
        switch mode {
        case .scans: exportScans(scans)
        case .compose: exportComposition()
        }
    }

    // MARK: - Projects

    func newProject() {
        guard confirmDiscardChanges() else { return }
        for scan in allScans { try? FileManager.default.removeItem(at: scan.url) }
        allScans = []
        selections = [:]
        selectedScanID = nil
        selectedClipID = nil
        history.reset(.create(newPagePaper, landscape: newPageLandscape))
        pageIndex = 0
        projectURL = nil
        isDirty = false
        scanCounter = 0
        status = ""
    }

    func openProject() {
        guard confirmDiscardChanges(), let url = Dialogs.openProject() else { return }
        load(url)
    }

    /// Files opened from Finder or dropped on the Dock icon.
    func open(_ urls: [URL]) {
        if let project = urls.first(where: { $0.pathExtension.lowercased() == ProjectFile.fileExtension }) {
            guard project != projectURL || !isDirty, confirmDiscardChanges() else { return }
            load(project)
        }
        let images = urls.filter { $0.pathExtension.lowercased() != ProjectFile.fileExtension }
        if !images.isEmpty {
            importImages(images)
            mode = .scans
        }
    }

    private func load(_ url: URL) {
        let folder = sessionDirectory.appendingPathComponent("project-" + UUID().uuidString, isDirectory: true)
        let project: Project
        do {
            project = try ProjectFile.load(url, imageDirectory: folder)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            Dialogs.showError("“\(url.lastPathComponent)” couldn't be opened.", error)
            return
        }
        for scan in allScans { try? FileManager.default.removeItem(at: scan.url) }
        var loaded: [ScannedPage] = []
        var selections: [String: Selection] = [:]
        for (i, s) in project.scans.enumerated() {
            guard let page = ScannedPage(id: s.id, url: s.imageURL, dpi: Double(s.dpi), number: i + 1, inScanList: s.inScanList) else {
                Dialogs.showError("“\(url.lastPathComponent)” couldn't be opened.", ProjectFormatError(message: "One of its scans is damaged."))
                return
            }
            loaded.append(page)
            if let sel = s.selection { selections[s.id] = Selection(rect: sel.cgRect, straighten: s.selectionStraighten) }
        }
        allScans = loaded
        self.selections = selections
        scanCounter = loaded.count
        selectedScanID = scans.first?.id
        selectedClipID = nil
        history.reset(project.composition)
        pageIndex = 0
        projectURL = url
        isDirty = false
        mode = .compose
        status = "Opened \(url.lastPathComponent)."
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    @discardableResult
    func saveProject() -> Bool {
        guard let url = projectURL else { return saveProjectAs() }
        return write(to: url)
    }

    @discardableResult
    func saveProjectAs() -> Bool {
        guard let url = Dialogs.saveProject(name: projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled") else { return false }
        return write(to: url)
    }

    private func write(to url: URL) -> Bool {
        let used = allScans.filter { $0.inScanList || composition.usesSource($0.id) }
        let project = Project(
            scans: used.map { scan in
                let sel = selections[scan.id]
                return ProjectScan(id: scan.id, imageURL: scan.url, dpi: Int(scan.dpi.rounded()), pixelWidth: scan.pixelWidth,
                                   pixelHeight: scan.pixelHeight, inScanList: scan.inScanList,
                                   selection: sel.map { PixelRect($0.rect) }, selectionStraighten: sel?.straighten ?? 0)
            },
            composition: composition)
        do {
            try ProjectFile.save(project, to: url, createdBy: "ScanNPrint for Mac \(Self.appVersion)")
        } catch {
            Dialogs.showError("The project couldn't be saved.", error)
            return false
        }
        projectURL = url
        isDirty = false
        status = "Saved \(url.lastPathComponent)."
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        return true
    }

    /// True when it's fine to throw away the current work (saved, nothing to lose, or the user said so).
    func confirmDiscardChanges() -> Bool {
        guard isDirty, !(allScans.isEmpty && composition.isEmpty) else { return true }
        switch Dialogs.askToSave(name: projectURL?.lastPathComponent) {
        case .save: return saveProject()
        case .discard: return true
        case .cancel: return false
        }
    }
}
