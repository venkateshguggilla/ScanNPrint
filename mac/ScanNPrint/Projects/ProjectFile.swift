import Foundation

/// A scan stored in a project. `imageURL` is a PNG on disk.
/// `inScanList` is false for scans removed from the scan list but still used by placed areas.
/// `selection` is the area last selected on this scan in the composer, if any.
struct ProjectScan {
    var id: String
    var imageURL: URL
    var dpi: Int
    var pixelWidth: Int
    var pixelHeight: Int
    var inScanList: Bool
    var selection: PixelRect?
    var selectionStraighten: Double = 0
}

/// Everything needed to carry on later: the scans and the composer layout.
struct Project {
    var scans: [ProjectScan]
    var composition: Composition
}

/// A project file that can't be opened; the message is fit to show the user.
struct ProjectFormatError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Reads and writes ScanNPrint project files (.snp): a zip holding `project.json` and the original scans as
/// `scans/<id>.png`. The format is shared with the Windows app, so projects open on either.
enum ProjectFile {
    static let fileExtension = "snp"
    /// The newest version this app reads. Files are written as version 1 unless something is straightened.
    static let formatVersion = 2

    private static let formatName = "scannprint-project"
    private static let manifestEntry = "project.json"
    private static let maxImageBytes = 1 << 30 // 1 GiB: far beyond a 1200 dpi A3 scan

    /// Writes `project` to `url`, replacing it only once fully written.
    static func save(_ project: Project, to url: URL, createdBy: String) throws {
        for scan in project.scans { try validate(id: scan.id) }
        let straightened = project.scans.contains { $0.selectionStraighten != 0 } ||
            project.composition.pages.contains { $0.clips.contains { $0.straightenDegrees != 0 } }

        let manifest = Manifest(
            format: formatName,
            formatVersion: straightened ? 2 : 1,
            createdBy: createdBy,
            scans: project.scans.map {
                ScanDTO(id: $0.id, dpi: $0.dpi, pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight,
                        inScanList: $0.inScanList, selection: $0.selection.map(RectDTO.init),
                        selectionStraighten: $0.selectionStraighten != 0 ? $0.selectionStraighten : nil)
            },
            pages: project.composition.pages.map { page in
                PageDTO(widthMm: page.widthMm, heightMm: page.heightMm, clips: page.clips.map {
                    ClipDTO(scanId: $0.sourceID, crop: RectDTO($0.crop), centerXMm: $0.centerX, centerYMm: $0.centerY,
                            widthMm: $0.width, heightMm: $0.height, naturalWidthMm: $0.naturalWidth,
                            naturalHeightMm: $0.naturalHeight, rotationDegrees: $0.rotationDegrees,
                            straightenDegrees: $0.straightenDegrees != 0 ? $0.straightenDegrees : nil)
                })
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let json = try encoder.encode(manifest)

        let temp = url.appendingPathExtension("partial")
        let fm = FileManager.default
        try? fm.removeItem(at: temp)
        do {
            let zip = try ZipWriter(url: temp)
            try zip.add(name: manifestEntry, data: json, compress: true)
            // PNGs are already compressed; storing them is much faster and barely larger.
            for scan in project.scans {
                try zip.add(name: imageEntry(scan.id), data: Data(contentsOf: scan.imageURL, options: .mappedIfSafe), compress: false)
            }
            try zip.finish()
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: url)
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    /// Opens a project, extracting its scans into `imageDirectory` under fresh file names.
    static func load(_ url: URL, imageDirectory: URL) throws -> Project {
        let zip: ZipReader
        do {
            zip = try ZipReader(url: url)
        } catch {
            throw ProjectFormatError(message: "This file is damaged or isn't a ScanNPrint project.")
        }
        guard let manifestZipEntry = zip.entries[manifestEntry] else {
            throw ProjectFormatError(message: "This file isn't a ScanNPrint project.")
        }
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: zip.read(manifestZipEntry))
        } catch {
            throw ProjectFormatError(message: "This project's contents are damaged and can't be read.")
        }
        guard manifest.format == formatName else { throw ProjectFormatError(message: "This file isn't a ScanNPrint project.") }
        if (manifest.formatVersion ?? 1) > formatVersion {
            throw ProjectFormatError(message: "This project was made with a newer version of ScanNPrint. Update the app to open it.")
        }

        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        var scans: [ProjectScan] = []
        for dto in manifest.scans ?? [] {
            guard let id = dto.id else { throw ProjectFormatError(message: "The project has a scan with an invalid id.") }
            try validate(id: id)
            if scans.contains(where: { $0.id == id }) {
                throw ProjectFormatError(message: "The project lists the same scan twice (\(id)).")
            }
            guard let dpi = dto.dpi, let w = dto.pixelWidth, let h = dto.pixelHeight, dpi > 0, w > 0, h > 0 else {
                throw ProjectFormatError(message: "The project has a scan with an invalid size (\(id)).")
            }
            guard let entry = zip.entries[imageEntry(id)] else {
                throw ProjectFormatError(message: "The project is missing one of its scans (\(id)).")
            }
            guard entry.size <= maxImageBytes else {
                throw ProjectFormatError(message: "The project contains a scan that is too large to open.")
            }
            let target = imageDirectory.appendingPathComponent(UUID().uuidString + ".png")
            do {
                try zip.read(entry).write(to: target)
            } catch {
                throw ProjectFormatError(message: "This file is damaged or isn't a ScanNPrint project.")
            }
            let straighten = clampStraighten(dto.selectionStraighten)
            let selection = dto.selection.map { fit($0.pixelRect, straighten: straighten, width: w, height: h) }
            scans.append(ProjectScan(id: id, imageURL: target, dpi: dpi, pixelWidth: w, pixelHeight: h,
                                     inScanList: dto.inScanList ?? true, selection: selection,
                                     selectionStraighten: selection == nil ? 0 : straighten))
        }

        let known = Dictionary(uniqueKeysWithValues: scans.map { ($0.id, $0) })
        let pages: [ComposedPage] = (manifest.pages ?? []).compactMap { p in
            guard let w = p.widthMm, let h = p.heightMm, w.isFinite, h.isFinite, w > 0, h > 0 else { return nil }
            let clips = (p.clips ?? []).compactMap { clip(from: $0, scans: known) }
            return ComposedPage(widthMm: w, heightMm: h, clips: clips)
        }
        guard !pages.isEmpty else { throw ProjectFormatError(message: "The project has no output pages.") }
        return Project(scans: scans, composition: Composition(pages: pages))
    }

    private static func clip(from c: ClipDTO, scans: [String: ProjectScan]) -> Clip? {
        guard let scanID = c.scanId, let scan = scans[scanID], let crop = c.crop, crop.width > 0, crop.height > 0,
              let cx = c.centerXMm, let cy = c.centerYMm, let w = c.widthMm, let h = c.heightMm,
              let nw = c.naturalWidthMm, let nh = c.naturalHeightMm else { return nil }
        let rotation = c.rotationDegrees ?? 0
        guard [cx, cy, w, h, nw, nh, rotation].allSatisfy(\.isFinite), w > 0, h > 0, nw > 0, nh > 0 else { return nil }
        let straighten = clampStraighten(c.straightenDegrees)
        return Clip(sourceID: scanID, crop: fit(crop.pixelRect, straighten: straighten, width: scan.pixelWidth, height: scan.pixelHeight),
                    straightenDegrees: straighten, centerX: cx, centerY: cy, width: w, height: h,
                    naturalWidth: nw, naturalHeight: nh, rotationDegrees: Clip.normalizeDegrees(rotation))
    }

    /// Unturned crops stay inside the image. A turned crop may reach past it, but its centre stays on the
    /// image and its size is capped at the image's diagonal.
    private static func fit(_ r: PixelRect, straighten: Double, width: Int, height: Int) -> PixelRect {
        if straighten == 0 { return r.clamped(width: width, height: height) }
        let diagonal = Int((Double(width * width + height * height)).squareRoot().rounded(.up))
        let w = min(r.width, diagonal), h = min(r.height, diagonal)
        let cx = min(max(r.centerX, 0), Double(width)), cy = min(max(r.centerY, 0), Double(height))
        return PixelRect(CGRect(centerX: cx, centerY: cy, width: Double(w), height: Double(h)))
    }

    private static func clampStraighten(_ degrees: Double?) -> Double {
        guard let d = degrees, d.isFinite else { return 0 }
        return min(max(d, -Clip.maxStraightenDegrees), Clip.maxStraightenDegrees)
    }

    private static func imageEntry(_ scanID: String) -> String { "scans/\(scanID).png" }

    /// Ids become entry names, so only allow plain characters (no paths).
    private static func validate(id: String) throws {
        let ok = (1...64).contains(id.count) && id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "_" || $0 == "-"
        }
        if !ok { throw ProjectFormatError(message: "The project has a scan with an invalid id.") }
    }

