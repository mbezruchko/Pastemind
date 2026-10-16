import CoreGraphics
import Foundation
import ImageIO

/// A picture as EmbeddingGemma 2's image encoder takes it: packed RGB, sized to fill a token budget. Any format ImageIO
/// reads (PNG, JPEG, HEIC, TIFF), turned as its EXIF says, transparency over white (a window's screenshot has a
/// transparent shadow).
public struct ImagePixels: Sendable {
    /// The soft-token budgets the encoder takes: more tokens, finer detail, slower.
    public static let budgets = [70, 140, 280, 560, 1120]

    public let width: Int
    public let height: Int
    public let rgb: [UInt8]

    /// Read once at the size `budget` asks for (decoded no larger than that), or nil when unreadable or too thin.
    public init?(url: URL, budget: Int = 280) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = properties[kCGImagePropertyPixelWidth] as? Int,
              var height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, orientation >= 5 {   // turned a quarter
            swap(&width, &height)
        }
        guard let target = Self.targetSize(height: height, width: width, budget: budget) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(target.width, target.height),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        self.init(image: image, width: target.width, height: target.height)
    }

    /// A picture already decoded (a video's frame, a PDF's page, a document's preview), sized for `budget`.
    public init?(image: CGImage, budget: Int = 280) {
        guard let target = Self.targetSize(height: image.height, width: image.width, budget: budget) else { return nil }
        self.init(image: image, width: target.width, height: target.height)
    }

    private init?(image: CGImage, width: Int, height: Int) {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for pixel in 0..<(width * height) {
            rgb[pixel * 3] = rgba[pixel * 4]
            rgb[pixel * 3 + 1] = rgba[pixel * 4 + 1]
            rgb[pixel * 3 + 2] = rgba[pixel * 4 + 2]
        }
        self.width = width
        self.height = height
        self.rgb = rgb
    }

    /// The size Gemma 4's image processor gives a picture for `budget` soft tokens: as large as `budget` × 9 patches of
    /// 16 px allow, its aspect kept, each side a whole number of 48 px cells (3 × 3 patches pool into one token). A
    /// picture so long and thin that a side comes to no cell keeps one cell there, the other side by its proportion
    /// (no longer than `budget` cells). Nil when neither side reaches a cell.
    static func targetSize(height: Int, width: Int, budget: Int) -> (height: Int, width: Int)? {
        let cell = 48, patchArea = 16 * 16
        let scale = (Double(budget * 9 * patchArea) / Double(height * width)).squareRoot()
        var rows = Int(Double(height) * scale / Double(cell))     // whole cells: rounded down
        var columns = Int(Double(width) * scale / Double(cell))
        switch (rows, columns) {
        case (0, 0): return nil
        case (0, _): (rows, columns) = (1, min(width / height, budget))
        case (_, 0): (rows, columns) = (min(height / width, budget), 1)
        default: break
        }
        return (rows * cell, columns * cell)
    }
}
