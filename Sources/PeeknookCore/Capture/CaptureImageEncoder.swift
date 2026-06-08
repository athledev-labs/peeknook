// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum CaptureImageEncoder {
    /// JPEG base64 for Ollama vision models, resized to keep latency reasonable on local inference.
    static func jpegBase64(from image: CGImage, maxPixel: Int = 1280, quality: CGFloat = 0.82) -> String? {
        let width = image.width
        let height = image.height
        let scale = min(1, Double(maxPixel) / Double(max(width, height)))
        let targetWidth = max(1, Int(Double(width) * scale))
        let targetHeight = max(1, Int(Double(height) * scale))

        let resized: CGImage
        if scale < 1, let scaled = resize(image, width: targetWidth, height: targetHeight) {
            resized = scaled
        } else {
            resized = image
        }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(dest, resized, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data.base64EncodedString()
    }

    private static func resize(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let colorSpace = image.colorSpace else { return nil }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
