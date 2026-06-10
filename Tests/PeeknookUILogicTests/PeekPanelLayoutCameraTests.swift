// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookUI

/// `cameraPreviewSize` is the pure, width-keyed sizing function for the live camera preview —
/// the unit-testable guard against the #1 notch-height risk (an `AVCaptureVideoPreviewLayer` has
/// no intrinsic SwiftUI size, and a screen-derived height would evict the host top bar).
final class PeekPanelLayoutCameraTests: XCTestCase {
    func testSixteenNineAtUsableWidthHitsTheCeiling() {
        let size = PeekPanelLayout.cameraPreviewSize(forWidth: 480)
        XCTAssertEqual(size.width, 480)
        XCTAssertEqual(size.height, 270)
    }

    func testTallAspectsClampToTheCeiling() {
        XCTAssertEqual(PeekPanelLayout.cameraPreviewSize(forWidth: 480, aspect: 4.0 / 3.0).height, 270)
        XCTAssertEqual(PeekPanelLayout.cameraPreviewSize(forWidth: 480, aspect: 9.0 / 16.0).height, 270)
        XCTAssertEqual(PeekPanelLayout.cameraPreviewSize(forWidth: 480, aspect: 1.0).height, 270)
    }

    func testUltraWideAspectsClampToTheFloor() {
        XCTAssertEqual(PeekPanelLayout.cameraPreviewSize(forWidth: 480, aspect: 32.0 / 9.0).height, 180)
    }

    func testCinematicAspectLandsInsideTheBand() {
        let height = PeekPanelLayout.cameraPreviewSize(forWidth: 480, aspect: 21.0 / 9.0).height
        XCTAssertEqual(height, 206)   // 480 / (21/9) ≈ 205.7 → rounded, inside 180–270
    }

    func testDegenerateInputsFallBackToDefaults() {
        XCTAssertEqual(PeekPanelLayout.cameraPreviewSize(forWidth: .nan).height, 270)
        XCTAssertEqual(PeekPanelLayout.cameraPreviewSize(forWidth: .infinity).height, 270)
        XCTAssertEqual(PeekPanelLayout.cameraPreviewSize(forWidth: 0).height, 270)
        XCTAssertEqual(PeekPanelLayout.cameraPreviewSize(forWidth: -5).height, 270)
        XCTAssertEqual(PeekPanelLayout.cameraPreviewSize(forWidth: 480, aspect: 0).height, 270)
        XCTAssertEqual(PeekPanelLayout.cameraPreviewSize(forWidth: 480, aspect: .nan).height, 270)
        XCTAssertEqual(PeekPanelLayout.cameraPreviewSize(forWidth: 480, aspect: -2).height, 270)
    }

    func testHeightsAreIntegral() {
        for aspect: CGFloat in [1.0, 4.0 / 3.0, 16.0 / 9.0, 21.0 / 9.0, 32.0 / 9.0] {
            let height = PeekPanelLayout.cameraPreviewSize(forWidth: 480, aspect: aspect).height
            XCTAssertEqual(height, height.rounded())
        }
    }

    /// The band holds for ANY width/aspect — the invariant that protects the host top bar.
    func testNeverEscapesTheBandAcrossWidthsAndAspects() {
        for width in stride(from: CGFloat(100), through: 2000, by: 50) {
            for aspect: CGFloat in [0.5, 1.0, 16.0 / 9.0, 4.0] {
                let height = PeekPanelLayout.cameraPreviewSize(forWidth: width, aspect: aspect).height
                XCTAssertTrue((180...270).contains(height), "width \(width) aspect \(aspect) → \(height)")
            }
        }
    }
}
