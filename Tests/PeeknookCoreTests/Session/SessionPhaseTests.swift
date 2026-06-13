// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// `suppressesSetupBanner` de-dupes the idle "finish setup" banner against a failure card that already
/// names the missing prerequisite — but ONLY for setup/permission cards, never for genuine runtime
/// failures (whose "finish setup" nudge is still independently true).
///
/// REVERT-CHECK: widening the predicate to a plain `if case .failed` (suppress on ANY failure) makes the
/// `.emptyAnswer` / `.incompleteAnswerStream` assertions fail — proving the banner is dropped only for
/// prerequisite cards. Narrowing it back to `.setupIncomplete`-only fails the `.permissionRequired`
/// assertion, which pins the ⌘⇧C camera-off double-message fix.
final class SessionPhaseTests: XCTestCase {
    func testSuppressesSetupBannerOnlyForPrerequisiteFailures() {
        // Prerequisite cards: the card already states what's missing, so the standing banner is redundant.
        XCTAssertTrue(SessionPhase.failed(.setupIncomplete).suppressesSetupBanner)
        XCTAssertTrue(
            SessionPhase.failed(.permissionRequired(.camera)).suppressesSetupBanner,
            "A Camera-off card (⌘⇧C path) must suppress a co-rendered 'Screen Recording off' banner — same bug class."
        )

        // Genuine runtime failures are a DIFFERENT problem: keep the standing setup banner.
        XCTAssertFalse(SessionPhase.failed(.emptyAnswer).suppressesSetupBanner)
        XCTAssertFalse(SessionPhase.failed(.incompleteAnswerStream).suppressesSetupBanner)

        // Non-failure phases never suppress.
        XCTAssertFalse(SessionPhase.idle.suppressesSetupBanner)
        XCTAssertFalse(SessionPhase.result("hi").suppressesSetupBanner)
    }
}
