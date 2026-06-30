// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// The pure temporal policy for on-screen captions: finalize a NEW line once it has held stable, never
/// re-translate the still-displayed subtitle, and let a growing line settle before committing.
final class ScreenTextSegmentPolicyTests: XCTestCase {

    func testWaitsBelowMinCharacters() {
        XCTAssertEqual(
            ScreenTextSegmentPolicy.decide(candidate: "a", lastEmitted: "", secondsSinceCandidateChanged: 5),
            .wait
        )
    }

    func testWaitsUntilStable() {
        XCTAssertEqual(
            ScreenTextSegmentPolicy.decide(candidate: "Hello there", lastEmitted: "", secondsSinceCandidateChanged: 0.1),
            .wait
        )
    }

    func testFinalizesNewStableLine() {
        XCTAssertEqual(
            ScreenTextSegmentPolicy.decide(candidate: "Hello there", lastEmitted: "", secondsSinceCandidateChanged: 1),
            .finalize
        )
    }

    func testDoesNotReTranslateStillDisplayedSubtitle() {
        // Same line still on screen (case/spacing wobble) -> never a new segment.
        XCTAssertEqual(
            ScreenTextSegmentPolicy.decide(candidate: "  hello   there ", lastEmitted: "Hello there", secondsSinceCandidateChanged: 10),
            .wait
        )
    }

    func testFinalizesReplacementLine() {
        XCTAssertEqual(
            ScreenTextSegmentPolicy.decide(candidate: "Goodbye now", lastEmitted: "Hello there", secondsSinceCandidateChanged: 1),
            .finalize
        )
    }

    func testIsSameLineIgnoresCaseAndWhitespace() {
        XCTAssertTrue(ScreenTextSegmentPolicy.isSameLine("Hello  There", "hello there"))
        XCTAssertFalse(ScreenTextSegmentPolicy.isSameLine("Hello there", "Hello friend"))
    }
}
