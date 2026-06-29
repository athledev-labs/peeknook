// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// Locks the single shared request-assembly seam (`SessionOrchestrator.assembleRequest`) that the
/// answer turn, the follow-up suggestion pass, and (later) the caption sink all route through. The
/// end-to-end byte-identical guarantees for the two existing callers stay in
/// `FastTextFollowUpRoutingTests` (model/endpoint identity, image drop) and `RemoteRedactionTests`
/// (the suggestion-pass redaction mirror); these assert the seam's own contract directly.
@MainActor
final class RequestAssemblyTests: XCTestCase {
    private let skKey = "sk-test-abcdefghijklmnopqrstuvwxyz1234567890"

    private func orchestrator(
        baseURL: String = "http://127.0.0.1:11434",
        textModel: String = "gemma4:e4b"
    ) -> SessionOrchestrator {
        SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, ollamaBaseURL: baseURL, textModel: textModel),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "screen")]),
            inference: MockInferenceEngine()
        )
    }

    private func secretTranscript(ground: Ground) -> [ChatTurn] {
        [ChatTurn(id: 1, kind: .image(
            CaptureResult(text: "the key is \(skKey)", sourceLabel: "src", screenshotBase64: nil, ground: ground)
        ))]
    }

    // MARK: - The `.primaryVision` route is the active identity pair, no redaction on a local turn

    func testPrimaryVisionResolvesActiveIdentityPairAndNilRedactionLocally() {
        let o = orchestrator()
        var sawRedactionNonNil: Bool?
        let assembled = o.assembleRequest(role: .primaryVision, quickMode: false) { redaction in
            sawRedactionNonNil = (redaction != nil)
            return []
        }
        // The route resolves to exactly what the pre-router answer/suggestion path used.
        XCTAssertEqual(assembled.route.model.tag, o.activeAnswerModel.tag)
        XCTAssertEqual(assembled.route.endpoint, o.activeInferenceEndpoint)
        // The request envelope reads off that route + the active profile/settings.
        XCTAssertEqual(assembled.request.model, o.activeAnswerModel.tag)
        XCTAssertEqual(assembled.request.endpoint, o.activeInferenceEndpoint)
        XCTAssertEqual(assembled.request.mode, o.settings.mode)
        XCTAssertFalse(assembled.request.quickMode)
        // A loopback non-cloud route does no inspection: the closure gets nil, the tally is 0.
        XCTAssertEqual(sawRedactionNonNil, false)
        XCTAssertEqual(assembled.redactedSecretCount, 0)
    }

    func testQuickModeFlagThreadsIntoTheEnvelope() {
        let o = orchestrator()
        let assembled = o.assembleRequest(role: .primaryVision, quickMode: true) { _ in [] }
        XCTAssertTrue(assembled.request.quickMode, "quickMode threads straight into the request envelope")
    }

    // MARK: - The `.textOnly` route (the caption sink's entry point) resolves the configured text model

    func testTextOnlyResolvesConfiguredTextModelElseFallsBackToPrimaryVision() {
        // Configured: `.textOnly` routes to the configured text model — the role the caption sink calls.
        let configured = orchestrator()
        configured.settings.textOnlyModelTag = "qwen-text"
        let routed = configured.assembleRequest(role: .textOnly, quickMode: false) { _ in [] }
        XCTAssertEqual(routed.route.model.tag, "qwen-text")
        XCTAssertEqual(routed.request.model, "qwen-text")

        // Unconfigured: `.textOnly` falls back to the primary-vision identity pair (never a blind route).
        let bare = orchestrator()
        bare.settings.textOnlyModelTag = ""
        let fallback = bare.assembleRequest(role: .textOnly, quickMode: false) { _ in [] }
        XCTAssertEqual(fallback.route.model.tag, bare.activeAnswerModel.tag)
        XCTAssertEqual(fallback.route.endpoint, bare.activeInferenceEndpoint)
    }

    // MARK: - A remote / `:cloud` route hands the closure a redaction context and tallies hits

    func testRemoteEgressPassesRedactionContextAndTalliesStrippedSecrets() {
        let o = orchestrator(baseURL: "https://remote.example.com:11434")   // non-loopback ⇒ remote egress
        let builder = InferenceMessageBuilder(quickMode: false, sessionBrief: nil)
        let convo = secretTranscript(ground: .systemAudio)
        var sawRedactionNonNil: Bool?
        let assembled = o.assembleRequest(role: .primaryVision, quickMode: false) { redaction in
            sawRedactionNonNil = (redaction != nil)
            return builder.inferenceMessages(from: convo, redaction: redaction)
        }
        XCTAssertTrue(assembled.route.endpoint.isRemoteEgress(modelTag: assembled.route.model.tag))
        XCTAssertEqual(sawRedactionNonNil, true, "a remote route hands the closure a redaction context")
        XCTAssertGreaterThan(assembled.redactedSecretCount, 0, "stripped spans are tallied onto the assembled request")
        let body = assembled.request.messages.first { $0.role == .user }?.text ?? ""
        XCTAssertFalse(body.contains(skKey), "the secret is stripped from the sent payload")
        XCTAssertTrue(body.contains(SensitiveContentPolicy.redactionToken))
    }

    func testCloudTagOnLoopbackStillTriggersRedaction() {
        // Loopback base URL but a `:cloud` model tag is still remote egress, so the seam must redact.
        let o = orchestrator(textModel: "gpt-oss:cloud")
        let builder = InferenceMessageBuilder(quickMode: false, sessionBrief: nil)
        let convo = secretTranscript(ground: .clipboard)
        var sawRedactionNonNil: Bool?
        let assembled = o.assembleRequest(role: .primaryVision, quickMode: false) { redaction in
            sawRedactionNonNil = (redaction != nil)
            return builder.inferenceMessages(from: convo, redaction: redaction)
        }
        XCTAssertEqual(o.activeAnswerModel.tag, "gpt-oss:cloud")
        XCTAssertEqual(sawRedactionNonNil, true)
        XCTAssertGreaterThan(assembled.redactedSecretCount, 0)
        let body = assembled.request.messages.first { $0.role == .user }?.text ?? ""
        XCTAssertFalse(body.contains(skKey))
    }
}