    // On-disk shape of project.json, kept apart from the model so the file format stays stable.
    // Every field is optional so damaged files fail with a clear message instead of a decoding error.
    private struct Manifest: Codable {
        var format: String?
        var formatVersion: Int?
        var createdBy: String?
        var scans: [ScanDTO]?
        var pages: [PageDTO]?
    }

    private struct ScanDTO: Codable {
        var id: String?
        var dpi: Int?
        var pixelWidth: Int?
        var pixelHeight: Int?
        var inScanList: Bool?
        var selection: RectDTO?
        var selectionStraighten: Double?
    }

    private struct PageDTO: Codable {
        var widthMm: Double?
        var heightMm: Double?
        var clips: [ClipDTO]?
    }

    private struct ClipDTO: Codable {
        var scanId: String?
        var crop: RectDTO?
        var centerXMm: Double?
        var centerYMm: Double?
        var widthMm: Double?
        var heightMm: Double?
        var naturalWidthMm: Double?
        var naturalHeightMm: Double?
        var rotationDegrees: Double?
        var straightenDegrees: Double?
    }

    private struct RectDTO: Codable {
        var x: Int
        var y: Int
        var width: Int
        var height: Int

        init(_ r: PixelRect) {
            x = r.x
            y = r.y
            width = r.width
            height = r.height
        }

        var pixelRect: PixelRect { PixelRect(x: x, y: y, width: width, height: height) }
    }
}
