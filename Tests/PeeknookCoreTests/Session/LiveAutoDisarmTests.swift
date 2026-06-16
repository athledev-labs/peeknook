// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// Live Session WS-2: the mandatory auto-disarm timeout. An armed session may run longer than today's
/// exit-on-everything (it survives Done with `livePersistAcrossDone`) but is now ALWAYS bounded by a hard
/// inactivity cap the user cannot disable. `liveMaxArmedSeconds == 0` (the default) = no cap, byte-identical
/// to before: no deadline is snapshot at arm and the loop never `.expire`s. With a cap the deadline is
/// snapshot at arm, pushed forward on user interaction, watched by the existing timer loop, and on expiry the
/// session disarms through the SINGLE choke point `stopLiveSession()` and emits a one-shot `.liveEnded` notice.
@MainActor
final class LiveAutoDisarmTests: XCTestCase {

    private func makeOrchestrator(
        maxArmedSeconds: Double = 0,
        provider: any CaptureProviding = StubCaptureProvider(sampleText: "s")
    ) -> SessionOrchestrator {
        var settings = PeeknookSettings(textModel: "x")
        settings.liveEnabled = true
        settings.liveMaxArmedSeconds = maxArmedSeconds
        return SessionOrchestrator(
            settings: settings,
            captureRegistry: GroundRegistry([.screen: provider]),
            inference: MockInferenceEngine(tokens: ["a"])
        )
    }

    /// Drive one capture to `.result` and arm a manual session via the real `armLive()` (so the deadline
    /// is snapshot exactly as production does).
    private func armedManual(maxArmedSeconds: Double) async -> SessionOrchestrator {
        let o = makeOrchestrator(maxArmedSeconds: maxArmedSeconds)
        o.beginCapture()
        _ = await o.waitForResult("a")
        o.armLive()
        return o
    }

    // MARK: No cap (default) is byte-identical — no deadline is ever snapshot

    func testNoCapSnapshotsNoDeadline() async {
        let o = await armedManual(maxArmedSeconds: 0)
        XCTAssertNil(o.livePolicy?.expiresAt, "cap=0 → no deadline (byte-identical to pre-WS-2)")
        XCTAssertNil(o.liveRemainingSeconds(), "no countdown is shown without a cap")
    }

    func testNoCapManualSessionRunsNoLoopAndNeverDisarmsItself() async {
        let o = await armedManual(maxArmedSeconds: 0)
        // A capless manual session has no loop at all; let time pass and confirm it stays armed.
        let disarmed = await o.waitUntil(timeout: 0.4) { !o.isLiveArmed }
        XCTAssertFalse(disarmed, "no cap → the session never auto-disarms")
        XCTAssertTrue(o.isLiveArmed)
    }

    // MARK: Arm snapshots a deadline from the cap (like the interval)

    func testArmSnapshotsDeadlineFromCap() async {
        let before = Date()
        let o = await armedManual(maxArmedSeconds: 1800)
        let after = Date()
        guard let deadline = o.livePolicy?.expiresAt else {
            return XCTFail("a cap should snapshot a deadline at arm")
        }
        XCTAssertGreaterThanOrEqual(deadline, before.addingTimeInterval(1800))
        XCTAssertLessThanOrEqual(deadline, after.addingTimeInterval(1800))
        // The remaining countdown reads roughly the full cap right after arm.
        let remaining = o.liveRemainingSeconds() ?? 0
        XCTAssertGreaterThan(remaining, 1700)
        XCTAssertLessThanOrEqual(remaining, 1800)
    }

    func testMidSessionCapEditDoesNotPerturbArmedDeadline() async {
        // Snapshot-at-arm contract (like the interval): editing the setting while armed is inert until
        // the next arm — the running session keeps its deadline.
        let o = await armedManual(maxArmedSeconds: 1800)
        let deadlineBefore = o.livePolicy?.expiresAt
        o.settings.liveMaxArmedSeconds = 900
        XCTAssertEqual(o.livePolicy?.expiresAt, deadlineBefore, "a mid-session cap edit doesn't retune the live deadline")
    }

    // MARK: The cap auto-disarms via the single choke point, with a one-shot notice

    func testCapExpiresAndDisarmsWithNotice() async {
        // A tiny cap so the loop expires it promptly. Assign the policy with a past/near deadline directly
        // (arm clamps nothing here, but we want a sub-second deadline for a fast, deterministic test).
        let o = makeOrchestrator(maxArmedSeconds: 0)
        o.beginCapture()
        _ = await o.waitForResult("a")
        o.livePolicy = LivePolicy(refresh: .manual, expiresAt: Date().addingTimeInterval(0.1))
        o.liveCoordinator.startTimerLoopIfNeeded()   // the loop runs to watch the deadline even for manual
        let disarmed = await o.waitUntil(timeout: 2) { !o.isLiveArmed }
        XCTAssertTrue(disarmed, "the loop auto-disarms the session at its deadline")
        XCTAssertNil(o.livePolicy, "expiry routes through stopLiveSession() — the policy is cleared")
        XCTAssertEqual(o.lastNotice, .liveEnded, "a one-shot notice explains the chip's disappearance")
    }

