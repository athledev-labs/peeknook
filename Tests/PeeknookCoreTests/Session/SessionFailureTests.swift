// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

@MainActor
final class SessionFailureTests: XCTestCase {
    func testCaptureErrorMapsToStructuredFailures() {
        XCTAssertEqual(SessionFailure.from(captureError: .noContent).kind, .captureFailed)

        let perm = SessionFailure.from(captureError: .permissionRequired("Screen Recording"))
        XCTAssertEqual(perm.kind, .permissionRequired(name: "Screen Recording"))
        XCTAssertEqual(perm.primaryRecovery, .openScreenRecordingSettings)

        let accessibility = SessionFailure.from(captureError: .permissionRequired("Accessibility"))
        XCTAssertEqual(accessibility.primaryRecovery, .openAccessibilitySettings)
    }

    func testInferenceErrorMapsToRecoveryActions() {
        let unreachable = SessionFailure.from(inferenceError: .ollamaUnreachable("Start Ollama"))
        XCTAssertEqual(unreachable.kind, .ollamaUnreachable)
        XCTAssertEqual(unreachable.primaryRecovery, .checkOllama)

        let missing = SessionFailure.from(inferenceError: .modelMissing("gemma4:e4b", hint: "ollama pull gemma4:e4b"))
        XCTAssertEqual(missing.kind, .modelMissing(tag: "gemma4:e4b"))
        XCTAssertEqual(missing.primaryRecovery, .downloadModel(tag: "gemma4:e4b"))
        XCTAssertEqual(missing.secondaryRecovery, .switchModel)
        XCTAssertEqual(missing.technicalDetail, "ollama pull gemma4:e4b")
    }

    func testEmptyAnswerStreamProducesEmptyAnswerFailure() async {
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e4b"),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "hello")]),
            inference: MockInferenceEngine(tokens: [])
        )

        orchestrator.beginCapture()
        let phase = await orchestrator.waitForFailed { $0.kind == .emptyAnswer }

        guard case .failed(let failure) = phase else {
            XCTFail("Expected failed, got \(orchestrator.phase)")
            return
        }
        XCTAssertEqual(failure.kind, .emptyAnswer)
        XCTAssertEqual(failure.primaryRecovery, .tryAgain)
    }

    func testRetryAfterFailureOnlyRunsFromFailedPhase() async {
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e4b"),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "x")]),
            inference: MockInferenceEngine(tokens: ["ok"])
        )

        orchestrator.retryAfterFailure()
        guard case .idle = orchestrator.phase else {
            XCTFail("retryAfterFailure should not start from idle")
            return
        }
    }

    func testURLErrorMapsToOllamaUnreachable() {
        let failure = SessionFailure.from(error: URLError(.networkConnectionLost))
        XCTAssertEqual(failure.kind, .ollamaUnreachable)
        XCTAssertEqual(failure.primaryRecovery, .checkOllama)
    }

    /// An OpenAI-compatible connection failure must not claim "Ollama isn't responding" — that
    /// sends the user debugging a process they aren't running.
    func testOpenAICompatibleUnreachableUsesBackendNeutralCopy() {
        let failure = SessionFailure.from(
            inferenceError: .ollamaUnreachable("No response from the inference server."),
            backend: .openAICompatible
        )
        XCTAssertEqual(failure.kind, .ollamaUnreachable)
        XCTAssertFalse(failure.title.contains("Ollama"), "Title must not name Ollama: \(failure.title)")

        let urlFailure = SessionFailure.from(
            error: URLError(.cannotConnectToHost), backend: .openAICompatible
        )
        XCTAssertFalse(urlFailure.message.contains("Ollama"), "Copy must not name Ollama: \(urlFailure.message)")
    }

    func testOllamaUnreachableStillUsesOllamaCopyByDefault() {
        let failure = SessionFailure.from(inferenceError: .ollamaUnreachable("Start Ollama"))
        XCTAssertTrue(failure.title.contains("Ollama"))
    }

    /// No download path exists on an OpenAI-compatible server — the model-missing recovery must
    /// not offer an Ollama pull.
    func testOpenAICompatibleModelMissingOffersSwitchNotDownload() {
        let failure = SessionFailure.from(
            inferenceError: .modelMissing("qwen2-vl", hint: "Load it on the server"),
            backend: .openAICompatible
        )
        XCTAssertEqual(failure.kind, .modelMissing(tag: "qwen2-vl"))
        XCTAssertEqual(failure.primaryRecovery, .switchModel)
        XCTAssertNotEqual(failure.primaryRecovery, .downloadModel(tag: "qwen2-vl"))
    }
}
