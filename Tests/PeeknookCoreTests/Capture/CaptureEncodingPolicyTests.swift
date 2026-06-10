// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

final class CaptureEncodingPolicyTests: XCTestCase {
    func testBaseMaxPixelMatchesScopeAndQuick() {
        XCTAssertEqual(CaptureEncodingPolicy.baseMaxPixel(scope: .display, quick: false), 1600)
        XCTAssertEqual(CaptureEncodingPolicy.baseMaxPixel(scope: .display, quick: true), 1152)
        XCTAssertEqual(CaptureEncodingPolicy.baseMaxPixel(scope: .window, quick: false), 1280)
        XCTAssertEqual(CaptureEncodingPolicy.baseMaxPixel(scope: .window, quick: true), 896)
    }

    func testQualityScalesBaselineAndJPEGTier() {
        let balanced = CaptureEncodingPolicy.resolve(scope: .window, quick: false, quality: .balanced)
        XCTAssertEqual(balanced.maxPixel, 1280)
        XCTAssertEqual(balanced.jpegQuality, 0.82, accuracy: 0.001)

        let fast = CaptureEncodingPolicy.resolve(scope: .window, quick: false, quality: .fast)
        XCTAssertEqual(fast.maxPixel, 960)
        XCTAssertEqual(fast.jpegQuality, 0.65, accuracy: 0.001)

        let high = CaptureEncodingPolicy.resolve(scope: .window, quick: false, quality: .high)
        XCTAssertEqual(high.maxPixel, 1600)
        XCTAssertEqual(high.jpegQuality, 0.92, accuracy: 0.001)
    }

    func testScaledPixelFloorAt512() {
        XCTAssertEqual(CaptureEncodingPolicy.scaledMaxPixel(600, quality: .fast), 512)
    }

    func testCaptureQualityDefaultsAndRoundTrips() throws {
        let legacy = Data("""
        {"mode":"general","previewBeforeInfer":true,"ollamaBaseURL":"http://127.0.0.1:11434","textModel":"gemma4:e2b"}
        """.utf8)
        XCTAssertEqual(try JSONDecoder().decode(PeeknookSettings.self, from: legacy).captureQuality, .balanced)

        let high = PeeknookSettings(textModel: "gemma4:e2b", captureQuality: .high)
        let back = try JSONDecoder().decode(PeeknookSettings.self, from: JSONEncoder().encode(high))
        XCTAssertEqual(back.captureQuality, .high)
    }
}
