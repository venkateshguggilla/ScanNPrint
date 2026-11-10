import Foundation

/// A named paper size in portrait orientation, in millimetres.
struct PaperSize: Hashable, Identifiable {
    let name: String
    let widthMm: Double
    let heightMm: Double

    var id: String { name }

    static let a3 = PaperSize(name: "A3", widthMm: 297, heightMm: 420)
    static let a4 = PaperSize(name: "A4", widthMm: 210, heightMm: 297)
    static let a5 = PaperSize(name: "A5", widthMm: 148, heightMm: 210)
    static let a6 = PaperSize(name: "A6", widthMm: 105, heightMm: 148)
    static let b5 = PaperSize(name: "B5", widthMm: 176, heightMm: 250)
    static let letter = PaperSize(name: "Letter", widthMm: 215.9, heightMm: 279.4)
    static let legal = PaperSize(name: "Legal", widthMm: 215.9, heightMm: 355.6)

    static let standard: [PaperSize] = [a4, a5, a6, b5, letter, legal, a3]

    var label: String { "\(name) (\(Units.format(widthMm)) × \(Units.format(heightMm)) mm)" }

    static func named(_ name: String) -> PaperSize? { standard.first { $0.name == name } }

    /// The standard size of `width` × `height` mm in either orientation, within 1 mm.
    static func matching(width: Double, height: Double) -> PaperSize? {
        standard.first {
            (abs($0.widthMm - width) < 1 && abs($0.heightMm - height) < 1) ||
                (abs($0.widthMm - height) < 1 && abs($0.heightMm - width) < 1)
        }
    }
}