    func testTimerCapExpiresEvenWhileParkingFrames() async {
        // A timer session past its deadline must disarm rather than keep parking — the cap wins over the
        // refresh cadence (the pure policy's expire-over-park precedence, exercised through the real loop).
        let o = makeOrchestrator(maxArmedSeconds: 0)
        o.beginCapture()
        _ = await o.waitForResult("a")
        o.livePolicy = LivePolicy(refresh: .timer, timerInterval: 0.05, expiresAt: Date().addingTimeInterval(0.2))
        o.liveCoordinator.startTimerLoopIfNeeded()
        let disarmed = await o.waitUntil(timeout: 2) { !o.isLiveArmed }
        XCTAssertTrue(disarmed, "a timer session disarms at its deadline")
        let parkedAfter = await o.waitUntil(timeout: 0.3) { o.hasPendingLiveFrame }
        XCTAssertFalse(parkedAfter, "no further park after the cap disarms")
    }

    // MARK: User interaction resets the countdown (pushes the deadline forward)

    func testManualRefreshResetsTheDeadline() async {
        let o = await armedManual(maxArmedSeconds: 1800)
        // Wind the deadline down so a reset is observable.
        o.livePolicy?.expiresAt = Date().addingTimeInterval(10)
        let near = o.liveRemainingSeconds() ?? 0
        XCTAssertLessThan(near, 60, "precondition: the deadline is wound near")
        o.refreshLive()                      // a user Refresh → reset
        _ = await o.waitUntil { o.hasPendingLiveFrame }
        let reset = o.liveRemainingSeconds() ?? 0
        XCTAssertGreaterThan(reset, 1700, "a manual Refresh pushes the deadline back to the full cap")
    }

    func testAnswerNowResetsTheDeadline() async {
        let o = await armedManual(maxArmedSeconds: 1800)
        o.refreshLive()
        _ = await o.waitUntil { o.hasPendingLiveFrame }
        o.livePolicy?.expiresAt = Date().addingTimeInterval(10)
        o.answerLive()                       // "Answer now" → reset
        let reset = o.liveRemainingSeconds() ?? 0
        XCTAssertGreaterThan(reset, 1700, "Answer now pushes the deadline back to the full cap")
    }

    func testUpdateAndAskResetsTheDeadline() async {
        let o = await armedManual(maxArmedSeconds: 1800)
        o.livePolicy?.expiresAt = Date().addingTimeInterval(10)
        o.updateAndAskLive()                 // "Update & ask" → reset
        let reset = o.liveRemainingSeconds() ?? 0
        XCTAssertGreaterThan(reset, 1700, "Update & ask pushes the deadline back to the full cap")
    }

    func testAutomaticTimerParkDoesNotResetTheDeadline() async {
        // An auto `.timer` park is NOT a user interaction — it must not extend the inactivity deadline,
        // or a timer left running unattended would never expire (defeating the whole cap).
        let o = makeOrchestrator(maxArmedSeconds: 0)
        o.beginCapture()
        _ = await o.waitForResult("a")
        let deadline = Date().addingTimeInterval(60)
        o.livePolicy = LivePolicy(refresh: .timer, timerInterval: 0.05, expiresAt: deadline)
        o.liveCoordinator.startTimerLoopIfNeeded()
        _ = await o.waitUntil { o.hasPendingLiveFrame }   // a timer park has happened
        XCTAssertEqual(o.livePolicy?.expiresAt, deadline, "an automatic timer park leaves the deadline unchanged")
    }

    func testBumpIsANoOpWithoutACap() async {
        // With no cap (expiresAt == nil) the deadline stays nil through interactions — byte-identical.
        let o = await armedManual(maxArmedSeconds: 0)
        o.refreshLive()
        _ = await o.waitUntil { o.hasPendingLiveFrame }
        XCTAssertNil(o.livePolicy?.expiresAt, "no cap → interactions never create a deadline")
    }

    // MARK: liveRemainingSeconds is a pure, injectable computation

    func testRemainingSecondsIsPureAndFloored() async {
        let o = await armedManual(maxArmedSeconds: 1800)
        let at = o.livePolicy?.expiresAt ?? Date()
        XCTAssertEqual(o.liveRemainingSeconds(at: at.addingTimeInterval(-600)) ?? 0, 600, accuracy: 0.01)
        XCTAssertEqual(o.liveRemainingSeconds(at: at) ?? -1, 0, accuracy: 0.01, "at the deadline → 0")
        XCTAssertEqual(o.liveRemainingSeconds(at: at.addingTimeInterval(60)) ?? -1, 0,
                       "past the deadline floors at 0, never negative")
    }
}
