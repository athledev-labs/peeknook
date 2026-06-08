// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// Mock that reports usage stats and a fixed context window so context-pressure can be exercised.
private struct StatsInferenceEngine: InferenceEngine, Sendable {
    var tokens: [String]
    var promptTokens: Int
    var window: Int

    func health(baseURL: String, model: String) async -> InferenceHealth { .ready }

    func stream(request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                for token in tokens {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    if Task.isCancelled { break }
                    continuation.yield(.token(token))
                }
                continuation.yield(.completed(InferenceStats(promptTokens: promptTokens, responseTokens: 10, generationSeconds: 0.1)))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func contextLength(model: String, baseURL: String) async -> Int? { window }
}

@MainActor
final class ConversationArchiveFlowTests: XCTestCase {
    private func tempArchive() -> (ConversationArchiveStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peeknook-flow-\(UUID().uuidString)", isDirectory: true)
        return (ConversationArchiveStore(directory: dir), dir)
    }

    func testOpenThreadRestoresArchivedChatAsResult() async {
        let (store, dir) = tempArchive()
        defer { try? FileManager.default.removeItem(at: dir) }

        let saved = ConversationThread(
            turns: [
                ChatTurn(id: 1, kind: .user("question")),
                ChatTurn(id: 2, kind: .assistant("archived answer")),
            ],
            turnCounter: 2
        )
        let saveResult = await store.save(saved)
        XCTAssertTrue(saveResult.isSuccess)

        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(textModel: "gemma4:e4b", persistConversation: true),
            capture: StubCaptureProvider(sampleText: "x"),
            inference: MockInferenceEngine(tokens: ["y"])
        )
        orchestrator.conversationArchive = store

        let threads = await orchestrator.availableThreads()
        XCTAssertEqual(threads.count, 1)
        await orchestrator.openThread(id: saved.id)

        guard case .result("archived answer") = orchestrator.phase else {
            XCTFail("Expected restored result, got \(orchestrator.phase)")
            return
        }
        XCTAssertEqual(orchestrator.conversation.count, 2)
    }

    func testDeleteActiveThreadReturnsToIdle() async throws {
        let (store, dir) = tempArchive()
        defer { try? FileManager.default.removeItem(at: dir) }

        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e4b", persistConversation: true),
            capture: StubCaptureProvider(sampleText: "hello"),
            inference: MockInferenceEngine(tokens: ["hi"])
        )
        orchestrator.conversationArchive = store
        orchestrator.beginCapture()
        try await Task.sleep(nanoseconds: 350_000_000)
        try await Task.sleep(nanoseconds: 200_000_000)

        let summaries = await orchestrator.availableThreads()
        XCTAssertEqual(summaries.count, 1)

        await orchestrator.openThread(id: summaries[0].id)
        orchestrator.deleteThread(id: summaries[0].id)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(orchestrator.phase, .idle)
        XCTAssertFalse(orchestrator.hasConversation)
        let remaining = await orchestrator.availableThreads()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testContextPressureCriticalNearWindowLimit() async throws {
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e4b"),
            capture: StubCaptureProvider(sampleText: "hello"),
            inference: StatsInferenceEngine(tokens: ["ok"], promptTokens: 950, window: 1000)
        )
        orchestrator.beginCapture()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(orchestrator.contextPressure, .critical)
        XCTAssertEqual(orchestrator.contextFraction ?? 0, 0.95, accuracy: 0.001)
    }

    func testContextPressureHighBelowCritical() async throws {
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e4b"),
            capture: StubCaptureProvider(sampleText: "hello"),
            inference: StatsInferenceEngine(tokens: ["ok"], promptTokens: 850, window: 1000)
        )
        orchestrator.beginCapture()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(orchestrator.contextPressure, .high)
    }

    func testContextPressureNormalWhenWindowUnknown() async throws {
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e4b"),
            capture: StubCaptureProvider(sampleText: "hello"),
            inference: MockInferenceEngine(tokens: ["ok"])
        )
        orchestrator.beginCapture()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(orchestrator.contextPressure, .normal)
    }
}
