import SwiftUI
import UIKit

/// Visible ("ink") extent of SF Symbols, measured from rendered pixels rather than the image's
/// layout frame (which includes side bearings). Results are cached per symbol and point size.
@MainActor
enum SymbolInk {
    struct Offsets: Hashable {
        /// Distance from the image's horizontal centre to the leftmost ink pixel.
        var leading: CGFloat
        /// Distance from the image's horizontal centre to the rightmost ink pixel.
        var trailing: CGFloat
    }

    private static var cache: [String: Offsets] = [:]

    /// Ink extent of `systemName` drawn at `pointSize` (regular weight, medium scale, like
    /// `Image(systemName:).font(...)`), relative to the image centre, in points.
    static func inkOffsetFromCenter(systemName: String, pointSize: CGFloat, weight: UIImage.SymbolWeight = .regular) -> Offsets {
        let key = "\(systemName)|\(pointSize)|\(weight.rawValue)"
        if let cached = cache[key] { return cached }
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight, scale: .medium)
        guard let image = UIImage(systemName: systemName, withConfiguration: config) else {
            return Offsets(leading: pointSize / 2, trailing: pointSize / 2)
        }
        let offsets = measure(image) ?? Offsets(leading: image.size.width / 2, trailing: image.size.width / 2)
        cache[key] = offsets
        return offsets
    }

    private static func measure(_ image: UIImage) -> Offsets? {
        let scale: CGFloat = 3
        let size = image.size
        let width = Int((size.width * scale).rounded(.up))
        let height = Int((size.height * scale).rounded(.up))
        guard width > 0, height > 0 else { return nil }
        // Rasterise the (vector) symbol first; its own `cgImage` may be nil.
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let raster = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.withTintColor(.black, renderingMode: .alwaysOriginal).draw(in: CGRect(origin: .zero, size: size))
        }
        guard let cgImage = raster.cgImage else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: nil, bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var minX = width, maxX = -1
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where pixels[row + x] > 24 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
            }
        }
        guard maxX >= minX else { return nil }
        let center = CGFloat(width) / 2
        return Offsets(
            leading: (center - CGFloat(minX)) / scale,
            trailing: (CGFloat(maxX + 1) - center) / scale
        )
    }
}
