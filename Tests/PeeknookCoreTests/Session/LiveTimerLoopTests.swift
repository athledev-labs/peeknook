// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// Live Session v1 slice 6: the LiveCoordinator-owned auto-refresh timer. It PARKS the latest frame on
/// a fixed interval (exactly like manual Refresh) and NEVER infers; pauses at critical context; survives
/// `abortSessionWork` (a Retake / Add image); dies only on disarm; and cannot leak across a relaunch
/// (the armed policy is transient). The user-facing interval clamps to >= 1s, so the timing tests drive
/// the REAL loop with a sub-second interval via the white-box seam (assign `livePolicy` directly,
/// bypassing arm's clamp, then call the internal `startTimerLoopIfNeeded()`).
@MainActor
final class LiveTimerLoopTests: XCTestCase {

    private func makeOrchestrator(
        _ settings: PeeknookSettings = PeeknookSettings(textModel: "x"),
        provider: any CaptureProviding = StubCaptureProvider(sampleText: "s")
    ) -> SessionOrchestrator {
        SessionOrchestrator(
            settings: settings,
            captureRegistry: GroundRegistry([.screen: provider]),
            inference: MockInferenceEngine(tokens: ["a"])
        )
    }

    /// Drive one capture to `.result` (the only state Live arms from), then start a fast `.timer` loop
    /// by assigning the policy directly (arm() would clamp the interval to >= 1s).
    private func armedTimer(
        interval: TimeInterval = 0.05,
        provider: any CaptureProviding = StubCaptureProvider(sampleText: "s")
    ) async -> SessionOrchestrator {
        let o = makeOrchestrator(provider: provider)
        o.beginCapture()
        _ = await o.waitForResult("a")
        o.livePolicy = LivePolicy(refresh: .timer, timerInterval: interval)
        o.liveCoordinator.startTimerLoopIfNeeded()
        return o
    }

    // MARK: Parks, no inference

    func testTimerParksFrameWithoutInferring() async {
        let o = await armedTimer()
        let imagesBefore = o.conversation.filter(\.isImage).count
        let parked = await o.waitUntil { o.hasPendingLiveFrame }
        XCTAssertTrue(parked, "the timer parks the latest screen into pending context")
        XCTAssertNotNil(o.lastLiveRefreshAt, "a timer park stamps the last-refresh time for the chip")
        XCTAssertEqual(o.conversation.filter(\.isImage).count, imagesBefore, "a park adds no turn — no inference")
        XCTAssertTrue(o.isLiveArmed)
        if case .result = o.phase {} else { XCTFail("the timer stays in .result, got \(o.phase)") }
    }

    func testTimerNeverInfersOverManyTicks() async {
        let o = await armedTimer(interval: 0.03)
        let assistantBefore = o.conversation.filter(\.isAssistant).count
        // Let many intervals elapse — repeatedly draining the parked frame so each tick re-parks.
        for _ in 0..<5 {
            _ = await o.waitUntil { o.hasPendingLiveFrame }
            _ = o.takePendingLiveFrame()
        }
        XCTAssertEqual(o.conversation.filter(\.isAssistant).count, assistantBefore,
                       "the timer never starts a turn — auto-respond is a separate, off control")
    }

    // MARK: Manual mode never starts a loop (byte-identical to slice 4)

    func testTimerDoesNotStartInManualMode() async {
        let o = makeOrchestrator()
        o.beginCapture()
        _ = await o.waitForResult("a")
        o.livePolicy = LivePolicy(refresh: .manual, timerInterval: 0.05)
        o.liveCoordinator.startTimerLoopIfNeeded()
        let parked = await o.waitUntil(timeout: 0.4) { o.hasPendingLiveFrame }
        XCTAssertFalse(parked, "manual mode runs no loop — identical to pre-timer behavior")
    }

    // MARK: The real arm() path starts the loop from settings

