// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// Records each `InferenceRequest` and replies with a scripted token list per call, so a test
/// can assert what history the orchestrator replayed on a follow-up.
final class ScriptedEngine: InferenceEngine, @unchecked Sendable {
    private(set) var requests: [InferenceRequest] = []
    private let responsesPerCall: [[String]]
    private var callIndex = 0
    /// Canned suggestion-pass result.
    var followUps: [String] = []

    init(responsesPerCall: [[String]]) {
        self.responsesPerCall = responsesPerCall
    }

    func health(baseURL: String, model: String) async -> InferenceHealth { .ready }

    var followUpStats: InferenceStats?

    func generateFollowUps(request: InferenceRequest) async -> FollowUpGenerationResult {
        FollowUpGenerationResult(suggestions: followUps, stats: followUpStats)
    }

    func stream(request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        // Called synchronously on the orchestrator's main actor — safe to record here.
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
                continuation.yield(.completed(nil))
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
        XCTAssertEqual(msgs[1], InferenceMessage(role: .assistant, text: "first answer"))
        XCTAssertEqual(msgs[2], InferenceMessage(role: .user, text: "why?"))
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
        // The second answer's prompt replays the first answer + the new image grounding.
        let msgs = engine.requests.last?.messages ?? []
        XCTAssertEqual(msgs.count, 3)
        XCTAssertEqual(msgs[1], InferenceMessage(role: .assistant, text: "first answer"))
        XCTAssertEqual(msgs[2].role, .user)
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
        XCTAssertEqual(usage.stats.captures, 1, "a follow-up reuses the screenshot — not a new capture")
    }

    func testFollowUpIgnoredWithoutAnAnswer() {
        let orchestrator = makeOrchestrator(ScriptedEngine(responsesPerCall: [["a"]]))
        // No capture yet — phase is .idle, so a follow-up is a no-op.
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
        // The answer stream and the suggestion pass are independent — the answer is never
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
        // Suggestions are a separate, non-blocking call — quick mode (terse answers) must not
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
}
