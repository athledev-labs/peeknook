// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// The pure caption policies: segment finalization debounce, the bounded rolling-tail state, and the
/// recognizer-rollover decision. Clock-free, so they pin the cadence apart from the device-only tap.
final class CaptionPolicyTests: XCTestCase {

    // MARK: CaptionSegmentPolicy

    func testWaitsWhileInterimStillFlowing() {
        XCTAssertEqual(
            CaptionSegmentPolicy.decide(interim: "hello there", secondsSinceLastToken: 0.2, secondsSinceSegmentStart: 1, recognizerMarkedFinal: false),
            .wait
        )
    }

    func testFinalizesAfterStabilityWindow() {
        XCTAssertEqual(
            CaptionSegmentPolicy.decide(interim: "hello there", secondsSinceLastToken: 1.5, secondsSinceSegmentStart: 2, recognizerMarkedFinal: false),
            .finalize, "a settled (quiet) interim finalizes"
        )
    }

    func testFinalizesOnRecognizerFinal() {
        XCTAssertEqual(
            CaptionSegmentPolicy.decide(interim: "hi", secondsSinceLastToken: 0, secondsSinceSegmentStart: 0.1, recognizerMarkedFinal: true),
            .finalize, "a recognizer-final result finalizes immediately"
        )
    }

    func testForceFinalizesAPauselessMonologueAtMaxAge() {
        XCTAssertEqual(
            CaptionSegmentPolicy.decide(interim: "a long run-on with no pause", secondsSinceLastToken: 0.3, secondsSinceSegmentStart: 6.5, recognizerMarkedFinal: false),
            .finalize, "maxSegmentAge slices a pause-less monologue"
        )
    }

    func testNeverFinalizesEmptyOrTooShortInterim() {
        XCTAssertEqual(
            CaptionSegmentPolicy.decide(interim: "   ", secondsSinceLastToken: 5, secondsSinceSegmentStart: 10, recognizerMarkedFinal: true),
            .wait, "silence never finalizes, even when marked final"
        )
        XCTAssertEqual(
            CaptionSegmentPolicy.decide(interim: "a", secondsSinceLastToken: 5, secondsSinceSegmentStart: 10, recognizerMarkedFinal: true),
            .wait, "a single stray character is below minCharacters"
        )
    }

    // MARK: CaptionState

    func testCommitCurrentLinePushesAndCapsRollingTail() {
        var s = CaptionState()
        for i in 1...5 {
            s.currentLine = "line \(i)"
            s.commitCurrentLine()
        }
        XCTAssertEqual(s.currentLine, "")
        XCTAssertEqual(s.recentLines, ["line 3", "line 4", "line 5"], "capped at maxRecentLines (3), oldest dropped")
    }

    func testCommitCurrentLineDropsBlank() {
        var s = CaptionState(recentLines: ["keep"])
        s.currentLine = "   "
        s.commitCurrentLine()
        XCTAssertEqual(s.currentLine, "")
        XCTAssertEqual(s.recentLines, ["keep"], "a blank translation never pollutes the tail")
    }

    // MARK: RecognizerRolloverPolicy

    func testRolloverTruthTable() {
        XCTAssertFalse(RecognizerRolloverPolicy.shouldRoll(elapsed: 10, sawFinal: false))
        XCTAssertTrue(RecognizerRolloverPolicy.shouldRoll(elapsed: 51, sawFinal: false), "past the safe window")
        XCTAssertTrue(RecognizerRolloverPolicy.shouldRoll(elapsed: 5, sawFinal: true), "a natural final is the clean seam")
    }
}