    func testArmWithTimerSettingStartsTheLoop() async {
        var s = PeeknookSettings(textModel: "x")
        s.liveRefreshTriggerRaw = "timer"
        s.liveTimerIntervalSeconds = 1   // the clamp floor — first park lands ~1s after arm
        let o = makeOrchestrator(s)
        o.beginCapture()
        _ = await o.waitForResult("a")
        o.armLive()
        XCTAssertEqual(o.livePolicy?.refresh, .timer)
        XCTAssertEqual(o.livePolicy?.timerInterval, 1, "the interval is snapshotted at arm")
        let parked = await o.waitUntil(timeout: 2) { o.hasPendingLiveFrame }
        XCTAssertTrue(parked, "arming a timer-mode session starts the loop and parks within an interval")
    }

    // MARK: Pause at critical, resume when pressure drops

    func testTimerPausesAtCriticalAndResumes() async {
        let o = makeOrchestrator()
        o.beginCapture()
        _ = await o.waitForResult("a")
        o.lastPromptTokens = 1000
        o.contextWindow = 1000   // contextFraction 1.0 → .critical from the very first tick
        XCTAssertTrue(o.isContextBlocked, "precondition: critical context")
        o.livePolicy = LivePolicy(refresh: .timer, timerInterval: 0.05)
        o.liveCoordinator.startTimerLoopIfNeeded()

        let parkedWhileCritical = await o.waitUntil(timeout: 0.5) { o.hasPendingLiveFrame }
        XCTAssertFalse(parkedWhileCritical, "the timer pauses at critical — it never parks")

        o.lastPromptTokens = 100   // contextFraction 0.1 → .normal: the timer resumes
        let resumed = await o.waitUntil(timeout: 2) { o.hasPendingLiveFrame }
        XCTAssertTrue(resumed, "the timer resumes parking once pressure falls below critical")
    }

    // MARK: Survives in-thread abort (Retake / Add image), dies only on disarm

    func testTimerSurvivesAbortSessionWork() async {
        let o = await armedTimer()
        _ = await o.waitUntil { o.hasPendingLiveFrame }
        _ = o.takePendingLiveFrame()
        o.abortSessionWork()   // exactly what Retake / Add image invoke
        XCTAssertTrue(o.isLiveArmed, "abortSessionWork does not disarm")
        let parkedAgain = await o.waitUntil(timeout: 1) { o.hasPendingLiveFrame }
        XCTAssertTrue(parkedAgain, "the timer keeps ticking across an in-thread abort")
    }

    func testTimerDiesOnDisarm() async {
        let o = await armedTimer()
        _ = await o.waitUntil { o.hasPendingLiveFrame }
        o.stopLive()
        XCTAssertNil(o.livePolicy, "disarm clears the policy")
        XCTAssertFalse(o.hasPendingLiveFrame, "disarm clears any parked frame + its mirror")
        let parkedAfterStop = await o.waitUntil(timeout: 0.5) { o.hasPendingLiveFrame }
        XCTAssertFalse(parkedAfterStop, "the timer is cancelled on disarm — no further parks")
    }

    // MARK: Relaunch cannot leak a timer (the armed policy is transient)

    func testRelaunchDoesNotLeakTimer() async {
        var s = PeeknookSettings(textModel: "x")
        s.liveEnabled = true
        s.liveRefreshTriggerRaw = "timer"   // a persisted timer preference…
        let o = makeOrchestrator(s)
        o.beginCapture()
        _ = await o.waitForResult("a")       // …answered, but the user never re-armed after "relaunch"
        XCTAssertNil(o.livePolicy, "a fresh session starts disarmed regardless of the persisted preference")
        let parked = await o.waitUntil(timeout: 0.5) { o.hasPendingLiveFrame }
        XCTAssertFalse(parked, "no arm → no timer; the persisted preference is inert until the user arms")
    }

    // MARK: A mid-session trigger flip is inert (the snapshot-at-arm contract)

