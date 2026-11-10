import CoreGraphics
import Foundation

/// Turns the pages of a PDF into PNG images, so PDFs can be used like scans.
enum PDFImporter {
    static func render(_ url: URL, dpi: Double, into folder: URL) -> [URL] {
        guard let document = CGPDFDocument(url as CFURL), document.numberOfPages > 0 else { return [] }
        var files: [URL] = []
        for n in 1...document.numberOfPages {
            guard let page = document.page(at: n) else { continue }
            let box = page.getBoxRect(.cropBox)
            let turned = page.rotationAngle % 180 != 0
            let wPt = turned ? box.height : box.width, hPt = turned ? box.width : box.height
            let w = Int((wPt / 72 * dpi).rounded()), h = Int((hPt / 72 * dpi).rounded())
            guard w > 0, h > 0, w * h < 400_000_000,
                  let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { continue }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.interpolationQuality = .high
            ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: w, height: h), rotate: 0, preserveAspectRatio: true))
            ctx.drawPDFPage(page)
            guard let image = ctx.makeImage() else { continue }
            let file = folder.appendingPathComponent("pdf-\(UUID().uuidString).png")
            if (try? ImageFile.write([image], to: file, type: .png, dpi: dpi)) != nil { files.append(file) }
        }
        return files
    }
}
