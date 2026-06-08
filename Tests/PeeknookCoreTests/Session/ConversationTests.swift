// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// Records each `InferenceRequest` and replies with a scripted token list per call, so a test
/// can assert what history the orchestrator replayed on a follow-up.
final class ScriptedEngine: InferenceEngine, @unchecked Sendable {
    private(set) var requests: [InferenceRequest] = []
    private(set) var suggestionRequests: [InferenceRequest] = []
    private let responsesPerCall: [[String]]
    private var callIndex = 0
    /// Canned suggestion-pass result.
    var followUps: [String] = []
    var inferenceStats: InferenceStats?
    var followUpStats: InferenceStats?
    var contextWindow: Int?
    /// Whether `warmUp` reports the model as loaded (drives prewarm warmth tests).
    var warmUpSucceeds = true

    init(responsesPerCall: [[String]]) {
        self.responsesPerCall = responsesPerCall
    }

    func health(baseURL: String, model: String, acceptInsecureRemote: Bool) async -> InferenceHealth { .ready }

    func warmUp(model: String, baseURL: String, acceptInsecureRemote: Bool) async -> Bool { warmUpSucceeds }

    func contextLength(model: String, baseURL: String, acceptInsecureRemote: Bool) async -> Int? { contextWindow }

    func capabilities(model: String, baseURL: String, acceptInsecureRemote: Bool) async -> [String]? { nil }

    func generateFollowUps(request: InferenceRequest) async -> FollowUpGenerationResult {
        suggestionRequests.append(request)
        return FollowUpGenerationResult(suggestions: followUps, stats: followUpStats)
    }