    func testMidSessionTriggerFlipIsInert() async {
        // Arm in MANUAL mode (no loop), then flip the SETTING to timer. The running session keeps its
        // arm-time snapshot, so no loop starts until the next arm. Pins the snapshot contract so a future
        // change can't "fix" this by reading live settings in the loop and reintroduce a start path
        // outside arm() (which would be a timer that can outlive its expected lifecycle).
        let o = makeOrchestrator()
        o.beginCapture()
        _ = await o.waitForResult("a")
        o.armLive()   // manual default → no loop
        XCTAssertEqual(o.livePolicy?.refresh, .manual)
        o.settings.liveRefreshTriggerRaw = "timer"   // user flips the setting while armed
        let parked = await o.waitUntil(timeout: 0.4) { o.hasPendingLiveFrame }
        XCTAssertFalse(parked, "flipping the setting mid-session does not retune the running session")
        XCTAssertEqual(o.livePolicy?.refresh, .manual, "the armed snapshot is unchanged until re-arm")
    }

    // MARK: Regression — a failing capture keeps the loop ticking at BOUNDED frequency (no busy-spin)

    func testFailingTimerCaptureKeepsTickingBounded() async {
        // The pacing clock advances on every park ATTEMPT, not only on a successful stamp — so a capture
        // that keeps failing (e.g. revoked Screen Recording) retries about once per interval, NOT on every
        // wake. A regression guard for the busy-spin a `lastLiveRefreshAt`-only clock would cause.
        let provider = CountingFailProvider()
        let o = makeOrchestrator(provider: provider)
        o.beginCapture()
        _ = await o.waitForResult("a")   // call #1 succeeds → result
        o.livePolicy = LivePolicy(refresh: .timer, timerInterval: 0.1)
        o.liveCoordinator.startTimerLoopIfNeeded()

        let noticed = await o.waitUntil { o.lastNotice == .liveRefreshFailed }
        XCTAssertTrue(noticed, "a failing timer capture surfaces the transient notice and stays armed")
        XCTAssertTrue(o.isLiveArmed, "a failing capture never disarms the session")

        // Let ~0.6s elapse and count the failed attempts. At a 0.1s interval that is ~6 — a busy-spin
        // would be hundreds/thousands. Assert a generous bound that still cleanly separates the two.
        _ = await o.waitUntil(timeout: 0.6) { false }   // negative wait: just let time pass
        let failedAttempts = provider.callCount - 1      // minus the initial success
        XCTAssertGreaterThanOrEqual(failedAttempts, 1, "the loop keeps retrying — it does not freeze")
        XCTAssertLessThan(failedAttempts, 40, "the retry is interval-paced, not a main-actor busy-spin")
        XCTAssertTrue(o.isLiveArmed, "still armed after the retry window")
    }

    // MARK: Anti-graft — a refresh/timer grab whose capture STRADDLES a Retake is dropped, not parked

