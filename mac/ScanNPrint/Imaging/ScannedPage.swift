import AppKit
import CoreGraphics

/// A scan in the session: a PNG on disk plus downscaled copies for the screen.
final class ScannedPage: Identifiable {
    /// Longest side of the on-screen copy. Big enough to stay sharp when zoomed in on a Retina display.
    static let previewPixels = 2600

    let id: String
    let url: URL
    let dpi: Double
    let pixelWidth: Int
    let pixelHeight: Int
    let isGray: Bool
    let number: Int
    let preview: CGImage
    let thumbnail: NSImage
    var inScanList: Bool

    init?(id: String, url: URL, dpi: Double, number: Int, inScanList: Bool = true) {
        guard let info = ImageFile.info(url),
              let preview = ImageFile.thumbnail(url, maxPixels: min(Self.previewPixels, max(info.width, info.height))),
              let small = ImageFile.thumbnail(url, maxPixels: 200) else { return nil }
        self.id = id
        self.url = url
        self.dpi = dpi
        self.number = number
        self.inScanList = inScanList
        pixelWidth = info.width
        pixelHeight = info.height
        isGray = ImageFile.isGray(preview)
        self.preview = preview
        thumbnail = NSImage(cgImage: small, size: NSSize(width: small.width, height: small.height))
    }

    var name: String { "Scan \(number)" }
    var widthMm: Double { Units.pixelsToMm(Double(pixelWidth), dpi: dpi) }
    var heightMm: Double { Units.pixelsToMm(Double(pixelHeight), dpi: dpi) }
    var pixelSize: CGSize { CGSize(width: pixelWidth, height: pixelHeight) }

    /// Preview pixels per scan pixel.
    var previewScale: Double { Double(preview.width) / Double(pixelWidth) }

    var sizeDescription: String {
        let paper = PaperSize.matching(width: widthMm, height: heightMm).map { "\($0.name) · " } ?? ""
        return "\(paper)\(Units.format(widthMm)) × \(Units.format(heightMm)) mm · \(Int(dpi.rounded())) dpi"
    }

    func loadFullImage() -> CGImage? { ImageFile.load(url) }
}
