// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

@MainActor
final class ConversationPersistenceTests: XCTestCase {
    private func tempArchive() -> (ConversationArchiveStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peeknook-archive-\(UUID().uuidString)", isDirectory: true)
        return (ConversationArchiveStore(directory: dir), dir)
    }

    func testEnabledPersistenceSavesAndReloadsAcrossOrchestrators() async throws {
        let (store, dir) = tempArchive()
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e4b", persistConversation: true),
            capture: StubCaptureProvider(sampleText: "hello"),
            inference: MockInferenceEngine(tokens: ["ans", "wer"])
        )
        first.conversationArchive = store
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
        second.conversationArchive = store
        second.loadPersistedConversationIfEnabled()

        XCTAssertTrue(second.hasConversation)
        second.resumeChat()
        guard case .result("answer") = second.phase else {
            XCTFail("Expected restored result, got \(second.phase)")
            return
        }
    }

    func testDisabledPersistenceWritesNothing() async throws {
        let (store, dir) = tempArchive()
        defer { try? FileManager.default.removeItem(at: dir) }

        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e4b", persistConversation: false),
            capture: StubCaptureProvider(sampleText: "hello"),
            inference: MockInferenceEngine(tokens: ["ok"])
        )
        orchestrator.conversationArchive = store
        orchestrator.beginCapture()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(store.summaries().isEmpty, "Persistence off should never write a thread")
    }

    func testDiscardActiveThreadRemovesItFromArchive() async throws {
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
        XCTAssertEqual(store.summaries().count, 1)

        orchestrator.startNewChat() // discards the active thread
        XCTAssertTrue(store.summaries().isEmpty, "Discarding the active chat should remove it from the archive")
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
        XCTAssertTrue(markdown.contains("Safari · Docs"))
        XCTAssertTrue(markdown.contains("**Peeknook:**"))
        XCTAssertTrue(markdown.contains("The answer"))
    }
}
