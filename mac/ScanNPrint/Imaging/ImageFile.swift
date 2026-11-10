import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Reading and writing image files with ImageIO.
enum ImageFile {
    struct Info {
        var width: Int
        var height: Int
        var dpi: Double?
        var orientation: Int
    }

    static func info(_ url: URL) -> Info? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let dpi = (p[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue
        return Info(width: w, height: h, dpi: dpi, orientation: (p[kCGImagePropertyOrientation] as? Int) ?? 1)
    }

    /// The full image, decoded now rather than on first draw.
    static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// A downscaled copy no larger than `maxPixels` on its longest side, upright per the file's orientation.
    static func thumbnail(_ url: URL, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The image turned upright per its EXIF orientation (photos from phones are often stored sideways).
    static func loadUpright(_ url: URL) -> CGImage? {
        guard let info = info(url) else { return nil }
        return info.orientation == 1 ? load(url) : thumbnail(url, maxPixels: max(info.width, info.height))
    }

    static func write(_ images: [CGImage], to url: URL, type: UTType, dpi: Double, quality: Double = 0.92) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, images.count, nil) else {
            throw ExportError(message: "Couldn't create \(url.lastPathComponent).")
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
            kCGImageDestinationLossyCompressionQuality: quality,
        ]
        for image in images { CGImageDestinationAddImage(destination, image, properties as CFDictionary) }
        guard CGImageDestinationFinalize(destination) else {
            throw ExportError(message: "Couldn't write \(url.lastPathComponent).")
        }
    }

    static func isGray(_ image: CGImage) -> Bool { image.colorSpace?.model == .monochrome }

    /// Draws `image` filling `rect` in a context whose y axis points down.
    static func drawYDown(_ image: CGImage, in rect: CGRect, context ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    /// A bitmap context with a white background and its origin at the top-left, y down.
    static func makeContext(width: Int, height: Int, gray: Bool) -> CGContext? {
        let ctx: CGContext?
        if gray {
            ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        } else {
            ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        }
        guard let ctx else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        return ctx
    }
}

struct ExportError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
