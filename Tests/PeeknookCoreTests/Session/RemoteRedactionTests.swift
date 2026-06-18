// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// Redact-and-notify before sending text to a remote or `:cloud` model. A remote/cloud turn strips
/// secret spans from the SENT text payload (transcript/clipboard primary text and supplementary
/// extracted text); a local/loopback non-cloud turn is byte-identical (no inspection). The archived
/// `ChatTurn` and the on-screen conversation keep the ORIGINAL text. The screenshot bitmap is out of
/// scope — only text legs are inspected.
final class RemoteRedactionTests: XCTestCase {
    private let builder = InferenceMessageBuilder(quickMode: false, sessionBrief: nil)
    private let token = SensitiveContentPolicy.redactionToken

    private let skKey = "sk-test-abcdefghijklmnopqrstuvwxyz1234567890"
    private let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxIn0.sig"

    private func transcript(_ id: Int, ground: Ground = .systemAudio, text: String) -> ChatTurn {
        ChatTurn(
            id: id,
            kind: .image(CaptureResult(text: text, sourceLabel: "src", screenshotBase64: nil, ground: ground))
        )
    }
    private func screen(_ id: Int, text: String?, base64: String? = "SCR", group: UUID? = nil) -> ChatTurn {
        ChatTurn(
            id: id,
            kind: .image(CaptureResult(text: text, sourceLabel: "src", screenshotBase64: base64, ground: .screen)),
            compositeGroupID: group
        )
    }

    private func userText(in messages: [InferenceMessage]) -> String {
        messages.first { $0.role == .user }?.text ?? ""
    }

    // MARK: - Endpoint / cloud-tag classifier

    func testLoopbackNonCloudIsNotRemoteEgress() {
        let endpoint = InferenceEndpoint.ollama(baseURL: "http://127.0.0.1:11434", acceptInsecureRemote: false)
        XCTAssertFalse(endpoint.isRemoteEgress(modelTag: "gemma4:e4b"))
    }

    func testRemoteHostIsRemoteEgress() {
        let endpoint = InferenceEndpoint.ollama(baseURL: "https://example.com:11434", acceptInsecureRemote: false)
        XCTAssertTrue(endpoint.isRemoteEgress(modelTag: "gemma4:e4b"))
    }

    func testCloudTagOnLoopbackIsRemoteEgress() {
        let endpoint = InferenceEndpoint.ollama(baseURL: "http://127.0.0.1:11434", acceptInsecureRemote: false)
        XCTAssertTrue(endpoint.isRemoteEgress(modelTag: "gpt-oss:cloud"))
    }

    // MARK: - Redaction on a remote turn

    func testRemoteRedactsSkKeyInTranscriptLeg() {
        let redaction = RedactionContext()
        let convo = [transcript(1, ground: .systemAudio, text: "the key is \(skKey) ok")]
        let messages = builder.inferenceMessages(from: convo, redaction: redaction)
        let body = userText(in: messages)
        XCTAssertFalse(body.contains(skKey), "the sk- key is stripped from the sent transcript")
        XCTAssertTrue(body.contains(token), "the redaction token replaces the secret")
        XCTAssertEqual(redaction.hitCount, 1)
    }

    func testRemoteRedactsJWTInTranscriptLeg() {
        let redaction = RedactionContext()
        let convo = [transcript(1, ground: .clipboard, text: "Bearer \(jwt)")]
        let messages = builder.inferenceMessages(from: convo, redaction: redaction)
        let body = userText(in: messages)
        XCTAssertFalse(body.contains(jwt), "the JWT is stripped from the sent clipboard text")
        XCTAssertTrue(body.contains(token))
        XCTAssertGreaterThan(redaction.hitCount, 0)
    }

    func testRemoteRedactsLabeledKeyInSupplementaryExtractedText() {
        let redaction = RedactionContext()
        // A screen leg carries supplementary extracted text containing a labeled secret.
        let convo = [screen(1, text: "config\napi_key=\(skKey)")]
        let messages = builder.inferenceMessages(from: convo, redaction: redaction)
        let body = userText(in: messages)
        XCTAssertFalse(body.contains(skKey), "the labeled key value is stripped from extracted text")
        XCTAssertTrue(body.contains(token))
        XCTAssertTrue(body.contains("api_key="), "the label stays; only the value is redacted")
        XCTAssertEqual(redaction.hitCount, 1)
    }

    // MARK: - Loopback non-cloud is byte-identical

    func testLoopbackTranscriptIsByteIdenticalToVerbatim() {
        // No redaction context (the local, non-cloud path): the assembled message must be identical
        // to one built with no redaction, secrets intact.
        let convo = [transcript(1, ground: .systemAudio, text: "secret \(skKey) here")]
        let verbatim = userText(in: builder.inferenceMessages(from: convo))
        let withNilRedaction = userText(in: builder.inferenceMessages(from: convo, redaction: nil))
        XCTAssertEqual(verbatim, withNilRedaction)
        XCTAssertTrue(verbatim.contains(skKey), "a loopback non-cloud turn sends the secret verbatim")
        XCTAssertFalse(verbatim.contains(token))
    }

