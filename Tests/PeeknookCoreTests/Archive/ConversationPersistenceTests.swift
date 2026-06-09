// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

@MainActor
final class ConversationPersistenceTests: XCTestCase {
    private func tempArchive() -> (ConversationArchiveStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peeknook-archive-\(UUID().uuidString)", isDirectory: true)
        return (ConversationArchiveTestSupport.makeStore(directory: dir), dir)
    }

    func testEnabledPersistenceSavesAndReloadsAcrossOrchestrators() async throws {
        let (store, dir) = tempArchive()
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e4b", persistConversation: true),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "hello")]),
            inference: MockInferenceEngine(tokens: ["ans", "wer"])
        )
        first.conversationArchive = store
        first.beginCapture()
        let firstPhase = await first.waitForResult("answer")
        guard case .result("answer") = firstPhase else {
            XCTFail("Expected result, got \(firstPhase)")
            return
        }
        _ = await store.waitForSummaries(count: 1)

        let second = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e4b", persistConversation: true),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "x")]),
            inference: MockInferenceEngine(tokens: ["y"])
        )
        second.conversationArchive = store
        second.loadPersistedConversationIfEnabled()
        let restored = await second.waitUntil { second.hasConversation }
        XCTAssertTrue(restored)

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
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "hello")]),
            inference: MockInferenceEngine(tokens: ["ok"])
        )
        orchestrator.conversationArchive = store
        orchestrator.beginCapture()
        _ = await orchestrator.waitForResult("ok")

        let summaries = await store.summaries()
        XCTAssertTrue(summaries.isEmpty, "Persistence off should never write a thread")
    }

    func testArchivePersistenceIssueSurfacesWhenSaveFails() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("peeknook-persist-fail-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let blocked = parent.appendingPathComponent("blocked-dir")
        try "not a directory".write(to: blocked, atomically: true, encoding: .utf8)

        let store = ConversationArchiveTestSupport.makeStore(directory: blocked)
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e4b", persistConversation: true),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "hello")]),
            inference: MockInferenceEngine(tokens: ["hi"])
        )
        orchestrator.conversationArchive = store
        orchestrator.beginCapture()
        _ = await orchestrator.waitForResult("hi")
        let issueReported = await orchestrator.waitForArchivePersistenceIssue(.directoryUnavailable)
        XCTAssertTrue(issueReported)
    }

    func testDiscardActiveThreadRemovesItFromArchive() async throws {
        let (store, dir) = tempArchive()
        defer { try? FileManager.default.removeItem(at: dir) }

        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e4b", persistConversation: true),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "hello")]),
            inference: MockInferenceEngine(tokens: ["hi"])
        )
        orchestrator.conversationArchive = store
        orchestrator.beginCapture()
        _ = await orchestrator.waitForResult("hi")
        let beforeDiscard = await store.waitForSummaries(count: 1)
        XCTAssertEqual(beforeDiscard.count, 1)

        orchestrator.startNewChat()
        let afterDiscard = await store.waitForSummaries(count: 0)
        XCTAssertTrue(afterDiscard.isEmpty, "Discarding the active chat should remove it from the archive")
    }

    func testConversationMarkdownRendersTurns() async {
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e4b"),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "screen text", appName: "Safari", windowTitle: "Docs")]),
            inference: MockInferenceEngine(tokens: ["The ", "answer"])
        )
        orchestrator.beginCapture()
        let phase = await orchestrator.waitForResult("The answer")
        guard case .result = phase else {
            XCTFail("Expected result, got \(phase)")
            return
        }

        let markdown = orchestrator.conversationMarkdown()
        XCTAssertTrue(markdown.contains("Safari · Docs"))
        XCTAssertTrue(markdown.contains("**Peeknook:**"))
        XCTAssertTrue(markdown.contains("The answer"))
    }
}
