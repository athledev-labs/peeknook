// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

final class ConversationArchiveStoreTests: XCTestCase {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("peeknook-archive-\(UUID().uuidString)", isDirectory: true)
    }

    private func thread(_ text: String, updatedAt: Date = Date()) -> ConversationThread {
        ConversationThread(
            createdAt: updatedAt,
            updatedAt: updatedAt,
            turns: [ChatTurn(id: 1, kind: .assistant(text))],
            turnCounter: 1
        )
    }

    func testSaveListLoadDelete() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConversationArchiveTestSupport.makeStore(directory: dir)

        let a = thread("first", updatedAt: Date(timeIntervalSinceNow: -60))
        let b = thread("second", updatedAt: Date())
        let saveA = await store.save(a)
        let saveB = await store.save(b)
        XCTAssertTrue(saveA.isSuccess)
        XCTAssertTrue(saveB.isSuccess)

        let summaries = await store.summaries()
        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(summaries.first?.id, b.id, "Newest thread should sort first")

        let loaded = await store.load(id: a.id)
        XCTAssertEqual(loaded?.id, a.id)
        XCTAssertEqual(loaded?.title, "first")

        await store.delete(id: a.id)
        let afterDelete = await store.summaries()
        XCTAssertEqual(afterDelete.count, 1)
        let deletedLoad = await store.load(id: a.id)
        XCTAssertNil(deletedLoad)
    }

    func testSaveSkipsEmptyThread() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConversationArchiveTestSupport.makeStore(directory: dir)
        let emptySave = await store.save(ConversationThread(turns: []))
        XCTAssertTrue(emptySave.isSuccess)
        let summaries = await store.summaries()
        XCTAssertTrue(summaries.isEmpty)
    }

    func testUpdatingExistingThreadDoesNotDuplicate() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConversationArchiveTestSupport.makeStore(directory: dir)

        var t = thread("draft")
        let firstSave = await store.save(t)
        XCTAssertTrue(firstSave.isSuccess)
        t.turns.append(ChatTurn(id: 2, kind: .user("more")))
        t.updatedAt = Date(timeIntervalSinceNow: 5)
        let secondSave = await store.save(t)
        XCTAssertTrue(secondSave.isSuccess)

        let summaries = await store.summaries()
        XCTAssertEqual(summaries.count, 1)
        let loaded = await store.load(id: t.id)
        XCTAssertEqual(loaded?.turns.count, 2)
    }

    func testDeleteAllClearsArchive() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConversationArchiveTestSupport.makeStore(directory: dir)
        let saveA = await store.save(thread("a"))
        let saveB = await store.save(thread("b"))
        XCTAssertTrue(saveA.isSuccess)
        XCTAssertTrue(saveB.isSuccess)
        await store.deleteAll()
        let summaries = await store.summaries()
        XCTAssertTrue(summaries.isEmpty)
    }

    func testRetentionPrunesOldestOverCountCap() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConversationArchiveTestSupport.makeStore(directory: dir, maxThreads: 3)

        var ids: [UUID] = []
        for i in 0..<5 {
            let t = thread("chat \(i)", updatedAt: Date(timeIntervalSinceNow: Double(i)))
            ids.append(t.id)
            let save = await store.save(t)
            XCTAssertTrue(save.isSuccess)
        }

        let remaining = await store.summaries().map(\.id)
        XCTAssertEqual(remaining.count, 3)
        XCTAssertFalse(remaining.contains(ids[0]), "Oldest should be pruned")
        XCTAssertFalse(remaining.contains(ids[1]), "Second oldest should be pruned")
        XCTAssertTrue(remaining.contains(ids[4]), "Newest should survive")
    }

    func testMigratesLegacySingleFile() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacyURL = dir.appendingPathComponent("conversation.v1.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let legacy = PersistedConversation(
            turns: [ChatTurn(id: 1, kind: .assistant("legacy answer"))],
            contextWindow: 4096,
            turnCounter: 1,
            lastPromptTokens: 120
        )
        try JSONEncoder().encode(legacy).write(to: legacyURL)

        let store = ConversationArchiveTestSupport.makeStore(directory: dir, legacyFileURL: legacyURL)
        let migrated = await store.migrateLegacyIfNeeded()

        XCTAssertNotNil(migrated)
        XCTAssertEqual(migrated?.contextWindow, 4096)
        let summaries = await store.summaries()
        XCTAssertEqual(summaries.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path), "Legacy file should be removed after migration")

        let secondMigration = await store.migrateLegacyIfNeeded()
        XCTAssertNil(secondMigration)
    }

    func testMigrationSkippedWhenArchiveAlreadyExists() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConversationArchiveTestSupport.makeStore(
            directory: dir,
            legacyFileURL: dir.appendingPathComponent("conversation.v1.json")
        )
        let existingSave = await store.save(thread("existing"))
        XCTAssertTrue(existingSave.isSuccess)

        let legacyURL = dir.appendingPathComponent("conversation.v1.json")
        let legacy = PersistedConversation(turns: [ChatTurn(id: 9, kind: .assistant("old"))], contextWindow: nil, turnCounter: 9, lastPromptTokens: nil)
        try JSONEncoder().encode(legacy).write(to: legacyURL)

        let skipped = await store.migrateLegacyIfNeeded()
        XCTAssertNil(skipped)
        let summaries = await store.summaries()
        XCTAssertEqual(summaries.count, 1)
    }

    func testSaveFailsWhenDirectoryIsFile() async {
        let parent = tempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let dir = parent.appendingPathComponent("blocked-dir")
        try? "not a directory".write(to: dir, atomically: true, encoding: .utf8)

        let store = ConversationArchiveTestSupport.makeStore(directory: dir)
        let result = await store.save(thread("blocked"))

        XCTAssertEqual(result.archiveFailure, .directoryUnavailable)
    }

    func testDerivedTitlePrefersQuestionThenAnswerThenCapture() {
        let withUser = ConversationThread(turns: [
            ChatTurn(id: 1, kind: .image(CaptureResult(text: nil, sourceLabel: "Vision", appName: "Safari", windowTitle: "Docs"))),
            ChatTurn(id: 2, kind: .user("What does this regex do?")),
            ChatTurn(id: 3, kind: .assistant("It matches…")),
        ])
        XCTAssertEqual(withUser.title, "What does this regex do?")

        let answerOnly = ConversationThread(turns: [
            ChatTurn(id: 1, kind: .assistant("A long assistant explanation that should be condensed for the row title display.")),
        ])
        XCTAssertTrue(answerOnly.title.hasSuffix("…"))
        XCTAssertLessThanOrEqual(answerOnly.title.count, 50)
    }
}
