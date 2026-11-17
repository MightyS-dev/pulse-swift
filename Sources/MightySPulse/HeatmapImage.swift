import Foundation
import CoreGraphics
import ImageIO

/// Encodes a captured screen for the debug upload: longest side at most 2048 px, PNG, and JPEG at quality 80 when the PNG
/// is above 2 MiB. Pure CoreGraphics and ImageIO; call it off the main thread.
internal enum PulseHeatmapImage {
    static let maxSide = 2048
    static let pngLimit = 2 * 1024 * 1024

    static func scaled(_ image: CGImage) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxSide else { return image }
        let ratio = Double(maxSide) / Double(longest)
        let width = max(1, Int((Double(image.width) * ratio).rounded())), height = max(1, Int((Double(image.height) * ratio).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
    private static func data(_ image: CGImage, type: String, quality: Double?) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type as CFString, 1, nil) else { return nil }
        var options: [CFString: Any] = [:]
        if let quality = quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
    /// The bytes and their Content-Type, or nil when the picture cannot be encoded within 2 MiB.
    static func encode(_ image: CGImage) -> (bytes: Data, contentType: String)? {
        let small = scaled(image)
        if let png = data(small, type: "public.png", quality: nil), png.count <= pngLimit { return (png, "image/png") }
        if let jpeg = data(small, type: "public.jpeg", quality: 0.8), jpeg.count <= PulseHeatmapShots.maxBytes { return (jpeg, "image/jpeg") }
        return nil
    }
}