    func stream(request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        // Called synchronously on the orchestrator's main actor, safe to record here.
        requests.append(request)
        let tokens = callIndex < responsesPerCall.count ? responsesPerCall[callIndex] : []
        callIndex += 1
        return AsyncThrowingStream { continuation in
            let task = Task {
                for token in tokens {
                    try? await Task.sleep(nanoseconds: 8_000_000)
                    if Task.isCancelled { break }
                    continuation.yield(.token(token))
                }
                continuation.yield(.completed(inferenceStats))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private extension ChatTurn {
    var assistantText: String? { if case .assistant(let t) = kind { return t } else { return nil } }
    var userText: String? { if case .user(let t) = kind { return t } else { return nil } }
    var isImage: Bool { if case .image = kind { return true } else { return false } }
}

@MainActor
final class ConversationTests: XCTestCase {
    private func makeOrchestrator(_ engine: ScriptedEngine) -> SessionOrchestrator {
        SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "x"),
            capture: StubCaptureProvider(sampleText: "screen"),
            inference: engine
        )
    }

    func testSessionBriefClearsOnNewChatAndReachesPrompt() async {
        let engine = ScriptedEngine(responsesPerCall: [["answer"]])
        let orchestrator = makeOrchestrator(engine)
        orchestrator.setSessionBrief("Chess themes only")
        orchestrator.beginCapture()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(engine.requests.first?.messages.first?.text.contains("Session brief") ?? false)
        orchestrator.startNewChat()
        XCTAssertEqual(orchestrator.sessionBrief, "")
    }

    func testFirstCaptureRecordsImageTurnAndAnswer() async {
        let engine = ScriptedEngine(responsesPerCall: [["first ", "answer"]])
        let orchestrator = makeOrchestrator(engine)

        orchestrator.beginCapture()
        try? await Task.sleep(nanoseconds: 200_000_000)

        guard case .result("first answer") = orchestrator.phase else {
            return XCTFail("Expected first answer, got \(orchestrator.phase)")
        }
        // The chat opens with the captured image, then the answer.
        XCTAssertEqual(orchestrator.conversation.count, 2)
        XCTAssertTrue(orchestrator.conversation[0].isImage)
        XCTAssertEqual(orchestrator.conversation[1].assistantText, "first answer")
        // First turn replays exactly one (grounding) user message.
        XCTAssertEqual(engine.requests.first?.messages.count, 1)
        XCTAssertEqual(engine.requests.first?.messages.first?.role, .user)
    }

    func testFollowUpAppendsTurnsAndReplaysHistory() async {
        let engine = ScriptedEngine(responsesPerCall: [["first ", "answer"], ["second ", "answer"]])
        let orchestrator = makeOrchestrator(engine)

        orchestrator.beginCapture()
        try? await Task.sleep(nanoseconds: 200_000_000)

        orchestrator.sendFollowUp("why?")
        try? await Task.sleep(nanoseconds: 200_000_000)

        guard case .result("second answer") = orchestrator.phase else {
            return XCTFail("Expected second answer, got \(orchestrator.phase)")
        }
        XCTAssertEqual(orchestrator.conversation.compactMap(\.assistantText), ["first answer", "second answer"])
        XCTAssertEqual(orchestrator.conversation.compactMap(\.userText), ["why?"])
        // The follow-up replays [grounding image, prior answer, new question].
        let msgs = engine.requests.last?.messages ?? []
        XCTAssertEqual(msgs.count, 3)
        XCTAssertEqual(msgs[0].role, .user)
        XCTAssertNotNil(msgs[0].imageBase64, "the sole screenshot still rides as base64")
        XCTAssertEqual(msgs[1], InferenceMessage(role: .assistant, text: "first answer"))
        XCTAssertEqual(msgs[2].role, .user)
        XCTAssertTrue(msgs[2].text.contains("why?"))
        XCTAssertTrue(msgs[2].text.contains("## Follow-up"))
    }

    func testAddImageExtendsChatWithSecondScreenshot() async {
        let engine = ScriptedEngine(responsesPerCall: [["first answer"], ["second answer"]])
        let orchestrator = makeOrchestrator(engine)

        orchestrator.beginCapture()
        try? await Task.sleep(nanoseconds: 200_000_000)
        orchestrator.addImage()
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Two image turns now coexist in one chat.
        let c = orchestrator.conversation
        XCTAssertEqual(c.count, 4)
        XCTAssertTrue(c[0].isImage)
        XCTAssertEqual(c[1].assistantText, "first answer")
        XCTAssertTrue(c[2].isImage)
        XCTAssertEqual(c[3].assistantText, "second answer")
        // The second answer's prompt replays both image groundings but only the latest base64.
        let msgs = engine.requests.last?.messages ?? []
        XCTAssertEqual(msgs.count, 3)
        XCTAssertEqual(msgs[0].role, .user)
        XCTAssertNil(msgs[0].imageBase64, "older screenshot is text-only")
        XCTAssertEqual(msgs[1], InferenceMessage(role: .assistant, text: "first answer"))
        XCTAssertEqual(msgs[2].role, .user)
        XCTAssertNotNil(msgs[2].imageBase64, "latest screenshot still rides as base64")
    }

    func testRetakeReplacesChat() async {
        let engine = ScriptedEngine(responsesPerCall: [["first answer"], ["second answer"]])
        let orchestrator = makeOrchestrator(engine)

        orchestrator.beginCapture()
        try? await Task.sleep(nanoseconds: 200_000_000)
        orchestrator.retake()
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Retake starts over: just the new image + its answer.
        XCTAssertEqual(orchestrator.conversation.count, 2)
        XCTAssertEqual(orchestrator.conversation.last?.assistantText, "second answer")
    }

    func testBeginCaptureFromResultExtendsChat() async {
        let engine = ScriptedEngine(responsesPerCall: [["first answer"], ["second answer"]])
        let orchestrator = makeOrchestrator(engine)

        orchestrator.beginCapture()
        try? await Task.sleep(nanoseconds: 200_000_000)
        orchestrator.beginCapture()
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(orchestrator.conversation.count, 4)
        XCTAssertEqual(orchestrator.conversation.compactMap(\.assistantText), ["first answer", "second answer"])
    }

    func testAddImageCountsAsACaptureButFollowUpDoesNot() async {
        let usage = UsageStore(defaults: UserDefaults(suiteName: "peeknook.test.addimage")!)
        usage.reset()
        let engine = ScriptedEngine(responsesPerCall: [["a"], ["b"], ["c"]])
        let orchestrator = makeOrchestrator(engine)
        orchestrator.usage = usage

        orchestrator.beginCapture()
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(usage.stats.captures, 1)

        orchestrator.sendFollowUp("more")   // no new image
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(usage.stats.captures, 1, "text follow-up is not a capture")

        orchestrator.addImage()             // new screenshot
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(usage.stats.captures, 2, "an added image is a new capture")
    }

    func testFollowUpDoesNotCountAsACapture() async {
        let usage = UsageStore(defaults: UserDefaults(suiteName: "peeknook.test.conversation")!)
        usage.reset()
        let engine = ScriptedEngine(responsesPerCall: [["a"], ["b"]])
        let orchestrator = makeOrchestrator(engine)
        orchestrator.usage = usage

        orchestrator.beginCapture()
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(usage.stats.captures, 1)

        orchestrator.sendFollowUp("more")
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(usage.stats.captures, 1, "a follow-up reuses the screenshot, not a new capture")
    }

    func testFollowUpIgnoredWithoutAnAnswer() {
        let orchestrator = makeOrchestrator(ScriptedEngine(responsesPerCall: [["a"]]))
        // No capture yet, phase is .idle, so a follow-up is a no-op.
        orchestrator.sendFollowUp("hello?")
        XCTAssertTrue(orchestrator.conversation.isEmpty)
        guard case .idle = orchestrator.phase else {
            return XCTFail("Expected idle, got \(orchestrator.phase)")
        }
    }

    func testStoppingFollowUpKeepsThread() async {
        let engine = ScriptedEngine(responsesPerCall: [["done"], ["slow ", "answer ", "tokens"]])
        let orchestrator = makeOrchestrator(engine)

        orchestrator.beginCapture()
        try? await Task.sleep(nanoseconds: 150_000_000)

        orchestrator.sendFollowUp("expand")
        try? await Task.sleep(nanoseconds: 12_000_000) // mid follow-up stream
        orchestrator.cancel()

        // The established answer survives; the unanswered question is dropped.
        XCTAssertEqual(orchestrator.conversation.compactMap(\.assistantText), ["done"])
        XCTAssertTrue(orchestrator.conversation.compactMap(\.userText).isEmpty)
        guard case .result("done") = orchestrator.phase else {
            return XCTFail("Expected to fall back to the first answer, got \(orchestrator.phase)")
        }
    }

    func testSuggestionsArriveFromSeparatePassWithoutPollutingAnswer() async {
        // The answer stream and the suggestion pass are independent, the answer is never
        // mutated by suggestion handling.
        let engine = ScriptedEngine(responsesPerCall: [["The error is a nil unwrap."]])
        engine.followUps = ["How do I fix it?", "What line is it on?"]
        let orchestrator = makeOrchestrator(engine)

        orchestrator.beginCapture()
        try? await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(orchestrator.conversation.last?.assistantText, "The error is a nil unwrap.")
        XCTAssertEqual(orchestrator.suggestedFollowUps, ["How do I fix it?", "What line is it on?"])
        guard case .result("The error is a nil unwrap.") = orchestrator.phase else {
            return XCTFail("Answer must be exactly what the model streamed, got \(orchestrator.phase)")
        }
    }

    func testSuggestionsGeneratedEvenInQuickMode() async {
        // Suggestions are a separate, non-blocking call, quick mode (terse answers) must not
        // suppress them.
        let engine = ScriptedEngine(responsesPerCall: [["short answer"]])
        engine.followUps = ["What does this mean?"]
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "x", quickMode: true),
            capture: StubCaptureProvider(sampleText: "screen"),
            inference: engine
        )

        orchestrator.beginCapture()
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(orchestrator.suggestedFollowUps, ["What does this mean?"])
    }

