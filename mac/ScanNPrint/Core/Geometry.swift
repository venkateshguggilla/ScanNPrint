import CoreGraphics
import Foundation

/// A rectangle of whole pixels in a source image, y growing downwards.
struct PixelRect: Hashable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    var right: Int { x + width }
    var bottom: Int { y + height }
    var centerX: Double { Double(x) + Double(width) / 2 }
    var centerY: Double { Double(y) + Double(height) / 2 }
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Rounds to whole pixels, keeping at least 1 × 1.
    init(_ rect: CGRect) {
        let x0 = Int(rect.minX.rounded()), y0 = Int(rect.minY.rounded())
        let x1 = Int(rect.maxX.rounded()), y1 = Int(rect.maxY.rounded())
        self.init(x: x0, y: y0, width: max(1, x1 - x0), height: max(1, y1 - y0))
    }

    /// Clamps to an `imageWidth` × `imageHeight` image, keeping at least 1 × 1.
    func clamped(width imageWidth: Int, height imageHeight: Int) -> PixelRect {
        let x0 = min(max(x, 0), imageWidth - 1)
        let y0 = min(max(y, 0), imageHeight - 1)
        let x1 = min(max(right, x0 + 1), imageWidth)
        let y1 = min(max(bottom, y0 + 1), imageHeight)
        return PixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

/// A rectangle turned clockwise (on a y-down image) by `angleDegrees` about its centre.
struct TiltedRect: Equatable {
    var centerX: Double
    var centerY: Double
    var width: Double
    var height: Double
    var angleDegrees: Double
}

extension CGRect {
    init(centerX: Double, centerY: Double, width: Double, height: Double) {
        self.init(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height)
    }

    var center: CGPoint { CGPoint(x: midX, y: midY) }

    /// True when the rectangles overlap by more than an edge.
    func overlaps(_ other: CGRect) -> Bool {
        minX < other.maxX && other.minX < maxX && minY < other.maxY && other.minY < maxY
    }

    func containsRect(_ other: CGRect, tolerance: Double = 1e-6) -> Bool {
        other.minX >= minX - tolerance && other.minY >= minY - tolerance &&
            other.maxX <= maxX + tolerance && other.maxY <= maxY + tolerance
    }
}

extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: CGPoint, s: CGFloat) -> CGPoint { CGPoint(x: a.x * s, y: a.y * s) }

    var length: CGFloat { (x * x + y * y).squareRoot() }

    /// Turns clockwise on a y-down plane.
    func rotated(degrees: Double) -> CGPoint {
        let rad = degrees * .pi / 180, c = cos(rad), s = sin(rad)
        return CGPoint(x: x * c - y * s, y: x * s + y * c)
    }

    func distance(to other: CGPoint) -> CGFloat { (self - other).length }
}
