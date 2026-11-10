import CoreGraphics
import Foundation

/// Cutting clips out of scans and drawing composed pages.
enum ClipRenderer {
    /// The crop, turned by `straighten` degrees about its centre on the scan, as an upright image.
    /// `scale` is image pixels per scan pixel (1 for the full scan, less for a preview). Parts outside the scan are white.
    static func extract(from image: CGImage, scale: Double, crop: PixelRect, straighten: Double, gray: Bool) -> CGImage? {
        if straighten == 0 {
            // A plain crop keeps the original pixels untouched.
            let r = CGRect(x: Double(crop.x) * scale, y: Double(crop.y) * scale,
                           width: Double(crop.width) * scale, height: Double(crop.height) * scale).integral
            if let cropped = image.cropping(to: r) { return cropped }
        }
        let outW = max(1, Int((Double(crop.width) * scale).rounded()))
        let outH = max(1, Int((Double(crop.height) * scale).rounded()))
        guard let ctx = ImageFile.makeContext(width: outW, height: outH, gray: gray) else { return nil }
        ctx.scaleBy(x: Double(outW) / Double(crop.width), y: Double(outH) / Double(crop.height))
        ctx.translateBy(x: Double(crop.width) / 2, y: Double(crop.height) / 2)
        ctx.rotate(by: -straighten * .pi / 180)
        ctx.translateBy(x: -crop.centerX, y: -crop.centerY)
        ImageFile.drawYDown(image, in: CGRect(x: 0, y: 0, width: Double(image.width) / scale, height: Double(image.height) / scale), context: ctx)
        return ctx.makeImage()
    }

    /// Draws an upright clip image into its place on a page. The context's units are millimetres, y down.
    static func draw(_ clip: Clip, image: CGImage, in ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: clip.centerX, y: clip.centerY)
        ctx.rotate(by: clip.rotationDegrees * .pi / 180)
        ImageFile.drawYDown(image, in: CGRect(x: -clip.width / 2, y: -clip.height / 2, width: clip.width, height: clip.height), context: ctx)
        ctx.restoreGState()
    }

    /// Draws a whole page (white paper, clips back to front). The context's units are millimetres, y down.
    static func drawPage(_ page: ComposedPage, in ctx: CGContext, image: (Clip) -> CGImage?) {
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: page.widthMm, height: page.heightMm))
        ctx.interpolationQuality = .high
        for clip in page.clips {
            if let img = image(clip) { draw(clip, image: img, in: ctx) }
        }
    }
}

/// Full-resolution clip images for printing and exporting, decoding each scan once.
final class ClipImageSource {
    private let scans: [String: ScannedPage]
    private var full: [String: CGImage] = [:]
    private var clips: [String: CGImage] = [:]

    init(scans: [String: ScannedPage]) { self.scans = scans }

    func image(for clip: Clip) -> CGImage? {
        let key = "\(clip.sourceID)|\(clip.crop)|\(clip.straightenDegrees)"
        if let cached = clips[key] { return cached }
        guard let scan = scans[clip.sourceID] else { return nil }
        if full[scan.id] == nil { full[scan.id] = scan.loadFullImage() }
        guard let source = full[scan.id] else { return nil }
        let img = ClipRenderer.extract(from: source, scale: Double(source.width) / Double(scan.pixelWidth), crop: clip.crop,
                                       straighten: clip.straightenDegrees, gray: ImageFile.isGray(source))
        clips[key] = img
        return img
    }
}
