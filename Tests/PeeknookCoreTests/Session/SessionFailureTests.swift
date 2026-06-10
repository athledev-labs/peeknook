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

    func testRetryAfterEmptyAnswerReinfersSameScreenshot() async {
        let counter = CaptureCallCounter(inner: StubCaptureProvider(sampleText: "hello"))
        let inference = SequentialMockInferenceEngine(tokenSequences: [[], ["retry ", "ok"]])
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e4b"),
            captureRegistry: GroundRegistry([.screen: counter]),
            inference: inference
        )

        orchestrator.beginCapture()
        _ = await orchestrator.waitForFailed { $0.kind == .emptyAnswer }
        XCTAssertEqual(counter.captureCount, 1)
        XCTAssertEqual(orchestrator.conversation.count, 1)
        guard case .image = orchestrator.conversation[0].kind else {
            return XCTFail("Expected orphan image turn")
        }

        orchestrator.retryAfterFailure()
        let phase = await orchestrator.waitForResult("retry ok")

        XCTAssertEqual(counter.captureCount, 1, "Retry should re-infer, not re-capture")
        guard case .result("retry ok") = phase else {
            XCTFail("Expected recovered result, got \(phase)")
            return
        }
        XCTAssertEqual(orchestrator.conversation.count, 2)
    }

    func testRetryAfterEmptyAnswerPreservesPriorAnswersInMultiTurn() async {
        let counter = CaptureCallCounter(inner: StubCaptureProvider(sampleText: "screen"))
        let inference = SequentialMockInferenceEngine(
            tokenSequences: [["first ", "answer"], [], ["second ", "answer"]]
        )
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e4b"),
            captureRegistry: GroundRegistry([.screen: counter]),
            inference: inference
        )

        orchestrator.beginCapture()
        _ = await orchestrator.waitForResult("first answer")
        orchestrator.addImage()
        _ = await orchestrator.waitForFailed { $0.kind == .emptyAnswer }
        XCTAssertEqual(counter.captureCount, 2)
        XCTAssertEqual(orchestrator.conversation.count, 3)

        orchestrator.retryAfterFailure()
        _ = await orchestrator.waitForResult("second answer")

        XCTAssertEqual(counter.captureCount, 2, "Retry should not trigger a third capture")
        XCTAssertEqual(orchestrator.conversation.count, 4)
        guard case .assistant(let first) = orchestrator.conversation[1].kind else {
            return XCTFail("Expected first answer preserved")
        }
        XCTAssertEqual(first, "first answer")
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

// MARK: - Test doubles

private final class CaptureCallCounter: CaptureProviding, @unchecked Sendable {
    let inner: StubCaptureProvider
    private let lock = NSLock()
    private(set) var captureCount = 0

    init(inner: StubCaptureProvider) {
        self.inner = inner
    }

    func capture(
        scope: CaptureScope,
        quick: Bool,
        encoding: CaptureEncodingParams
    ) async throws -> CaptureResult {
        _ = encoding
        lock.lock()
        captureCount += 1
        lock.unlock()
        return try await inner.capture(scope: scope, quick: quick, encoding: encoding)
    }
}

private final class SequentialMockInferenceEngine: InferenceEngine, @unchecked Sendable {
    var tokenSequences: [[String]]
    private let lock = NSLock()
    private var nextIndex = 0

    init(tokenSequences: [[String]]) {
        self.tokenSequences = tokenSequences
    }

    func health(baseURL: String, model: String, acceptInsecureRemote: Bool) async -> InferenceHealth { .ready }

    func warmUp(model: String, baseURL: String, acceptInsecureRemote: Bool) async -> Bool { true }

    func contextLength(model: String, baseURL: String, acceptInsecureRemote: Bool) async -> Int? { nil }

    func capabilities(model: String, baseURL: String, acceptInsecureRemote: Bool) async -> [String]? { nil }

    func stream(request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        _ = request
        lock.lock()
        let index = nextIndex
        nextIndex += 1
        lock.unlock()
        let tokens = index < tokenSequences.count ? tokenSequences[index] : []
        return AsyncThrowingStream { continuation in
            let task = Task {
                for token in tokens {
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
