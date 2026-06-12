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

    func testDiscardRacingTheSaveDoesNotResurrectTheThreadFile() async throws {
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
        // Discard WITHOUT first waiting for the save to settle: the answer completion synchronously mints
        // the thread id and enqueues the save, so this delete is enqueued while the save is still in flight.
        // The observable contract: the discarded thread must leave NO summary and NO file behind. Today two
        // things uphold it — the archive `save` is a single synchronous actor hop (so save-then-delete is
        // atomic in creation order) AND `enqueueArchiveIO` chains the delete behind the save's completion.
        // The chain is the load-bearing guarantee if `save` ever gains a suspension point (e.g. async blob
        // writes), where actor reentrancy could otherwise let an unchained delete run mid-save and a late
        // write resurrect the file. This test pins the contract; it is not a race-forcing regression.
        orchestrator.startNewChat()

        // Both ops bump the archive revision; >= 2 means the save AND the delete have both run.
        let settled = await orchestrator.waitUntil { orchestrator.archiveRevision >= 2 }
        XCTAssertTrue(settled, "the save and the delete both completed")

        let summaries = await store.summaries()
        XCTAssertTrue(summaries.isEmpty, "a discard racing the save leaves no summary in the index")
        let threadFiles = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".json") && $0 != "index.v2.json" }
        XCTAssertTrue(threadFiles.isEmpty, "no thread file may survive a discard that raced the save")
    }

    func testArchiveRevisionIncrementsAfterSave() async throws {
        let (store, dir) = tempArchive()
        defer { try? FileManager.default.removeItem(at: dir) }

        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e4b", persistConversation: true),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "hello")]),
            inference: MockInferenceEngine(tokens: ["saved"])
        )
        orchestrator.conversationArchive = store
        XCTAssertEqual(orchestrator.archiveRevision, 0)

        orchestrator.beginCapture()
        _ = await orchestrator.waitForResult("saved")
        _ = await orchestrator.waitUntil { orchestrator.archiveRevision > 0 }
        XCTAssertGreaterThan(orchestrator.archiveRevision, 0)
    }

    func testPurgeAllClearsInMemoryAndReturnsIdle() async throws {
        let (store, dir) = tempArchive()
        defer { try? FileManager.default.removeItem(at: dir) }

        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e4b", persistConversation: true),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "hello")]),
            inference: MockInferenceEngine(tokens: ["answer"])
        )
        orchestrator.conversationArchive = store
        orchestrator.beginCapture()
        _ = await orchestrator.waitForResult("answer")
        _ = await store.waitForSummaries(count: 1)

        orchestrator.purgeAllConversations()

        guard case .idle = orchestrator.phase else {
            XCTFail("Expected idle after purge, got \(orchestrator.phase)")
            return
        }
        XCTAssertTrue(orchestrator.conversation.isEmpty)
        XCTAssertFalse(orchestrator.hasConversation)
        let summaries = await store.waitForSummaries(count: 0)
        XCTAssertTrue(summaries.isEmpty)
    }

    func testSetPersistConversationOffPurgesDiskAndMemory() async throws {
        let (store, dir) = tempArchive()
        defer { try? FileManager.default.removeItem(at: dir) }

        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e4b", persistConversation: true),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "hello")]),
            inference: MockInferenceEngine(tokens: ["saved"])
        )
        orchestrator.conversationArchive = store
        let defaults = UserDefaults(suiteName: "peeknook.test.\(UUID().uuidString)")!
        let setup = SetupCoordinator(settings: orchestrator.settings, defaults: defaults)
        let controller = PeekSettingsController(
            orchestrator: orchestrator,
            setup: setup,
            defaults: defaults,
            inference: MockInferenceEngine(tokens: ["x"])
        )

        orchestrator.beginCapture()
        _ = await orchestrator.waitForResult("saved")
        _ = await store.waitForSummaries(count: 1)

        controller.setPersistConversation(false)

        guard case .idle = orchestrator.phase else {
            XCTFail("Expected idle after toggle off, got \(orchestrator.phase)")
            return
        }
        XCTAssertTrue(orchestrator.conversation.isEmpty)
        XCTAssertFalse(controller.settings.persistConversation)
        let summaries = await store.waitForSummaries(count: 0)
        XCTAssertTrue(summaries.isEmpty)
    }

    func testPersistConversationOffThenOnDoesNotResurrectThread() async throws {
        let (store, dir) = tempArchive()
        defer { try? FileManager.default.removeItem(at: dir) }

        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e4b", persistConversation: true),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "hello")]),
            inference: MockInferenceEngine(tokens: ["saved"])
        )
        orchestrator.conversationArchive = store
        let defaults = UserDefaults(suiteName: "peeknook.test.\(UUID().uuidString)")!
        let setup = SetupCoordinator(settings: orchestrator.settings, defaults: defaults)
        let controller = PeekSettingsController(
            orchestrator: orchestrator,
            setup: setup,
            defaults: defaults,
            inference: MockInferenceEngine(tokens: ["x"])
        )

        orchestrator.beginCapture()
        _ = await orchestrator.waitForResult("saved")
        _ = await store.waitForSummaries(count: 1)

        controller.setPersistConversation(false)
        _ = await store.waitForSummaries(count: 0)
        controller.setPersistConversation(true)

        let summaries = await store.summaries()
        XCTAssertTrue(summaries.isEmpty, "Re-enabling persistence must not resurrect a purged thread from memory")
        XCTAssertTrue(orchestrator.conversation.isEmpty)
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
