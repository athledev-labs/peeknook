// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// End-to-end routing of the text-only follow-up role through `runTurn`: the opt-in gate, the forced
/// image drop, the engine following the routed endpoint cross-backend, suggestions/usage pinning,
/// and the byte-identical default. Complements the pure resolver in `RoleResolutionTests`.
@MainActor
final class FastTextFollowUpRoutingTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "peeknook.tests.fastTextFollowUp")!
        defaults.removePersistentDomain(forName: "peeknook.tests.fastTextFollowUp")
    }

    private func makeOrchestrator(
        _ engine: ScriptedEngine, textModel: String = "gemma4:e4b"
    ) -> SessionOrchestrator {
        SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: textModel),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "screen")]),
            inference: engine
        )
    }

    private func anyImage(in request: InferenceRequest?) -> Bool {
        (request?.messages ?? []).contains { $0.imageBase64 != nil }
    }

    // MARK: turnRole gate (all three conjuncts)

    func testTurnRoleFiresTextOnlyOnlyWithAllThreeConjuncts() {
        let o = makeOrchestrator(ScriptedEngine(responsesPerCall: []))
        // A capture turn is never text-only, even fully configured.
        o.settings.fastTextFollowUps = true
        o.settings.textOnlyModelTag = "qwen-text"
        XCTAssertEqual(o.turnRole(forFollowUp: false), .primaryVision)
        // Follow-up, opt-in OFF.
        o.settings.fastTextFollowUps = false
        XCTAssertEqual(o.turnRole(forFollowUp: true), .primaryVision)
        // Follow-up, opt-in ON but no text model.
        o.settings.fastTextFollowUps = true
        o.settings.textOnlyModelTag = ""
        XCTAssertEqual(o.turnRole(forFollowUp: true), .primaryVision)
        // All three present.
        o.settings.textOnlyModelTag = "qwen-text"
        XCTAssertEqual(o.turnRole(forFollowUp: true), .textOnly)
    }

    // MARK: byte-identical default

    func testDefaultCaptureTurnUsesPrimaryVisionModelAndEndpoint() async {
        let engine = ScriptedEngine(responsesPerCall: [["hi"]])
        let o = makeOrchestrator(engine)
        o.beginCapture()
        _ = await o.waitForResult("hi")
        XCTAssertEqual(engine.requests.first?.model, o.activeAnswerModel.tag)
        XCTAssertEqual(engine.requests.first?.endpoint, o.activeInferenceEndpoint)
    }

    func testDefaultFollowUpStaysVisionAndReplaysImage() async {
        let engine = ScriptedEngine(responsesPerCall: [["a1"], ["a2"]])
        let o = makeOrchestrator(engine)
        o.beginCapture()
        _ = await o.waitForResult("a1")
        o.sendFollowUp("why?")
        _ = await o.waitForResult("a2")
        XCTAssertEqual(engine.requests.count, 2)
        XCTAssertEqual(engine.requests[1].model, o.activeAnswerModel.tag)
        XCTAssertTrue(
            anyImage(in: engine.requests[1]),
            "The default follow-up must keep visual context (replay the latest screenshot)."
        )
    }

    // MARK: text-only route

    func testTextOnlyFollowUpDropsImageAndUsesTextModel() async {
        let engine = ScriptedEngine(responsesPerCall: [["a1"], ["a2"]])
        let o = makeOrchestrator(engine)
        o.settings.fastTextFollowUps = true
        o.settings.textOnlyModelTag = "qwen-text" // Ollama backend (default)
        o.beginCapture()
        _ = await o.waitForResult("a1")
        XCTAssertTrue(anyImage(in: engine.requests[0]), "The capture turn still carries its screenshot.")
        o.sendFollowUp("explain")
        _ = await o.waitForResult("a2")
        XCTAssertEqual(engine.requests[1].model, "qwen-text")
        XCTAssertFalse(
            anyImage(in: engine.requests[1]),
            "A routed text-only follow-up must provably carry no screenshot."
        )
    }

    func testCaptureTurnStaysVisionEvenWithOptInOn() async {
        let engine = ScriptedEngine(responsesPerCall: [["a1"]])
        let o = makeOrchestrator(engine)
        o.settings.fastTextFollowUps = true
        o.settings.textOnlyModelTag = "qwen-text"
        o.beginCapture()
        _ = await o.waitForResult("a1")
        XCTAssertEqual(engine.requests[0].model, o.activeAnswerModel.tag)
        XCTAssertTrue(anyImage(in: engine.requests[0]))
    }

    // MARK: engine follows the routed endpoint (seam-2, cross-backend)

    func testEngineFollowsRoutedEndpointCrossBackend() async {
        let ollama = ScriptedEngine(responsesPerCall: [["vision"]])
        let openAI = ScriptedEngine(responsesPerCall: [["text"]])
        var settings = PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e4b")
        settings.openAICompatibleBaseURL = "http://127.0.0.1:1234"
        settings.fastTextFollowUps = true
        settings.textOnlyBackend = .openAICompatible
        settings.textOnlyModelTag = "text-mini"
        let o = SessionOrchestrator(
            settings: settings,
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "screen")]),
            inferenceRegistry: InferenceBackendRegistry([.ollama: ollama, .openAICompatible: openAI])
        )

        o.beginCapture()
        _ = await o.waitForResult("vision")
        XCTAssertEqual(ollama.requests.count, 1, "Capture turn → primaryVision → Ollama engine.")
        XCTAssertEqual(openAI.requests.count, 0)

        o.sendFollowUp("explain")
        _ = await o.waitForResult("text")
        XCTAssertEqual(openAI.requests.count, 1, "Text-only follow-up → OpenAI-compatible engine.")
        XCTAssertEqual(openAI.requests.first?.model, "text-mini")
        XCTAssertEqual(openAI.requests.first?.endpoint.backend, .openAICompatible)
        XCTAssertEqual(ollama.requests.count, 1, "The vision engine must not receive the text-only turn.")
    }

    // MARK: suggestions + usage

    func testSuggestionsStayPrimaryVisionAfterTextOnlyTurn() async {
        let engine = ScriptedEngine(responsesPerCall: [["a1"], ["a2"]])
        engine.followUps = ["What next?"]
        let o = makeOrchestrator(engine)
        o.settings.fastTextFollowUps = true
        o.settings.textOnlyModelTag = "qwen-text"
        o.beginCapture()
        _ = await o.waitForResult("a1")
        o.sendFollowUp("explain")
        _ = await o.waitForResult("a2")
        XCTAssertEqual(engine.requests[1].model, "qwen-text", "The answer used the text-only model…")
        let ready = await o.waitForSuggestions(["What next?"])
        XCTAssertTrue(ready)
        XCTAssertEqual(
            engine.suggestionRequests.last?.model, o.activeAnswerModel.tag,
            "…but the suggestion pass stays pinned to the primary vision model."
        )
    }

    func testUsageRecordsRoutedTextOnlyTag() async {
        let engine = ScriptedEngine(responsesPerCall: [["a1"], ["a2"]])
        engine.inferenceStats = InferenceStats(promptTokens: 4, responseTokens: 2, generationSeconds: 0.1)
        let o = makeOrchestrator(engine)
        let usage = UsageStore(defaults: defaults)
        o.usage = usage
        o.settings.fastTextFollowUps = true
        o.settings.textOnlyModelTag = "qwen-text"
        o.beginCapture()
        _ = await o.waitForResult("a1")
        o.sendFollowUp("explain")
        _ = await o.waitForResult("a2")
        XCTAssertEqual(usage.stats.events.last?.modelTag, "qwen-text")
    }
}
