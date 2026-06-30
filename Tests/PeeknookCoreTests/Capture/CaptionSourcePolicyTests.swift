// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// The pure source router: screen text wins when present, audio is the fallback, and the asymmetric
/// claim/release windows give hysteresis so a brief subtitle gap doesn't flap the source.
final class CaptionSourcePolicyTests: XCTestCase {

    func testNeverSeenScreenRidesAudio() {
        XCTAssertEqual(
            CaptionSourcePolicy.authoritativeSource(current: .audio, secondsSinceScreenSegment: .infinity),
            .audio
        )
    }

    func testFreshScreenSegmentClaimsAuthorityFromAudio() {
        XCTAssertEqual(
            CaptionSourcePolicy.authoritativeSource(current: .audio, secondsSinceScreenSegment: 1),
            .screen
        )
    }

    func testStaleScreenDoesNotClaimFromAudio() {
        XCTAssertEqual(
            CaptionSourcePolicy.authoritativeSource(
                current: .audio,
                secondsSinceScreenSegment: CaptionSourcePolicy.screenClaimWindow + 1
            ),
            .audio
        )
    }

    func testBriefSubtitleGapHoldsScreen() {
        // Between claim and release windows: a gap, but we keep screen (hysteresis), no flap to audio.
        let between = (CaptionSourcePolicy.screenClaimWindow + CaptionSourcePolicy.screenReleaseWindow) / 2
        XCTAssertEqual(
            CaptionSourcePolicy.authoritativeSource(current: .screen, secondsSinceScreenSegment: between),
            .screen
        )
    }

    func testScreenReleasesToAudioAfterLongSilence() {
        XCTAssertEqual(
            CaptionSourcePolicy.authoritativeSource(
                current: .screen,
                secondsSinceScreenSegment: CaptionSourcePolicy.screenReleaseWindow + 1
            ),
            .audio
        )
    }
}
