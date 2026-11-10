import CoreGraphics
import Foundation

/// A region cut from a scan and placed on an output page. Non-destructive: it only references the
/// source image and the crop, so it can be re-rendered at full resolution at any time.
///
/// - `crop`: the selected region in the source image's pixels, before straightening.
/// - `straightenDegrees`: clockwise turn of the crop about its centre on the scan; the clip shows that
///   region upright. Limited to ±45°. A turned crop may reach past the image; that part is white.
/// - `centerX/Y`: centre on the page in mm; rotation happens around it.
/// - `width/height`: size on the page before rotation, in mm.
/// - `naturalWidth/Height`: physical size of the crop at the scan's DPI, i.e. "actual size".
/// - `rotationDegrees`: clockwise turn on the page, normalised to [0, 360).
struct Clip: Identifiable, Equatable {
    static let maxStraightenDegrees = 45.0

    var id = UUID()
    var sourceID: String
    var crop: PixelRect
    var straightenDegrees: Double = 0
    var centerX: Double
    var centerY: Double
    var width: Double
    var height: Double
    var naturalWidth: Double
    var naturalHeight: Double
    var rotationDegrees: Double = 0

    /// A new clip at actual size, centred at the given point.
    static func create(sourceID: String, crop: PixelRect, straighten: Double, dpi: Double,
                       centerX: Double, centerY: Double) -> Clip {
        let w = Units.pixelsToMm(Double(crop.width), dpi: dpi)
        let h = Units.pixelsToMm(Double(crop.height), dpi: dpi)
        return Clip(sourceID: sourceID, crop: crop, straightenDegrees: straighten, centerX: centerX, centerY: centerY,
                    width: w, height: h, naturalWidth: w, naturalHeight: h)
    }

    /// Print scale relative to the original: 1.0 is actual size.
    var scale: Double { width / naturalWidth }

    var center: CGPoint { CGPoint(x: centerX, y: centerY) }

    /// True when turned a quarter (90° or 270°), so width and height swap on the page.
    var isQuarterTurned: Bool { abs(rotationDegrees - 90) < 0.01 || abs(rotationDegrees - 270) < 0.01 }

    /// True when the clip's sides are parallel to the page's.
    var isAxisAligned: Bool { rotationDegrees.truncatingRemainder(dividingBy: 90) < 0.01 || 90 - rotationDegrees.truncatingRemainder(dividingBy: 90) < 0.01 }

    /// The axis-aligned box the clip covers on the page.
    var bounds: CGRect {
        let rad = rotationDegrees * .pi / 180
        let c = abs(cos(rad)), s = abs(sin(rad))
        return CGRect(centerX: centerX, centerY: centerY, width: width * c + height * s, height: width * s + height * c)
    }

    /// Corner `i` of the clip on the page: 0 top-left, 1 top-right, 2 bottom-right, 3 bottom-left (before rotation).
    func corner(_ i: Int) -> CGPoint {
        let sx: Double = (i == 1 || i == 2) ? 1 : -1
        let sy: Double = i >= 2 ? 1 : -1
        return toPage(CGPoint(x: sx * width / 2, y: sy * height / 2))
    }

    /// From the clip's own frame (origin at its centre) to the page.
    func toPage(_ local: CGPoint) -> CGPoint { center + local.rotated(degrees: rotationDegrees) }

    /// From the page to the clip's own frame.
    func toLocal(_ point: CGPoint) -> CGPoint { (point - center).rotated(degrees: -rotationDegrees) }

    func contains(_ point: CGPoint) -> Bool {
        let l = toLocal(point)
        return abs(l.x) <= width / 2 && abs(l.y) <= height / 2
    }

    func movedBy(dx: Double, dy: Double) -> Clip {
        var c = self
        c.centerX += dx
        c.centerY += dy
        return c
    }

    func movedTo(x: Double, y: Double) -> Clip {
        var c = self
        c.centerX = x
        c.centerY = y
        return c
    }

    func rotatedBy(_ degrees: Double) -> Clip { rotatedTo(rotationDegrees + degrees) }

    func rotatedTo(_ degrees: Double) -> Clip {
        var c = self
        c.rotationDegrees = Clip.normalizeDegrees(degrees)
        return c
    }

    /// Scales uniformly about the centre; 1.0 means actual size.
    func withScale(_ scale: Double) -> Clip {
        var c = self
        c.width = naturalWidth * scale
        c.height = naturalHeight * scale
        return c
    }

    /// Wraps into [0, 360), rounded to 6 decimals so repeated turns don't drift.
    static func normalizeDegrees(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        var r = degrees.truncatingRemainder(dividingBy: 360)
        if r < 0 { r += 360 }
        r = (r * 1e6).rounded() / 1e6
        return r >= 360 ? 0 : r
    }
}
