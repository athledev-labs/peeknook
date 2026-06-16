// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// Live Session v1.3.1: an armed session can PERSIST across Done (opt-in `livePersistAcrossDone`, default
/// off). With it on, tapping Done returns to the idle home WITHOUT disarming — Resume re-enters the same
/// armed chat. While idle the session is QUIESCED (the timer and any in-flight capture leg are cancelled,
/// so nothing captures at idle) but the policy / rate clocks / parked frame are kept. Every OTHER exit
/// (New chat, switch/delete thread, purge, collapse/hide, explicit Stop) still disarms. Default off is
/// byte-identical to the MVP (Done disarms).
@MainActor
final class LivePersistAcrossDoneTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "peeknook.tests.livePersistAcrossDone")!
        defaults.removePersistentDomain(forName: "peeknook.tests.livePersistAcrossDone")
    }

    private func makeOrchestrator(
        persist: Bool = false,
        maxArmedSeconds: Double = 0,
        provider: any CaptureProviding = StubCaptureProvider(sampleText: "s")
    ) -> SessionOrchestrator {
        var settings = PeeknookSettings(textModel: "x")
        settings.liveEnabled = true
        settings.livePersistAcrossDone = persist
        settings.liveMaxArmedSeconds = maxArmedSeconds
        return SessionOrchestrator(
            settings: settings,
            captureRegistry: GroundRegistry([.screen: provider]),
            inference: MockInferenceEngine(tokens: ["a"])
        )
    }

    /// Drive one capture to `.result` (the only state Live arms from) and arm a manual session.
    private func armedManual(persist: Bool) async -> SessionOrchestrator {
        let o = makeOrchestrator(persist: persist)
        o.beginCapture()
        _ = await o.waitForResult("a")
        o.armLive()
        return o
    }

    /// Arm a fast `.timer` loop (arm() clamps the interval to >= 1s, so assign the policy directly).
    /// `expiresAt` injects a WS-2 auto-disarm deadline (nil = no cap, today's behavior).
    private func armedTimer(
        persist: Bool,
        interval: TimeInterval = 0.05,
        expiresAt: Date? = nil
    ) async -> SessionOrchestrator {
        let o = makeOrchestrator(persist: persist)
        o.beginCapture()
        _ = await o.waitForResult("a")
        o.livePolicy = LivePolicy(refresh: .timer, timerInterval: interval, expiresAt: expiresAt)
        o.liveCoordinator.startTimerLoopIfNeeded()
        return o
    }

    // MARK: Default (persist off) is byte-identical — Done disarms

    func testFinishChatPersistOffDisarms() async {
        let o = await armedManual(persist: false)
        o.refreshLive()
        _ = await o.waitUntil { o.hasPendingLiveFrame }   // park a frame so we can prove it is cleared
        o.finishChat()
        XCTAssertNil(o.livePolicy, "default Done disarms (the MVP rule)")
        XCTAssertNil(o.lastLiveRefreshAt)
        XCTAssertNil(o.lastAutoResponseAt)
        XCTAssertFalse(o.hasPendingLiveFrame, "disarm clears the parked frame + its mirror")
        XCTAssertNil(o.lifecycle.pendingLiveCapture)
        if case .idle = o.phase {} else { XCTFail("Done returns to idle, got \(o.phase)") }
    }

    // MARK: Persist on — Done keeps the session armed at idle

    func testFinishChatPersistOnKeepsArmedAtIdle() async {
        let o = await armedManual(persist: true)
        o.lastAutoResponseAt = Date()           // a rate clock that must survive the idle round-trip
        let policyBefore = o.livePolicy
        let clockBefore = o.lastAutoResponseAt
        o.finishChat()
        XCTAssertTrue(o.isLiveArmed, "persist keeps the session armed across Done")
        XCTAssertEqual(o.livePolicy, policyBefore, "the policy is untouched (quiesce, not teardown)")
        XCTAssertEqual(o.lastAutoResponseAt, clockBefore, "the rate clock survives the idle gap")
        if case .idle = o.phase {} else { XCTFail("Done still returns to idle, got \(o.phase)") }
    }

    func testFinishChatPersistOnKeepsParkedFrame() async {
        let o = await armedManual(persist: true)
        o.refreshLive()
        _ = await o.waitUntil { o.hasPendingLiveFrame }
        o.finishChat()
        XCTAssertTrue(o.hasPendingLiveFrame, "persist keeps a pre-Done parked frame (symmetric with keeping the thread)")
        XCTAssertNotNil(o.lifecycle.pendingLiveCapture)
        XCTAssertTrue(o.isLiveArmed)
    }

    // MARK: Quiesce — no capture happens while idle

    func testFinishChatPersistOnQuiescesTimerNoNewParkAtIdle() async {
        let o = await armedTimer(persist: true)
        _ = await o.waitUntil { o.hasPendingLiveFrame }   // the loop is provably running
        _ = o.takePendingLiveFrame()
        o.finishChat()
        XCTAssertTrue(o.isLiveArmed, "persist keeps it armed")
        let parkedAtIdle = await o.waitUntil(timeout: 0.4) { o.hasPendingLiveFrame }
        XCTAssertFalse(parkedAtIdle, "the timer is quiesced at idle — no new park (cancelLiveWork + the .result guards)")
    }

    func testIdleArmedSessionDoesNotCapture() async {
        let o = await armedTimer(persist: true)
        _ = await o.waitUntil { o.hasPendingLiveFrame }
        _ = o.takePendingLiveFrame()
        o.finishChat()
        let imagesBefore = o.conversation.filter(\.isImage).count
        // Every Live op no-ops at idle (each guards `.result`); the defense-in-depth post-await guard
        // also holds. None of these may capture, park, or start a turn while at the home screen.
        o.refreshLive()
        o.answerLive()
        o.updateAndAskLive()
        let captured = await o.waitUntil(timeout: 0.4) { o.hasPendingLiveFrame || o.conversation.filter(\.isImage).count != imagesBefore }
        XCTAssertFalse(captured, "no capture or inference runs while idle")
        XCTAssertNil(o.lifecycle.pendingLiveCapture)
        if case .idle = o.phase {} else { XCTFail("still idle, got \(o.phase)") }
    }

    // MARK: The load-bearing race — an in-flight grab straddling Done is dropped, never parked at idle

    /// The sharpest privacy edge: the timer's `.park` grab suspends mid-`await provider.capture(...)`
    /// WITHOUT bumping the session generation, and `finishChat()` does not bump it either. A naive
    /// timer-only cancel would let the suspended grab resume at idle, capture the home screen, and PARK it —
    /// a capture-while-idle. TWO independent barriers prevent it and this test verifies the OUTCOME (no park
    /// at idle): (1) the persist branch routes through `cancelLiveWork()`, which cancels the in-flight refresh
    /// leg so its returned capture is dropped by the `!Task.isCancelled` guard; (2) the defense-in-depth
    /// `if case .idle` guard after the await drops any grab that still resolves while the phase is `.idle`.
    func testFinishChatPersistOnStraddleGrabIsDroppedNotParkedAtIdle() async {
        let provider = GatedCaptureProvider()
        let o = makeOrchestrator(persist: true, provider: provider)
        o.beginCapture()
        _ = await o.waitForResult("a")        // call #1 — not gated yet
        o.armLive()
        provider.activateGate()               // subsequent captures block until released
        o.refreshLive()                       // the refresh grab starts and blocks mid-await
        _ = await o.waitUntil { provider.startedCount == 1 }

        o.finishChat()                        // Done while the grab is in flight — quiesces (cancelLiveWork)
        provider.release(upTo: 1)             // let the (now-cancelled) grab return

        let parked = await o.waitUntil(timeout: 0.5) { o.lifecycle.pendingLiveCapture != nil }
        XCTAssertFalse(parked, "a grab straddling Done is dropped, never parked onto the idle home")
        XCTAssertFalse(o.hasPendingLiveFrame, "the mirror stays low")
        XCTAssertTrue(o.conversation.filter(\.isImage).count == 1, "no extra image turn — only the original capture")
        XCTAssertTrue(o.isLiveArmed, "persist keeps it armed")
        if case .idle = o.phase {} else { XCTFail("still idle, got \(o.phase)") }
    }

    // MARK: Resume re-enters the armed session cleanly

    func testResumeChatReentersArmedResult() async {
        let o = await armedManual(persist: true)
        o.lastAutoResponseAt = Date()
        let clockBefore = o.lastAutoResponseAt
        let policyBefore = o.livePolicy
        o.finishChat()
        o.resumeChat()
        if case .result = o.phase {} else { XCTFail("Resume re-enters .result, got \(o.phase)") }
        XCTAssertTrue(o.isLiveArmed)
        XCTAssertEqual(o.livePolicy, policyBefore, "no re-arm, no policy change")
        XCTAssertEqual(o.lastAutoResponseAt, clockBefore, "no rate-clock reset on resume")
    }

    func testResumeRestartsTimerParkingInResultNotInstantly() async {
        let o = await armedTimer(persist: true)
        _ = await o.waitUntil { o.hasPendingLiveFrame }
        _ = o.takePendingLiveFrame()
        o.finishChat()
        let parkedAtIdle = await o.waitUntil(timeout: 0.3) { o.hasPendingLiveFrame }
        XCTAssertFalse(parkedAtIdle, "quiesced while idle")

        o.resumeChat()
        XCTAssertFalse(o.hasPendingLiveFrame, "the restart re-seeds the clock — the first park is one interval later, not instant")
        let parkedAfterResume = await o.waitUntil(timeout: 1) { o.hasPendingLiveFrame }
        XCTAssertTrue(parkedAfterResume, "resume restarts the timer; it parks again once back in .result")
    }

    /// Regression: re-entering a persisted-armed `.timer` thread via a CAPTURE from idle (the ⌘⇧P / Capture
    /// vector, not Resume) must restart the auto-refresh loop that the Done-quiesce cancelled — otherwise the
    /// Live chip lingers on a thread whose timer is permanently dead until an explicit Stop + re-arm.
    func testCaptureFromIdleRestartsTheQuiescedTimer() async {
        let o = await armedTimer(persist: true)
        _ = await o.waitUntil { o.hasPendingLiveFrame }
        _ = o.takePendingLiveFrame()
        o.finishChat()                              // quiesce: timer cancelled, still armed at idle
        let imagesBefore = o.conversation.filter(\.isImage).count
        o.beginCapture()                            // capture from idle — re-enters via .addToChat, NOT Resume
        let reentered = await o.waitUntil {
            o.conversation.filter(\.isImage).count == imagesBefore + 1 && o.conversation.last?.isAssistant == true
        }
        XCTAssertTrue(reentered, "the capture continues the thread and lands back in .result")
        XCTAssertTrue(o.isLiveArmed, "the persisted session stays armed across a capture re-entry")
        let parkedAgain = await o.waitUntil(timeout: 1) { o.hasPendingLiveFrame }
        XCTAssertTrue(parkedAgain, "the auto-refresh loop is restored on capture re-entry, not left dead")
    }

    func testResumeManualTriggerStartsNoTimer() async {
        let o = await armedManual(persist: true)   // manual trigger → no loop
        o.finishChat()
        o.resumeChat()
        XCTAssertTrue(o.isLiveArmed)
        if case .result = o.phase {} else { XCTFail("Resume re-enters .result, got \(o.phase)") }
        let parked = await o.waitUntil(timeout: 0.4) { o.hasPendingLiveFrame }
        XCTAssertFalse(parked, "a manual-trigger session has no timer to restart — Resume parks nothing on its own")
    }

    func testParkedFrameSurvivesDoneThenAnswerableAfterResume() async {
        let o = await armedManual(persist: true)
        o.refreshLive()
        _ = await o.waitUntil { o.hasPendingLiveFrame }
        o.finishChat()
        o.resumeChat()
        let imagesBefore = o.conversation.filter(\.isImage).count
        o.answerLive()   // promote the frame that survived Done
        let answered = await o.waitUntil {
            o.conversation.filter(\.isImage).count == imagesBefore + 1 && o.conversation.last?.isAssistant == true
        }
        XCTAssertTrue(answered, "the frame parked before Done promotes into an answered turn after Resume")
    }

    // MARK: Every non-Done exit still disarms (with persist ON)

    func testDismissResultDisarmsWithPersistOn() async {
        let o = await armedManual(persist: true)
        o.dismissResult()   // New chat / discard
        XCTAssertNil(o.livePolicy, "New chat disarms regardless of persist")
        XCTAssertFalse(o.hasPendingLiveFrame)
    }

    func testPurgeDisarmsWithPersistOn() async {
        let o = await armedManual(persist: true)
        o.purgeAllConversations()
        XCTAssertNil(o.livePolicy, "purge disarms regardless of persist")
        XCTAssertFalse(o.hasPendingLiveFrame)
    }

    func testHostCollapseDisarmsWithPersistOn() async {
        let o = await armedTimer(persist: true)
        _ = await o.waitUntil { o.hasPendingLiveFrame }
        o.stopLiveSession()   // the exact call onCompact / onHide / prepareForSwitchAway make
        XCTAssertNil(o.livePolicy, "collapse/hide disarms regardless of persist")
        XCTAssertFalse(o.hasPendingLiveFrame)
        let parkedAfter = await o.waitUntil(timeout: 0.4) { o.hasPendingLiveFrame }
        XCTAssertFalse(parkedAfter, "the timer is cancelled on disarm")
    }

    func testExplicitStopLiveDisarmsFromIdle() async {
        let o = await armedTimer(persist: true)
        _ = await o.waitUntil { o.hasPendingLiveFrame }
        _ = o.takePendingLiveFrame()
        o.finishChat()                 // armed at idle
        XCTAssertTrue(o.isLiveArmed)
        o.stopLive()                   // the idle Stop control
        XCTAssertNil(o.livePolicy, "Stop disarms a persisted-armed-at-idle session")
        let parkedAfter = await o.waitUntil(timeout: 0.4) { o.hasPendingLiveFrame }
        XCTAssertFalse(parkedAfter, "no further park after Stop")
    }

    // MARK: Disabling the feature flag disarms a persisted session (it can't outlive the flag)

    func testSetLiveEnabledFalseDisarmsPersistedSession() async {
        // A real controller over a bare orchestrator (nil `setup` → capture isn't readiness-gated). The
        // controller's own setup is used only for its persist/sync; the orchestrator drives capture freely.
        let o = makeOrchestrator(persist: true)   // liveEnabled = true, livePersistAcrossDone = true
        let setup = SetupCoordinator(settings: o.settings, defaults: defaults)
        let controller = PeekSettingsController(
            orchestrator: o, setup: setup, defaults: defaults, inference: MockInferenceEngine(tokens: ["a"])
        )
        o.beginCapture()
        _ = await o.waitForResult("a")
        o.armLive()
        o.finishChat()                 // armed at idle via persist
        XCTAssertTrue(o.isLiveArmed)

        controller.setLiveEnabled(false)
        XCTAssertFalse(o.isLiveArmed, "turning the feature off disarms a session armed-at-idle (no zombie arm)")

        // Re-enabling does not spuriously arm.
        controller.setLiveEnabled(true)
        XCTAssertFalse(o.isLiveArmed, "re-enabling the flag does not arm anything")
    }

    // MARK: Idle command bar — Stop shows only while armed, and is non-hideable

    func testIdleBarShowsStopWhenArmedAndIsNonHideable() {
        let layout = CommandLayout.screenDefault
        let stop = layout.commands.first { $0.id == "idle.stopLive" }
        XCTAssertEqual(stop?.action, .stopLive)
        XCTAssertEqual(stop?.isCustomizable, false, "Layout must never hide the only disarm control")

        let armed = CommandBarContext(isLiveArmed: true, enabledModules: [.screenCapture, .liveSession])
        XCTAssertTrue(layout.visibleCommands(.idle, in: armed).map(\.id).contains("idle.stopLive"),
                      "armed: the idle Stop shows")

        let disarmed = CommandBarContext(isLiveArmed: false, enabledModules: [.screenCapture, .liveSession])
        XCTAssertFalse(layout.visibleCommands(.idle, in: disarmed).map(\.id).contains("idle.stopLive"),
                       "not armed: the idle bar is byte-identical (no Stop)")

        // A hostile hidden-override on the idle Stop is ignored at the apply seam (non-customizable).
        let hostile = layout.forPlacement(.idle, applying: [CommandOverride(id: "idle.stopLive", hidden: true)])
        XCTAssertTrue(hostile.map(\.id).contains("idle.stopLive"), "a hand-edited hide cannot strip the idle Stop")
    }

    // MARK: WS-2 — the auto-disarm cap composes with persist-across-Done without weakening either rule

    /// The load-bearing privacy guarantee, re-verified WITH a cap set: an armed session quiesced across
    /// Done still captures nothing at the idle home (the cap extends lifetime, it does not add idle capture).
    func testIdleArmedSessionDoesNotCaptureWithCapOn() async {
        let o = await armedTimer(persist: true, expiresAt: Date().addingTimeInterval(3600))
        _ = await o.waitUntil { o.hasPendingLiveFrame }
        _ = o.takePendingLiveFrame()
        o.finishChat()
        XCTAssertTrue(o.isLiveArmed, "persist + cap keeps it armed at idle")
        let imagesBefore = o.conversation.filter(\.isImage).count
        o.refreshLive()
        o.answerLive()
        o.updateAndAskLive()
        let captured = await o.waitUntil(timeout: 0.4) {
            o.hasPendingLiveFrame || o.conversation.filter(\.isImage).count != imagesBefore
        }
        XCTAssertFalse(captured, "no capture or inference runs while idle, even with a cap set")
        XCTAssertNil(o.lifecycle.pendingLiveCapture)
        if case .idle = o.phase {} else { XCTFail("still idle, got \(o.phase)") }
    }

    /// Host collapse / hide / switch-away stay FULL disarms with a cap on — the cap extends ONLY Done.
    /// This keeps the existing host kill-path contract intact (the design's explicit non-exemption).
    func testHostCollapseStillFullyDisarmsWithCapOn() async {
        let o = await armedTimer(persist: true, expiresAt: Date().addingTimeInterval(3600))
        _ = await o.waitUntil { o.hasPendingLiveFrame }
        o.stopLiveSession()   // the exact call onCompact / onHide / prepareForSwitchAway make
        XCTAssertNil(o.livePolicy, "collapse/hide disarms regardless of the cap")
        XCTAssertFalse(o.hasPendingLiveFrame)
        let parkedAfter = await o.waitUntil(timeout: 0.4) { o.hasPendingLiveFrame }
        XCTAssertFalse(parkedAfter, "the timer is cancelled on disarm")
    }

    /// A session extended past Done is still BOUNDED by the deadline: resuming after it has passed
    /// auto-disarms at once (the loop's first decide() returns .expire). Proves the extended lifetime
    /// can never become indefinite. Built deterministically: arm with a FUTURE deadline, quiesce (which
    /// cancels the loop), then wind the deadline into the past while idle and resume.
    func testResumeAfterDeadlineAutoDisarms() async {
        let o = await armedTimer(persist: true, expiresAt: Date().addingTimeInterval(3600))
        _ = await o.waitUntil { o.hasPendingLiveFrame }
        _ = o.takePendingLiveFrame()
        o.finishChat()                 // quiesce at idle (timer cancelled), still armed
        XCTAssertTrue(o.isLiveArmed, "persist keeps it armed at idle until the deadline is re-checked")
        o.livePolicy?.expiresAt = Date().addingTimeInterval(-1)   // the cap elapsed while sitting idle
        o.resumeChat()                 // restarts the loop, which immediately sees now >= deadline
        let disarmed = await o.waitUntil(timeout: 2) { !o.isLiveArmed }
        XCTAssertTrue(disarmed, "resuming past the deadline auto-disarms — the extension is bounded, never indefinite")
        XCTAssertEqual(o.lastNotice, .liveEnded)
    }
}

/// Holds every capture mid-`await` once the gate is active, releasing them in order so a test can
/// deterministically resume an earlier grab while a later one stays blocked. Mirrors the helper in
/// `LiveTimerLoopTests` (private there, so duplicated for this file).
private final class GatedCaptureProvider: CaptureProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _gateActive = false
    private var _releasedUpTo = 0
    private var _startedCount = 0

    var startedCount: Int { lock.lock(); defer { lock.unlock() }; return _startedCount }
    func activateGate() { lock.lock(); _gateActive = true; lock.unlock() }
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
