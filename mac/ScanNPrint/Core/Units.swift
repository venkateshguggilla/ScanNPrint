import Foundation

/// Conversions between physical units. Everything physical in the app is stored in millimetres;
/// pixels only exist relative to a known DPI.
enum Units {
    static let mmPerInch = 25.4

    static func pixelsToMm(_ pixels: Double, dpi: Double) -> Double { pixels / dpi * mmPerInch }

    static func mmToPixels(_ mm: Double, dpi: Double) -> Double { mm / mmPerInch * dpi }

    /// PostScript points (1/72 inch), the unit of PDF pages and printing.
    static func mmToPoints(_ mm: Double) -> Double { mm / mmPerInch * 72 }

    static func pointsToMm(_ points: Double) -> Double { points / 72 * mmPerInch }

    static func format(_ mm: Double) -> String {
        mm >= 100 ? String(format: "%.0f", mm) : String(format: "%.1f", mm).replacingOccurrences(of: ".0", with: "")
    }
}
