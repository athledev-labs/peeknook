// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import XCTest
@testable import PeeknookCore

final class CaptureImageEncoderTests: XCTestCase {
    func testPreservesSmallImageWithoutResize() {
        let image = Self.makeImage(width: 640, height: 480)
        guard let encoded = CaptureImageEncoder.jpegBase64(from: image, maxPixel: 1280) else {
            XCTFail("Expected JPEG output")
            return
        }
        guard let decoded = Self.decodeJPEG(base64: encoded) else {
            XCTFail("Expected decodable JPEG")
            return
        }
        XCTAssertEqual(decoded.width, 640)
        XCTAssertEqual(decoded.height, 480)
    }

    func testDownscalesWideImage() {
        let image = Self.makeImage(width: 2000, height: 1000)
        guard let encoded = CaptureImageEncoder.jpegBase64(from: image, maxPixel: 1280) else {
            XCTFail("Expected JPEG output")
            return
        }
        guard let decoded = Self.decodeJPEG(base64: encoded) else {
            XCTFail("Expected decodable JPEG")
            return
        }
        XCTAssertLessThanOrEqual(max(decoded.width, decoded.height), 1280)
        XCTAssertEqual(decoded.width, 1280)
        XCTAssertEqual(decoded.height, 640)
    }

    func testLowerQualityProducesSmallerPayload() {
        let image = Self.makeImage(width: 800, height: 600)
        guard let high = CaptureImageEncoder.jpegBase64(from: image, quality: 0.9),
              let low = CaptureImageEncoder.jpegBase64(from: image, quality: 0.3) else {
            XCTFail("Expected JPEG output")
            return
        }
        XCTAssertLessThan(low.count, high.count)
    }

    private static func makeImage(width: Int, height: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private static func decodeJPEG(base64: String) -> CGImage? {
        guard let data = Data(base64Encoded: base64),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