    /// The timer fires `refresh()` every interval, so a Retake landing while a park's capture is mid-`await`
    /// is now routine (not a rare manual coincidence). Such a grab must be DROPPED — the `.fresh` Retake
    /// replaced the thread, so parking the pre-Retake screenshot would graft a stale frame that "Answer
    /// now" / a follow-up could fold onto the new thread. Exercised here through the manual `refreshLive()`
    /// path (the same generation-guarded `refresh()` the timer drives) for determinism, via a gated provider
    /// that holds the capture mid-flight until both the refresh grab and the Retake grab are in flight.
    func testRefreshCaptureStraddlingRetakeIsDroppedNotGrafted() async {
        let provider = GatedCaptureProvider()
        let o = makeOrchestrator(provider: provider)
        o.beginCapture()
        _ = await o.waitForResult("a")        // call #1 — not gated yet
        o.armLive()
        provider.activateGate()               // subsequent captures block until released, in order
        o.refreshLive()                       // the refresh grab (#1) starts and blocks mid-await
        _ = await o.waitUntil { provider.startedCount == 1 }
        o.retake()                            // bumps the session generation (G0->G1) synchronously, then
        _ = await o.waitUntil { provider.startedCount == 2 }   // the Retake's grab (#2) blocks too

        // Release ONLY the refresh grab and KEEP the Retake's grab blocked. The Retake therefore cannot
        // commit / resetConversation while we observe — so a buggy (unguarded) park would stay VISIBLE
        // the whole window instead of being scrubbed by the Retake's clear (the masking that made a
        // release-both test catch the regression only ~half the time). The guard drops it; the slot stays nil.
        provider.release(upTo: 1)
        let grafted = await o.waitUntil(timeout: 0.5) { o.lifecycle.pendingLiveCapture != nil }
        XCTAssertFalse(grafted, "a refresh whose capture straddled the Retake is dropped, not parked onto the replaced thread")
        XCTAssertFalse(o.hasPendingLiveFrame, "the mirror stays low")

        provider.release(upTo: 2)             // let the Retake finish into a clean replaced thread
        let retook = await o.waitUntil {
            o.conversation.filter(\.isImage).count == 1 && o.conversation.last?.isAssistant == true
        }
        XCTAssertTrue(retook, "the Retake produced a clean single-image thread")
        XCTAssertNil(o.lifecycle.pendingLiveCapture, "still no stale frame after the Retake settles")
        XCTAssertTrue(o.isLiveArmed, "a Retake keeps Live armed")
    }
}

/// Holds every capture mid-`await` once the gate is active, releasing them IN ORDER so a test can
/// deterministically resume an earlier grab while a later one stays blocked. Each gated capture takes the
/// next index (1, 2, …) and proceeds only once `release(upTo:)` covers it. The first (pre-gate) capture
/// reaches an answered result; gated captures block on a short poll. Ordered release is what makes the
/// straddling-Retake regression test catch a reverted guard every time (not ~half the time): the Retake's
/// grab is held blocked while the test observes, so its `resetConversation` can't scrub a buggy park.
private final class GatedCaptureProvider: CaptureProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _gateActive = false
    private var _releasedUpTo = 0
    private var _startedCount = 0

    /// How many gated captures have begun blocking — lets a test wait for an in-flight grab.
    var startedCount: Int { lock.lock(); defer { lock.unlock() }; return _startedCount }
    func activateGate() { lock.lock(); _gateActive = true; lock.unlock() }
    /// Release every gated grab with index <= `n` (monotonic — a later call can only widen the window).
    func release(upTo n: Int) { lock.lock(); _releasedUpTo = max(_releasedUpTo, n); lock.unlock() }

    func capture(scope: CaptureScope, quick: Bool, encoding: CaptureEncodingParams) async throws -> CaptureResult {
        lock.lock()
        let active = _gateActive
        var index = 0
        if active { _startedCount += 1; index = _startedCount }
        lock.unlock()
        if active {
            while true {
                lock.lock(); let released = _releasedUpTo >= index; lock.unlock()
                if released { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        return CaptureResult(
            text: "s", sourceLabel: "s",
            screenshotBase64: StubCaptureProvider.defaultScreenshotBase64, ground: .screen
        )
    }
}

private struct LiveTimerTestError: Error {}

/// Succeeds on the FIRST capture (to reach `.result`), then fails every subsequent capture while
/// counting calls — so a test can both reach an armed result and measure the timer's retry frequency.
private final class CountingFailProvider: CaptureProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0

    var callCount: Int { lock.lock(); defer { lock.unlock() }; return _calls }

    func capture(scope: CaptureScope, quick: Bool, encoding: CaptureEncodingParams) async throws -> CaptureResult {
        lock.lock(); _calls += 1; let n = _calls; lock.unlock()
        guard n == 1 else { throw LiveTimerTestError() }
        return CaptureResult(
            text: "s", sourceLabel: "s",
            screenshotBase64: StubCaptureProvider.defaultScreenshotBase64, ground: .screen
        )
    }
}
