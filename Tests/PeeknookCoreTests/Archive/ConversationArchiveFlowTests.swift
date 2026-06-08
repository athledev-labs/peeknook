// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// Mock that reports usage stats and a fixed context window so context-pressure can be exercised.
private struct StatsInferenceEngine: InferenceEngine, Sendable {
    var tokens: [String]
    var promptTokens: Int
    var window: Int

    func health(baseURL: String, model: String, acceptInsecureRemote: Bool) async -> InferenceHealth { .ready }

    func warmUp(model: String, baseURL: String, acceptInsecureRemote: Bool) async -> Bool { true }

    func contextLength(model: String, baseURL: String, acceptInsecureRemote: Bool) async -> Int? { window }

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

    func capabilities(model: String, baseURL: String, acceptInsecureRemote: Bool) async -> [String]? { nil }
}

@MainActor
final class ConversationArchiveFlowTests: XCTestCase {
    private func tempArchive() -> (ConversationArchiveStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peeknook-flow-\(UUID().uuidString)", isDirectory: true)
        return (ConversationArchiveTestSupport.makeStore(directory: dir), dir)
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

    func testLaunchRestoreSkipsAdoptWhenSessionMovedOn() async {
        // The launch restore runs in an unstructured Task that spans file IO. If the session moves
        // on while it loads (the user starts a new chat / a capture), it must not adopt the stale
        // thread over the user's action.
        let (store, dir) = tempArchive()
        defer { try? FileManager.default.removeItem(at: dir) }

        let saved = ConversationThread(
            turns: [
                ChatTurn(id: 1, kind: .user("old question")),
                ChatTurn(id: 2, kind: .assistant("stale archived answer")),
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

        // Kick off the async restore, then synchronously move the session on before its IO resolves.
        orchestrator.loadPersistedConversationIfEnabled()
        orchestrator.startNewChat()

        // Give the restore task time to run its file IO and (pre-fix) adopt the stale thread.
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(orchestrator.conversation.isEmpty, "restore adopted a stale thread after the session moved on")
        guard case .idle = orchestrator.phase else {
            return XCTFail("Expected idle, got \(orchestrator.phase)")
        }
    }

    func testOpenThreadIgnoredWhenPersistenceOff() async {
        // With persistence off the History switcher is hidden, but openThread must also refuse to
        // surface archived content directly (a stale id can't resurrect an opted-out chat).
        let (store, dir) = tempArchive()
        defer { try? FileManager.default.removeItem(at: dir) }

        let saved = ConversationThread(
            turns: [ChatTurn(id: 1, kind: .assistant("archived answer"))],
            turnCounter: 1
        )
        let save = await store.save(saved)
        XCTAssertTrue(save.isSuccess)

        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(textModel: "gemma4:e4b", persistConversation: false),
            capture: StubCaptureProvider(sampleText: "x"),
            inference: MockInferenceEngine(tokens: ["y"])
        )
        orchestrator.conversationArchive = store

        await orchestrator.openThread(id: saved.id)

        guard case .idle = orchestrator.phase else {
            return XCTFail("openThread must not surface archived content when persistence is off, got \(orchestrator.phase)")
        }
        XCTAssertTrue(orchestrator.conversation.isEmpty)
    }

    func testDeleteActiveThreadMidFollowUpStaysIdle() async {
        // Deleting the on-screen chat while a follow-up is streaming must abort that work, or the
        // late stream re-files an answer for a thread that no longer exists.
        let (store, dir) = tempArchive()
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = ScriptedEngine(responsesPerCall: [["first answer"], Array(repeating: "x ", count: 15)])
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "x", persistConversation: true),
            capture: StubCaptureProvider(sampleText: "screen"),
            inference: engine
        )
        orchestrator.conversationArchive = store

        orchestrator.beginCapture()
        _ = await orchestrator.waitForResult("first answer")
        guard let active = orchestrator.activeThreadID else {
            return XCTFail("Expected an active thread id after the first answer")
        }

        orchestrator.sendFollowUp("expand")
        let inferring = await orchestrator.waitForPhase { if case .inferring = $0 { return true }; return false }
        guard case .inferring = inferring else {
            return XCTFail("Expected to catch the follow-up inferring, got \(inferring)")
        }

        orchestrator.deleteThread(id: active)
        guard case .idle = orchestrator.phase else {
            return XCTFail("Expected idle after deleting the active thread, got \(orchestrator.phase)")
        }

        // Stays idle: a leaked follow-up stream must not re-file an answer for the deleted thread.
        // Poll rather than sleep-then-check so the assertion can't false-pass under CI load.
        let held = await orchestrator.phaseHolding({ if case .idle = $0 { return true }; return false })
        guard case .idle = held else {
            return XCTFail("A leaked follow-up resurrected a result after delete: \(held)")
        }
        XCTAssertTrue(orchestrator.conversation.isEmpty)
    }

    func testOpenThreadIgnoresStaleLoadWhenSwitchedAway() async {
        // openThread snapshots sessionGeneration before its archive load. If the user moves the
        // session on (a new chat) while the load is in flight, the newer intent wins — the stale
        // thread must not be adopted over the cleared session. (Sibling of the launch-restore guard,
        // but on the user-initiated History-switcher path.)
        let (store, dir) = tempArchive()
        defer { try? FileManager.default.removeItem(at: dir) }

        let threadA = ConversationThread(
            turns: [ChatTurn(id: 1, kind: .assistant("stale thread A answer"))],
            turnCounter: 1
        )
        let saveResult = await store.save(threadA)
        XCTAssertTrue(saveResult.isSuccess)

        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(textModel: "gemma4:e4b", persistConversation: true),
            capture: StubCaptureProvider(sampleText: "x"),
            inference: MockInferenceEngine(tokens: ["y"])
        )
        orchestrator.conversationArchive = store

        // openThread does only synchronous work (the generation snapshot) before `await archive.load`,
        // so one yield reliably parks it at that suspension on the cooperative main-actor executor.
        let opening = Task { await orchestrator.openThread(id: threadA.id) }
        await Task.yield()
        orchestrator.startNewChat()
        await opening.value

        XCTAssertTrue(orchestrator.conversation.isEmpty, "openThread adopted a stale thread after the user switched away")
        guard case .idle = orchestrator.phase else {
            return XCTFail("Expected idle, got \(orchestrator.phase)")
        }
    }
}