    func testLoopbackExtractedTextIsByteIdentical() {
        let convo = [screen(1, text: "api_key=\(skKey)")]
        let body = userText(in: builder.inferenceMessages(from: convo))
        XCTAssertTrue(body.contains(skKey), "extracted text is sent verbatim with no redaction context")
    }

    // MARK: - Multi-ground transcript legs are redacted

    func testRemoteRedactsMultiGroundTranscriptLeg() {
        let redaction = RedactionContext()
        let gid = UUID()
        let convo = [
            screen(2, text: "see attached", base64: "SCR", group: gid),
            transcript(3, ground: .systemAudio, text: "the token is \(skKey)"),
        ]
        // Make the audio leg part of the same group so it folds into the multi-ground message.
        let groupedAudio = ChatTurn(
            id: 3,
            kind: .image(CaptureResult(text: "the token is \(skKey)", sourceLabel: "src", screenshotBase64: nil, ground: .systemAudio)),
            compositeGroupID: gid
        )
        let grouped = [convo[0], groupedAudio]
        let messages = builder.inferenceMessages(from: grouped, redaction: redaction)
        let folded = messages.first { $0.role == .user }?.text ?? ""
        XCTAssertFalse(folded.contains(skKey), "the multi-ground transcript leg is redacted")
        XCTAssertTrue(folded.contains(token))
        XCTAssertEqual(redaction.hitCount, 1)
    }

    // MARK: - Archived / on-screen content stays the original

    func testRedactionDoesNotMutateTheConversation() {
        let redaction = RedactionContext()
        let convo = [transcript(1, ground: .clipboard, text: "key \(skKey)")]
        _ = builder.inferenceMessages(from: convo, redaction: redaction)
        // The source turn (the archive / on-screen model) still carries the original text.
        guard case .image(let capture) = convo[0].kind else { return XCTFail("expected an image turn") }
        XCTAssertEqual(capture.text, "key \(skKey)", "the archived/on-screen text is untouched")
    }

    // MARK: - Hit count

    func testHitCountTalliesEverySpan() {
        let redaction = RedactionContext()
        let convo = [
            transcript(1, ground: .clipboard, text: "first \(skKey)"),
            transcript(2, ground: .systemAudio, text: "second \(jwt) and api_key=\(skKey)"),
        ]
        _ = builder.inferenceMessages(from: convo, redaction: redaction)
        XCTAssertGreaterThanOrEqual(redaction.hitCount, 3, "every secret span across legs is counted")
    }

    func testCleanTextRedactsNothingAndCountsZero() {
        let redaction = RedactionContext()
        let convo = [transcript(1, ground: .systemAudio, text: "what does this kanji mean?")]
        let body = userText(in: builder.inferenceMessages(from: convo, redaction: redaction))
        XCTAssertTrue(body.contains("what does this kanji mean?"))
        XCTAssertFalse(body.contains(token))
        XCTAssertEqual(redaction.hitCount, 0)
    }

    // MARK: - Bool egress paths unchanged

    func testWebLookupAndCatalogSearchBoolEgressUnchanged() {
        let policy = SensitiveContentPolicy()
        // A secret still blocks the boolean egresses exactly as before — redaction did not relax them.
        XCTAssertFalse(policy.allowsEgress(text: skKey, windowTitle: nil, appName: nil, for: .webLookup))
        XCTAssertFalse(policy.allowsEgress(text: skKey, windowTitle: nil, appName: nil, for: .catalogSearch))
        XCTAssertTrue(policy.allowsEgress(text: "harmless question", windowTitle: nil, appName: nil, for: .webLookup))
        XCTAssertTrue(policy.allowsEgress(text: "harmless question", windowTitle: nil, appName: nil, for: .catalogSearch))
        // Remote inference never blocks at the gate (it redacts in the payload instead).
        XCTAssertTrue(policy.allowsEgress(text: skKey, windowTitle: nil, appName: nil, for: .remoteInference))
    }

    // MARK: - Spans parity with the boolean gate

    func testSensitiveSpansAgreeWithLooksSensitive() {
        let sensitive = ["api key: \(skKey)", "Bearer \(jwt)", "-----BEGIN PRIVATE KEY-----", skKey]
        for text in sensitive {
            XCTAssertTrue(SensitiveTextHeuristics.looksSensitive(text), "\(text) should be sensitive")
            XCTAssertFalse(SensitiveTextHeuristics.sensitiveSpans(in: text).isEmpty, "\(text) should have spans")
        }
        let clean = ["What does this kanji mean?", "import sklearn", "Stripe API keys start with sk- prefix"]
        for text in clean {
            XCTAssertFalse(SensitiveTextHeuristics.looksSensitive(text), "\(text) should be clean")
            XCTAssertTrue(SensitiveTextHeuristics.sensitiveSpans(in: text).isEmpty, "\(text) should have no spans")
        }
    }