    func testFocusedConversationShowsOnlyLatestAnswer() async {
        let engine = ScriptedEngine(responsesPerCall: [["first answer"], ["second answer"]])
        let orchestrator = makeOrchestrator(engine)

        orchestrator.beginCapture()
        try? await Task.sleep(nanoseconds: 200_000_000)
        orchestrator.sendFollowUp("What about shorts?")
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(orchestrator.conversation.count, 4) // image, assistant, user, assistant
        XCTAssertEqual(orchestrator.focusedConversationTurns.count, 1)
        XCTAssertEqual(orchestrator.focusedConversationTurns.first?.assistantText, "second answer")
        XCTAssertTrue(orchestrator.hasConversationHistory)
    }

    func testDefaultSkipsPreviewBeforeInfer() {
        XCTAssertFalse(PeeknookSettings(textModel: "x").previewBeforeInfer)
    }

    func testTurnUsageTimelineComputesDeltas() {
        let turns = [
            ChatTurn(
                id: 1,
                kind: .assistant("first"),
                turnUsage: TurnUsage(promptTokens: 500, responseTokens: 50, generationSeconds: 1, contextWindow: 8192)
            ),
            ChatTurn(
                id: 2,
                kind: .assistant("second"),
                turnUsage: TurnUsage(promptTokens: 1200, responseTokens: 80, generationSeconds: 1, contextWindow: 8192)
            ),
        ]
        let points = TurnUsageTimeline.points(from: turns)
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].promptDelta, 0)
        XCTAssertEqual(points[1].promptDelta, 700)
    }

    func testSuggestionPassAttachedToLatestAnswer() async {
        let engine = ScriptedEngine(responsesPerCall: [["answer"]])
        engine.followUps = ["What next?"]
        engine.followUpStats = InferenceStats(promptTokens: 900, responseTokens: 30, generationSeconds: 0.5)
        let orchestrator = makeOrchestrator(engine)

        orchestrator.beginCapture()
        try? await Task.sleep(nanoseconds: 250_000_000)

        let usage = orchestrator.conversation.last(where: \.isAssistant)?.turnUsage
        XCTAssertEqual(usage?.suggestionPass?.promptTokens, 900)
        XCTAssertEqual(usage?.suggestionPass?.responseTokens, 30)
    }

    func testSuggestionsCanBeDisabledInSettings() async {
        let engine = ScriptedEngine(responsesPerCall: [["answer"]])
        engine.followUps = ["should not appear"]
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "x", suggestFollowUps: false),
            capture: StubCaptureProvider(sampleText: "screen"),
            inference: engine
        )

        orchestrator.beginCapture()
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(orchestrator.suggestedFollowUps.isEmpty, "the setting toggle still disables suggestions")
    }

    func testFinishChatKeepsThreadAndResumeChatRestoresResult() async {
        let engine = ScriptedEngine(responsesPerCall: [["first answer"]])
        let orchestrator = makeOrchestrator(engine)

        orchestrator.beginCapture()
        try? await Task.sleep(nanoseconds: 200_000_000)

        orchestrator.finishChat()
        guard case .idle = orchestrator.phase else {
            return XCTFail("Expected idle after finishChat, got \(orchestrator.phase)")
        }
        XCTAssertEqual(orchestrator.conversation.count, 2)
        XCTAssertTrue(orchestrator.hasConversation)

        orchestrator.resumeChat()
        guard case .result("first answer") = orchestrator.phase else {
            return XCTFail("Expected resumed result, got \(orchestrator.phase)")
        }
    }

    func testInferenceReplaySendsOnlyLatestImagePayload() async {
        let engine = ScriptedEngine(responsesPerCall: [["first"], ["second"], ["third"]])
        let orchestrator = makeOrchestrator(engine)

        orchestrator.beginCapture()
        try? await Task.sleep(nanoseconds: 200_000_000)
        orchestrator.addImage()
        try? await Task.sleep(nanoseconds: 200_000_000)
        orchestrator.addImage()
        try? await Task.sleep(nanoseconds: 200_000_000)

        let msgs = engine.requests.last?.messages ?? []
        let imageMsgs = msgs.filter { $0.role == .user && $0.text.contains("## Task") }
        XCTAssertEqual(imageMsgs.count, 3, "all three screenshots still ground via text")
        XCTAssertNil(imageMsgs[0].imageBase64)
        XCTAssertNil(imageMsgs[1].imageBase64)
        XCTAssertNotNil(imageMsgs[2].imageBase64)
    }

    func testInferenceReplayRespectsLastTwoSetting() async {
        let engine = ScriptedEngine(responsesPerCall: [["first"], ["second"], ["third"]])
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "x", inferenceImageReplay: .lastTwo),
            capture: StubCaptureProvider(sampleText: "screen"),
            inference: engine
        )

        orchestrator.beginCapture()
        try? await Task.sleep(nanoseconds: 200_000_000)
        orchestrator.addImage()
        try? await Task.sleep(nanoseconds: 200_000_000)
        orchestrator.addImage()
        try? await Task.sleep(nanoseconds: 200_000_000)

        let msgs = engine.requests.last?.messages ?? []
        let imageMsgs = msgs.filter { $0.role == .user && $0.text.contains("## Task") }
        XCTAssertNil(imageMsgs[0].imageBase64)
        XCTAssertNotNil(imageMsgs[1].imageBase64)
        XCTAssertNotNil(imageMsgs[2].imageBase64)
    }

    func testSuggestionsOmitImagePayloads() async {
        let engine = ScriptedEngine(responsesPerCall: [["answer"]])
        engine.followUps = ["What next?"]
        let orchestrator = makeOrchestrator(engine)

        orchestrator.beginCapture()
        try? await Task.sleep(nanoseconds: 250_000_000)

        let suggestionMsgs = engine.suggestionRequests.last?.messages ?? []
        XCTAssertFalse(suggestionMsgs.isEmpty)
        XCTAssertTrue(suggestionMsgs.allSatisfy { $0.imageBase64 == nil })
    }

    func testCriticalContextBlocksFollowUpAndAddImage() async {
        let engine = ScriptedEngine(responsesPerCall: [["first answer"], ["retake answer"]])
        engine.inferenceStats = InferenceStats(promptTokens: 950, responseTokens: 10, generationSeconds: 0.1)
        engine.contextWindow = 1000
        let orchestrator = makeOrchestrator(engine)

        orchestrator.beginCapture()
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(orchestrator.contextPressure, .critical)

        orchestrator.sendFollowUp("blocked?")
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(orchestrator.conversation.compactMap(\.userText), [])
        XCTAssertEqual(engine.requests.count, 1, "follow-up must not run inference")

        orchestrator.addImage()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(orchestrator.conversation.count, 2)
        XCTAssertEqual(engine.requests.count, 1, "add image must not run inference")

        orchestrator.retake()
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(orchestrator.conversation.last?.assistantText, "retake answer")
        XCTAssertEqual(engine.requests.count, 2, "retake still runs a fresh capture")
    }

    func testStartNewChatClearsThread() async {
        let engine = ScriptedEngine(responsesPerCall: [["first answer"]])
        let orchestrator = makeOrchestrator(engine)

        orchestrator.beginCapture()
        try? await Task.sleep(nanoseconds: 200_000_000)

        orchestrator.startNewChat()
        guard case .idle = orchestrator.phase else {
            return XCTFail("Expected idle after startNewChat, got \(orchestrator.phase)")
        }
        XCTAssertTrue(orchestrator.conversation.isEmpty)
        XCTAssertFalse(orchestrator.hasConversation)
    }

    func testNewChatDuringInferenceDoesNotResurrectResult() async {
        // dismissResult/startNewChat must cancel the in-flight inference, or a late stream completes
        // after the user left and flips the phase back to a result over the cleared conversation.
        let engine = ScriptedEngine(responsesPerCall: [Array(repeating: "x ", count: 15)])
        let orchestrator = makeOrchestrator(engine)

        orchestrator.beginCapture()
        let inferring = await orchestrator.waitForPhase { if case .inferring = $0 { return true }; return false }
        guard case .inferring = inferring else {
            return XCTFail("Expected to catch the inferring phase, got \(inferring)")
        }

        orchestrator.startNewChat()
        guard case .idle = orchestrator.phase else {
            return XCTFail("Expected idle right after New chat, got \(orchestrator.phase)")
        }

        // The phase must *stay* idle: a leaked (now-cancelled) stream completing would flip it to a
        // result. Poll rather than sleep-then-check so the assertion can't false-pass under CI load.
        let held = await orchestrator.phaseHolding({ if case .idle = $0 { return true }; return false })
        guard case .idle = held else {
            return XCTFail("A leaked inference resurrected a result after New chat: \(held)")
        }
        XCTAssertTrue(orchestrator.conversation.isEmpty)
    }

    func testIdleCaptureWithFullContextStartsFreshChatAndNotifies() async {
        // ⌘⇧P from the idle home screen, with a resumable thread whose context window is full, must
        // not be a dead key: it starts a fresh chat and emits a notice the UI can surface.
        let engine = ScriptedEngine(responsesPerCall: [["first answer"], ["fresh answer"]])
        engine.inferenceStats = InferenceStats(promptTokens: 950, responseTokens: 10, generationSeconds: 0.1)
        engine.contextWindow = 1000
        let orchestrator = makeOrchestrator(engine)

        orchestrator.beginCapture()
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(orchestrator.contextPressure, .critical)

        // Leave the result for the calm home; the thread stays resumable but its context is full.
        orchestrator.finishChat()
        guard case .idle = orchestrator.phase else {
            return XCTFail("Expected idle after finishChat, got \(orchestrator.phase)")
        }
        XCTAssertNil(orchestrator.lastNotice)

        orchestrator.beginCapture()
        XCTAssertEqual(orchestrator.lastNotice, .contextFull)

        let phase = await orchestrator.waitForResult("fresh answer")
        guard case .result("fresh answer") = phase else {
            return XCTFail("Expected a fresh chat result, got \(phase)")
        }
        XCTAssertEqual(orchestrator.conversation.count, 2, "the full thread was replaced by a fresh chat")
    }

    func testCaptureFromFullResultStaysPutWithoutNotice() async {
        // From the result view the on-screen context banner already explains the block, so the
        // capture hotkey stays a no-op there — we only changed the idle (no-banner) case.
        let engine = ScriptedEngine(responsesPerCall: [["first answer"]])
        engine.inferenceStats = InferenceStats(promptTokens: 950, responseTokens: 10, generationSeconds: 0.1)
        engine.contextWindow = 1000
        let orchestrator = makeOrchestrator(engine)

        orchestrator.beginCapture()
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(orchestrator.contextPressure, .critical)
        guard case .result = orchestrator.phase else {
            return XCTFail("Expected a result, got \(orchestrator.phase)")
        }

        orchestrator.beginCapture()
        XCTAssertNil(orchestrator.lastNotice)
        guard case .result("first answer") = orchestrator.phase else {
            return XCTFail("A capture from a full result should stay put, got \(orchestrator.phase)")
        }
        XCTAssertEqual(orchestrator.conversation.count, 2)
    }

    func testPrewarmOnlyMarksModelWarmWhenWarmUpSucceeds() async {
        let failEngine = ScriptedEngine(responsesPerCall: [])
        failEngine.warmUpSucceeds = false
        let cold = makeOrchestrator(failEngine)
        XCTAssertFalse(cold.modelLikelyWarm)
        cold.prewarm()
        try? await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertFalse(cold.modelLikelyWarm, "a failed warm-up must not fake a warm model")

        let okEngine = ScriptedEngine(responsesPerCall: [])
        okEngine.warmUpSucceeds = true
        let warm = makeOrchestrator(okEngine)
        warm.prewarm()
        try? await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertTrue(warm.modelLikelyWarm, "a successful warm-up marks the model warm")
    }
}
