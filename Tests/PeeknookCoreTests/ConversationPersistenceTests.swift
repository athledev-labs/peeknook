// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

@MainActor
final class ConversationPersistenceTests: XCTestCase {
    private func tempStore() -> (ConversationStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("peeknook-test-\(UUID().uuidString).json")
        return (ConversationStore(fileURL: url), url)
    }

    func testEnabledPersistenceSavesAndReloadsAcrossOrchestrators() async throws {
        let (store, url) = tempStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let first = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e4b", persistConversation: true),
            capture: StubCaptureProvider(sampleText: "hello"),
            inference: MockInferenceEngine(tokens: ["ans", "wer"])
        )
        first.conversationStore = store
        first.beginCapture()
        try await Task.sleep(nanoseconds: 200_000_000)

        guard case .result("answer") = first.phase else {
            XCTFail("Expected result, got \(first.phase)")
            return
        }
        // The detached save task needs a beat to land on disk.
        try await Task.sleep(nanoseconds: 150_000_000)

        let second = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e4b", persistConversation: true),
            capture: StubCaptureProvider(sampleText: "x"),
            inference: MockInferenceEngine(tokens: ["y"])
        )
        second.conversationStore = store
        second.loadPersistedConversationIfEnabled()

        XCTAssertTrue(second.hasConversation)
        second.resumeChat()
        guard case .result("answer") = second.phase else {
            XCTFail("Expected restored result, got \(second.phase)")
            return
        }
    }

    func testDisabledPersistenceWritesNothing() async throws {
        let (store, url) = tempStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e4b", persistConversation: false),
            capture: StubCaptureProvider(sampleText: "hello"),
            inference: MockInferenceEngine(tokens: ["ok"])
        )
        orchestrator.conversationStore = store
        orchestrator.beginCapture()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertNil(store.load(), "Persistence off should never write a file")
    }

    func testPurgeClearsSavedConversation() async throws {
        let (store, url) = tempStore()
        defer { try? FileManager.default.removeItem(at: url) }

        store.save(PersistedConversation(turns: [ChatTurn(id: 1, kind: .assistant("hi"))], contextWindow: nil, turnCounter: 1, lastPromptTokens: nil))
        XCTAssertNotNil(store.load())

        store.clear()
        XCTAssertNil(store.load())
    }

    func testConversationMarkdownRendersTurns() async {
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e4b"),
            capture: StubCaptureProvider(sampleText: "screen text", appName: "Safari", windowTitle: "Docs"),
            inference: MockInferenceEngine(tokens: ["The ", "answer"])
        )
        orchestrator.beginCapture()
        try? await Task.sleep(nanoseconds: 200_000_000)

        let markdown = orchestrator.conversationMarkdown()
        XCTAssertTrue(markdown.contains("Safari — Docs"))
        XCTAssertTrue(markdown.contains("**Peeknook:**"))
        XCTAssertTrue(markdown.contains("The answer"))
    }
}
