// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// Live Session v1 slice 7: auto-respond. When an armed `.timer` session refreshes AND the user opted into
/// auto-respond, the frame is promoted into an answer automatically — rate-capped, paused at critical, and
/// timer-only (a manual Refresh always parks). Auto-respond OFF (the default) is byte-identical to slice 6.
/// Like the slice-6 timer tests, these drive the REAL loop with a sub-second interval via the white-box seam
/// (assign `livePolicy` directly to bypass arm's >= 1 clamp, then `startTimerLoopIfNeeded()`).
@MainActor
final class LiveAutoRespondTests: XCTestCase {

    private func makeOrchestrator(
        _ engine: any InferenceEngine = MockInferenceEngine(tokens: ["a"])
    ) -> SessionOrchestrator {
        SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "x"),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "s")]),
            inference: engine
        )
    }

    /// Answered, then armed with a fast `.timer` policy and the loop started (no inference yet).
    private func armedTimer(autoRespond: Bool, rateCap: TimeInterval, interval: TimeInterval = 0.05,
                            engine: any InferenceEngine = MockInferenceEngine(tokens: ["a"])) async -> SessionOrchestrator {
        let o = makeOrchestrator(engine)
        o.beginCapture()
        _ = await o.waitForResult("a")
        o.livePolicy = LivePolicy(refresh: .timer, autoRespond: autoRespond, rateCap: rateCap, timerInterval: interval)
        o.liveCoordinator.startTimerLoopIfNeeded()
        return o
    }

    private func assistantCount(_ o: SessionOrchestrator) -> Int { o.conversation.filter(\.isAssistant).count }

    // MARK: Off → byte-identical to slice 6 (parks, never answers)

    func testAutoRespondOffStillOnlyParks() async {
        let o = await armedTimer(autoRespond: false, rateCap: 0, interval: 0.03)
        let answersBefore = assistantCount(o)
        for _ in 0..<5 {   // drain several parks so each tick re-parks
            _ = await o.waitUntil { o.hasPendingLiveFrame }
            _ = o.takePendingLiveFrame()
        }
        XCTAssertEqual(assistantCount(o), answersBefore, "auto-respond off → the timer only parks, never answers")
        XCTAssertNil(o.lastAutoResponseAt, "off → the rate clock is never stamped")
    }

    // MARK: On → promotes a fresh frame into an answer (never parks the answered frame)

    func testAutoRespondOnAnswersAfterRefresh() async {
        let o = await armedTimer(autoRespond: true, rateCap: 100)   // one answer, then rate-capped
        let imagesBefore = o.conversation.filter(\.isImage).count
        let answered = await o.waitUntil {
            o.conversation.filter(\.isImage).count == imagesBefore + 1 && o.conversation.last?.isAssistant == true
        }
        XCTAssertTrue(answered, "auto-respond promotes the timer's frame into an answered image turn")
        XCTAssertNotNil(o.lastAutoResponseAt, "an auto-answer stamps the rate clock")
        XCTAssertTrue(o.isLiveArmed)
        if case .result = o.phase {} else { XCTFail("the auto-answer lands back in .result, got \(o.phase)") }
    }

    // MARK: Rate cap throttles a fast timer

    func testRateCapThrottlesFastTimer() async {
        let o = await armedTimer(autoRespond: true, rateCap: 100, interval: 0.02)
        _ = await o.waitUntil { self.assistantCount(o) == 2 }   // the initial answer + one auto-answer
        let after = assistantCount(o)
        let second = await o.waitUntil(timeout: 0.5) { self.assistantCount(o) > after }
        XCTAssertFalse(second, "the rate cap blocks a second auto-answer within the window")
        o.lastAutoResponseAt = Date(timeIntervalSinceNow: -200)   // pretend the cap has long elapsed
        let third = await o.waitUntil { self.assistantCount(o) > after }
        XCTAssertTrue(third, "once the cap elapses, auto-respond answers again (the cap, not just the phase, is gating)")
    }

    // MARK: Pause at critical — parks (no answer), resumes when pressure drops

    func testAutoRespondPausesAtCriticalThenResumes() async {
        let o = makeOrchestrator()
        o.beginCapture()
        _ = await o.waitForResult("a")
        o.lastPromptTokens = 1000
        o.contextWindow = 1000   // contextFraction 1.0 → .critical
        o.livePolicy = LivePolicy(refresh: .timer, autoRespond: true, rateCap: 0, timerInterval: 0.05)
        o.liveCoordinator.startTimerLoopIfNeeded()

        let answeredAtCritical = await o.waitUntil(timeout: 0.5) { self.assistantCount(o) > 1 }
        XCTAssertFalse(answeredAtCritical, "auto-respond never answers at critical context (it would overflow)")

        o.lastPromptTokens = 100   // back to .normal
        let resumed = await o.waitUntil { self.assistantCount(o) > 1 }
        XCTAssertTrue(resumed, "auto-respond resumes once pressure falls below critical")
    }

    // MARK: A Retake must not let a fast tick dodge the rate cap

    func testRetakeDoesNotDodgeTheRateCap() async {
        let o = await armedTimer(autoRespond: true, rateCap: 100)
        _ = await o.waitUntil { self.assistantCount(o) == 2 }   // first auto-answer
        let stamp = o.lastAutoResponseAt
        XCTAssertNotNil(stamp)
        o.retake()   // .fresh replace — keeps Live armed
        let retook = await o.waitUntil { o.conversation.filter(\.isImage).count == 1 && o.conversation.last?.isAssistant == true }
        XCTAssertTrue(retook, "the Retake produced a clean single-image thread")
        XCTAssertEqual(o.lastAutoResponseAt, stamp, "resetConversation does NOT clear the rate clock — a Retake can't dodge the cap")
        XCTAssertTrue(o.isLiveArmed)
    }

    // MARK: A streaming auto-answer is never cancelled by a later tick

    func testAutoRespondNoMidAnswerCancellation() async {
        // A slow second answer streams over ~0.3s; ticks land while it is .inferring. rateCap dominates so
        // only one auto-answer is issued, and the phase guard no-ops the in-flight ticks — the streamed
        // answer must complete intact (never truncated by a cancelInferenceAndSuggestions from a later tick).
        let engine = ScriptedEngine(
            responsesPerCall: [["a1"], ["one ", "two ", "three ", "four ", "five"]],
            tokenDelayNanoseconds: 60_000_000
        )
        let o = makeOrchestrator(engine)
        o.beginCapture()
        _ = await o.waitForResult("a1")
        o.livePolicy = LivePolicy(refresh: .timer, autoRespond: true, rateCap: 100, timerInterval: 0.02)
        o.liveCoordinator.startTimerLoopIfNeeded()

        let completed = await o.waitUntil(timeout: 3) { o.lastAssistantText == "one two three four five" }
        XCTAssertTrue(completed, "the streaming auto-answer completes intact — no later tick cancels it mid-stream")
        XCTAssertEqual(assistantCount(o), 2, "the initial answer plus exactly one (rate-capped) auto-answer")
    }

    // MARK: Disarm cancels auto-respond and clears the rate clock

    func testAutoRespondDiesOnDisarm() async {
        let o = await armedTimer(autoRespond: true, rateCap: 0)
        _ = await o.waitUntil { self.assistantCount(o) >= 2 }
        o.stopLive()
        XCTAssertNil(o.livePolicy)
        XCTAssertNil(o.lastAutoResponseAt, "disarm clears the rate clock")
        let after = assistantCount(o)
        let more = await o.waitUntil(timeout: 0.5) { self.assistantCount(o) > after }
        XCTAssertFalse(more, "no further auto-answers after disarm")
    }

    // MARK: A timer tick whose capture straddles a concurrent USER answer parks, never drops

    /// Regression for the review-found race: a `.timer` tick's capture is in flight when the user presses
    /// "Answer now" (which promotes a parked frame and flips the phase to `.inferring`). When the tick
    /// resumes it must NOT stamp-then-`promote` (promote would bail on its `.result` guard, dropping the
    /// frame AND over-charging the rate clock) — it must fall through to a park, keeping the frame
    /// retrievable (slice-6 behavior). `rateCap: 0` isolates the post-await phase guard as the sole defense.
    func testAutoRespondTickDuringAUserAnswerParksInsteadOfDropping() async {
        let provider = GatedAutoRespondProvider()
        let engine = ScriptedEngine(
            responsesPerCall: [["a1"], ["s1 ", "s2 ", "s3 ", "s4 ", "s5"]],
            tokenDelayNanoseconds: 50_000_000   // the user's answer streams ~0.25s, staying .inferring
        )
        let o = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "x"),
            captureRegistry: GroundRegistry([.screen: provider]),
            inference: engine
        )
        o.beginCapture()
        _ = await o.waitForResult("a1")
        o.livePolicy = LivePolicy(refresh: .timer, autoRespond: true, rateCap: 0, timerInterval: 0.05)
        // Park a frame the user can answer from (this capture is pre-gate, so it succeeds), then gate.
        o.refreshLive()
        _ = await o.waitUntil { o.hasPendingLiveFrame }
        XCTAssertNil(o.lastAutoResponseAt)
        provider.activateGate()
        o.liveCoordinator.startTimerLoopIfNeeded()
        _ = await o.waitUntil { provider.startedCount == 1 }   // a timer tick's capture is suspended mid-await

        // The user answers from the parked frame; the slow answer flips phase to .inferring and holds there.
        o.answerLive()
        let inferring = await o.waitUntil { if case .inferring = o.phase { return true }; return false }
        XCTAssertTrue(inferring, "the user's answer is streaming")

        provider.release()   // the timer tick resumes WHILE the user answer is still .inferring
        let parked = await o.waitUntil { o.hasPendingLiveFrame }
        XCTAssertTrue(parked, "the racing tick parks its frame (retrievable) instead of silently dropping it")
        XCTAssertNil(o.lastAutoResponseAt, "the racing tick does not over-charge the rate clock for an answer that never fired")
    }

    // MARK: Timer-only scope — a manual Refresh never auto-answers, even with auto-respond on

    func testManualRefreshNeverAutoAnswers() async {
        let o = makeOrchestrator()
        o.beginCapture()
        _ = await o.waitForResult("a")
        // Auto-respond ON, but DON'T start the timer loop — exercise the manual (.manual trigger) path.
        o.livePolicy = LivePolicy(refresh: .timer, autoRespond: true, rateCap: 0, timerInterval: 0.05)
        let imagesBefore = o.conversation.filter(\.isImage).count
        o.refreshLive()   // the manual Refresh command / public path forwards .manual
        let parked = await o.waitUntil { o.hasPendingLiveFrame }
        XCTAssertTrue(parked, "a manual Refresh parks even when auto-respond is on")
        XCTAssertEqual(o.conversation.filter(\.isImage).count, imagesBefore, "a manual Refresh never auto-answers — timer-only scope")
        XCTAssertNil(o.lastAutoResponseAt, "a manual Refresh does not stamp the rate clock")
    }
}

/// Lets the first captures (pre-gate) succeed, then holds every later capture mid-`await` until released —
/// so a test can suspend a timer tick's grab, interleave a user action, and resume the grab deterministically.
private final class GatedAutoRespondProvider: CaptureProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _gateActive = false
    private var _released = false
    private var _startedCount = 0

    var startedCount: Int { lock.lock(); defer { lock.unlock() }; return _startedCount }
    func activateGate() { lock.lock(); _gateActive = true; lock.unlock() }
    func release() { lock.lock(); _released = true; lock.unlock() }

    func capture(scope: CaptureScope, quick: Bool, encoding: CaptureEncodingParams) async throws -> CaptureResult {
        lock.lock()
        let active = _gateActive
        if active { _startedCount += 1 }
        lock.unlock()
        if active {
            while true {
                lock.lock(); let released = _released; lock.unlock()
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
