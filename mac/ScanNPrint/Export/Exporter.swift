import CoreGraphics
import Foundation
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable {
    case pdf, png, jpeg, tiff

    var id: Self { self }

    var title: String {
        switch self {
        case .pdf: "PDF"
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .tiff: "TIFF"
        }
    }

    var type: UTType {
        switch self {
        case .pdf: .pdf
        case .png: .png
        case .jpeg: .jpeg
        case .tiff: .tiff
        }
    }

    static func from(_ url: URL) -> ExportFormat {
        switch url.pathExtension.lowercased() {
        case "png": .png
        case "jpg", "jpeg": .jpeg
        case "tif", "tiff": .tiff
        default: .pdf
        }
    }
}

/// Saving output pages and scans. PDF and TIFF hold every page in one file; PNG and JPEG write one file per page.
enum Exporter {
    static let imageDPI = 300.0

    /// Returns the files written.
    static func export(_ composition: Composition, scans: [String: ScannedPage], format: ExportFormat, to url: URL) throws -> [URL] {
        let images = ClipImageSource(scans: scans)
        if format == .pdf {
            try writePDF(to: url, pages: composition.pages.map { page in
                (page.size, { ctx in ClipRenderer.drawPage(page, in: ctx, image: images.image(for:)) })
            })
            return [url]
        }
        let rendered = try composition.pages.map { page -> CGImage in
            let gray = page.clips.allSatisfy { scans[$0.sourceID]?.isGray ?? true } && !page.clips.isEmpty
            let w = Int(Units.mmToPixels(page.widthMm, dpi: imageDPI).rounded())
            let h = Int(Units.mmToPixels(page.heightMm, dpi: imageDPI).rounded())
            guard let ctx = ImageFile.makeContext(width: w, height: h, gray: gray) else {
                throw ExportError(message: "Not enough memory to render the page.")
            }
            ctx.scaleBy(x: Double(w) / page.widthMm, y: Double(h) / page.heightMm)
            ClipRenderer.drawPage(page, in: ctx, image: images.image(for:))
            guard let img = ctx.makeImage() else { throw ExportError(message: "Couldn't render the page.") }
            return img
        }
        return try writeImages(rendered, format: format, to: url, dpi: imageDPI)
    }

    static func export(_ scans: [ScannedPage], format: ExportFormat, to url: URL) throws -> [URL] {
        if format == .pdf {
            try writePDF(to: url, pages: scans.map { scan in
                (CGSize(width: scan.widthMm, height: scan.heightMm), { ctx in
                    if let img = scan.loadFullImage() {
                        ctx.interpolationQuality = .high
                        ImageFile.drawYDown(img, in: CGRect(x: 0, y: 0, width: scan.widthMm, height: scan.heightMm), context: ctx)
                    }
                })
            })
            return [url]
        }
        if format == .png, scans.count == 1, url.pathExtension.lowercased() == "png" {
            // The scan is already a PNG: copy it rather than re-encode.
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.copyItem(at: scans[0].url, to: url)
            return [url]
        }
        let images = scans.compactMap { $0.loadFullImage() }
        let dpi = scans.map(\.dpi).max() ?? imageDPI
        return try writeImages(images, format: format, to: url, dpi: dpi)
    }

    /// Each page is drawn in millimetres with y down.
    static func writePDF(to url: URL, pages: [(size: CGSize, draw: (CGContext) -> Void)]) throws {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box,
                                  [kCGPDFContextCreator: "ScanNPrint"] as CFDictionary) else {
            throw ExportError(message: "Couldn't create \(url.lastPathComponent).")
        }
        for page in pages {
            var media = CGRect(x: 0, y: 0, width: Units.mmToPoints(page.size.width), height: Units.mmToPoints(page.size.height))
            let info = [kCGPDFContextMediaBox: Data(bytes: &media, count: MemoryLayout<CGRect>.size)] as CFDictionary
            ctx.beginPDFPage(info)
            ctx.translateBy(x: 0, y: media.height)
            let k = Units.mmToPoints(1)
            ctx.scaleBy(x: k, y: -k)
            page.draw(ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    private static func writeImages(_ images: [CGImage], format: ExportFormat, to url: URL, dpi: Double) throws -> [URL] {
        if images.count <= 1 || format == .tiff {
            try ImageFile.write(images, to: url, type: format.type, dpi: dpi)
            return [url]
        }
        let base = url.deletingPathExtension()
        return try images.enumerated().map { i, image in
            let file = URL(fileURLWithPath: base.path + "-\(i + 1)").appendingPathExtension(url.pathExtension)
            try ImageFile.write([image], to: file, type: format.type, dpi: dpi)
            return file
        }
    }
}
