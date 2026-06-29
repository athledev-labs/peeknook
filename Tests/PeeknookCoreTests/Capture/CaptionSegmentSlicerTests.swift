// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// The pure delta extractor that turns a recognizer's growing cumulative transcript into the
/// not-yet-finalized tail. Clock-free, so it pins the "no dropped / duplicated words at the seam"
/// behavior apart from the device-only audio tap.
final class CaptionSegmentSlicerTests: XCTestCase {

    func testEmptyCommittedPrefixReturnsWholeCumulative() {
        XCTAssertEqual(
            CaptionSegmentSlicer.pending(cumulative: "hello there", committedPrefix: ""),
            "hello there"
        )
    }

    func testReturnsOnlyTheTailAfterACommit() {
        XCTAssertEqual(
            CaptionSegmentSlicer.pending(cumulative: "hello there world", committedPrefix: "hello there"),
            "world"
        )
    }

    func testWhitespaceToleranceOnBothSides() {
        XCTAssertEqual(
            CaptionSegmentSlicer.pending(cumulative: "  hello there   world  ", committedPrefix: "  hello there "),
            "world"
        )
    }

    func testFullyCommittedCumulativeYieldsEmptyTail() {
        XCTAssertEqual(
            CaptionSegmentSlicer.pending(cumulative: "hello there", committedPrefix: "hello there"),
            ""
        )
    }

    func testRevisionFallbackResurfacesWholeCumulativeRatherThanDropWords() {
        // The recognizer revised an already-committed word ("their" -> "there"): the committed prefix is
        // no longer a prefix, so we re-surface the whole line rather than silently drop the correction.
        XCTAssertEqual(
            CaptionSegmentSlicer.pending(cumulative: "hello there world", committedPrefix: "hello their"),
            "hello there world"
        )
    }

    func testGrowthAcrossSuccessivePartialsWithoutDuplication() {
        var committed = ""
        // First quiet tail finalizes.
        XCTAssertEqual(CaptionSegmentSlicer.pending(cumulative: "ship it", committedPrefix: committed), "ship it")
        committed = "ship it"
        // Same partial, nothing new -> nothing pending (no duplicate emit).
        XCTAssertEqual(CaptionSegmentSlicer.pending(cumulative: "ship it", committedPrefix: committed), "")
        // The session continues and adds more -> only the new words are pending.
        XCTAssertEqual(CaptionSegmentSlicer.pending(cumulative: "ship it on friday", committedPrefix: committed), "on friday")
    }
}
