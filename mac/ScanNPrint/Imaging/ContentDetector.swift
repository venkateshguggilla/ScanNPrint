import CoreGraphics
import Foundation

/// Finds what's on the glass: the area that differs from the scanner's empty background, and how far it is turned.
enum ContentDetector {
    private static let workPixels = 1200
    private static let tolerance = 36

    /// The content's rectangle in scan pixels, turned when `straighten` is on and the content is crooked.
    static func find(in scan: ScannedPage, straighten: Bool) -> TiltedRect? {
        let k = min(1, Double(workPixels) / Double(max(scan.pixelWidth, scan.pixelHeight)))
        let w = max(1, Int(Double(scan.pixelWidth) * k)), h = max(1, Int(Double(scan.pixelHeight) * k))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(scan.preview, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)

        // The background is whatever colour dominates the border of the scan.
        var border: [[Int]] = [[], [], []]
        func addBorder(_ x: Int, _ y: Int) {
            let o = (y * w + x) * 4
            for c in 0..<3 { border[c].append(Int(px[o + c])) }
        }
        for x in stride(from: 0, to: w, by: 2) { addBorder(x, 0); addBorder(x, h - 1) }
        for y in stride(from: 0, to: h, by: 2) { addBorder(0, y); addBorder(w - 1, y) }
        let background = border.map { $0.sorted()[$0.count / 2] }

        // Skip a thin frame: scanner lids and glass edges often leave dark lines there.
        let inset = max(2, min(w, h) / 200)
        var points: [SIMD2<Float>] = []
        points.reserveCapacity(w * h / 4)
        for y in inset..<max(inset, h - inset) {
            var o = (y * w + inset) * 4
            for x in inset..<max(inset, w - inset) {
                let d = max(abs(Int(px[o]) - background[0]), abs(Int(px[o + 1]) - background[1]), abs(Int(px[o + 2]) - background[2]))
                if d > tolerance { points.append(SIMD2(Float(x), Float(y))) }
                o += 4
            }
        }
        guard points.count >= 20 else { return nil }

        let angle = straighten ? Deskew.estimateAngle(points) : 0
        let minCount = max(2, Int(Double(min(w, h)) * 0.004))
        guard let r = Deskew.bounds(points, angleDegrees: angle, minCount: minCount) else { return nil }
        // Back to scan pixels, with a pixel of slack on each side for the downscale.
        let pad = 2 / k
        return TiltedRect(centerX: r.centerX / k, centerY: r.centerY / k,
                          width: r.width / k + pad, height: r.height / k + pad, angleDegrees: angle)
    }
}
