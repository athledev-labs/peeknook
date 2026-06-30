// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// The pure a11y -> OCR escalation decision: trust the cheap accessibility read only when it carried a
/// real caption, otherwise pay for pixels.
final class ScreenTextReaderPolicyTests: XCTestCase {

    func testEscalatesWhenAccessibilityEmpty() {
        XCTAssertTrue(ScreenTextReaderPolicy.shouldEscalateToOCR(accessibilityCandidate: nil))
        XCTAssertTrue(ScreenTextReaderPolicy.shouldEscalateToOCR(accessibilityCandidate: "   "))
    }

    func testEscalatesWhenAccessibilityTooShort() {
        // A short chrome label ("Play") is not a caption.
        XCTAssertTrue(ScreenTextReaderPolicy.shouldEscalateToOCR(accessibilityCandidate: "Play"))
    }

    func testTrustsRealAccessibilityCaption() {
        XCTAssertFalse(ScreenTextReaderPolicy.shouldEscalateToOCR(accessibilityCandidate: "I never expected to see you"))
    }
}