    func testRedactionPreservesSurroundingProse() {
        let policy = SensitiveContentPolicy()
        let result = policy.redactedForRemoteInference(text: "before \(skKey) after")
        XCTAssertEqual(result.text, "before \(token) after")
        XCTAssertEqual(result.hitCount, 1)
    }

    func testRedactionLeavesCleanTextByteIdentical() {
        let policy = SensitiveContentPolicy()
        let clean = "explain the chart on screen"
        let result = policy.redactedForRemoteInference(text: clean)
        XCTAssertEqual(result.text, clean, "clean text is never rewritten")
        XCTAssertEqual(result.hitCount, 0)
    }

    // MARK: - The follow-up suggestion pass redacts on the SAME condition as the answer pass

    /// The suggestion pass replays the conversation's captured text legs to the SAME endpoint as the
    /// answer pass. On a remote/`:cloud` turn it must redact too — otherwise a secret the answer turn
    /// stripped still egresses on the immediately following suggestion call. Driven through the real
    /// orchestrator path so it guards the `SuggestionCoordinator` wiring, not just the builder.
    @MainActor
    func testRemoteSuggestionPassRedactsCapturedSecret() async {
        let engine = RecordingSuggestionEngine(answer: "the answer", followUps: ["What next?"])
        let o = SessionOrchestrator(
            settings: PeeknookSettings(
                previewBeforeInfer: false,
                ollamaBaseURL: "https://remote.example.com:11434",   // non-loopback ⇒ remote egress
                textModel: "m"
            ),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "config\napi_key=\(skKey)")]),
            inference: engine
        )

        o.beginCapture()
        _ = await o.waitForResult("the answer")
        _ = await o.waitForSuggestions(["What next?"])

        let sent = engine.suggestionRequests.last?.messages.map(\.text).joined(separator: "\n") ?? ""
        XCTAssertFalse(sent.isEmpty, "the suggestion pass must have sent a request")
        XCTAssertFalse(sent.contains(skKey), "the captured secret is stripped from the suggestion request too")
        XCTAssertTrue(sent.contains(token), "the redaction token replaces it in the suggestion request")
    }

    /// Mirror of the answer-pass byte-identical guarantee: a local/loopback non-cloud suggestion pass
    /// does no inspection, so the captured text rides verbatim (nothing leaves the Mac regardless).
    @MainActor
    func testLoopbackSuggestionPassSendsCapturedTextVerbatim() async {
        let engine = RecordingSuggestionEngine(answer: "the answer", followUps: ["What next?"])
        let o = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "m"),   // default loopback
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "config\napi_key=\(skKey)")]),
            inference: engine
        )

        o.beginCapture()
        _ = await o.waitForResult("the answer")
        _ = await o.waitForSuggestions(["What next?"])

        let sent = engine.suggestionRequests.last?.messages.map(\.text).joined(separator: "\n") ?? ""
        XCTAssertTrue(sent.contains(skKey), "a loopback non-cloud suggestion pass is byte-identical (no inspection)")
        XCTAssertFalse(sent.contains(token))
    }
}

/// Records the suggestion-pass request so a test can inspect exactly what the follow-up call sends.
/// `capabilities == nil` ⇒ `VisionGate.unknown` ⇒ never blocks, so a screen turn reaches a result
/// without a live vision model.
private final class RecordingSuggestionEngine: InferenceEngine, @unchecked Sendable {
    private(set) var suggestionRequests: [InferenceRequest] = []
    private let answer: String
    private let followUps: [String]

    init(answer: String, followUps: [String]) {
        self.answer = answer
        self.followUps = followUps
    }

    func health(baseURL: String, model: String, acceptInsecureRemote: Bool) async -> InferenceHealth { .ready }
    func warmUp(model: String, baseURL: String, acceptInsecureRemote: Bool) async -> Bool { true }
    func contextLength(model: String, baseURL: String, acceptInsecureRemote: Bool) async -> Int? { nil }
    func capabilities(model: String, baseURL: String, acceptInsecureRemote: Bool) async -> [String]? { nil }

    func generateFollowUps(request: InferenceRequest) async -> FollowUpGenerationResult {
        suggestionRequests.append(request)
        return FollowUpGenerationResult(suggestions: followUps, stats: nil)
    }

    func stream(request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        let answer = self.answer
        return AsyncThrowingStream { continuation in
            continuation.yield(.token(answer))
            continuation.yield(.completed(nil))
            continuation.finish()
        }
    }
}
