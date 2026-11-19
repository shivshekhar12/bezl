import BezlCore
import CoreGraphics
import Foundation
import ImageIO

/// Decodes encoded artwork (PNG/JPEG/…) and extracts the rim palette. Safe off the main thread.
enum ArtworkPalette {
    static let side = 48

    static func palette(fromImageData data: Data) -> Palette? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // Let ImageIO decode a small thumbnail directly (much cheaper than full-size decode).
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 128,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return palette(from: image)
    }

    static func palette(from image: CGImage) -> Palette? {
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drew else { return nil }
        return PaletteExtractor().extract(rgba: pixels, width: side, height: side)
    }
}
