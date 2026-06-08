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
            capture: StubCaptureProvider(sampleText: "hello"),
            inference: MockInferenceEngine(tokens: [])
        )

        orchestrator.beginCapture()
        try? await Task.sleep(nanoseconds: 150_000_000)

        guard case .failed(let failure) = orchestrator.phase else {
            XCTFail("Expected failed, got \(orchestrator.phase)")
            return
        }
        XCTAssertEqual(failure.kind, .emptyAnswer)
        XCTAssertEqual(failure.primaryRecovery, .tryAgain)
    }

    func testRetryAfterFailureOnlyRunsFromFailedPhase() async {
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e4b"),
            capture: StubCaptureProvider(sampleText: "x"),
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
}
