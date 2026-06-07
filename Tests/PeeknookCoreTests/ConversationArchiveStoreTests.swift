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

    func testSaveListLoadDelete() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConversationArchiveStore(directory: dir)

        let a = thread("first", updatedAt: Date(timeIntervalSinceNow: -60))
        let b = thread("second", updatedAt: Date())
        store.save(a)
        store.save(b)

        let summaries = store.summaries()
        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(summaries.first?.id, b.id, "Newest thread should sort first")

        let loaded = store.load(id: a.id)
        XCTAssertEqual(loaded?.id, a.id)
        XCTAssertEqual(loaded?.title, "first")

        store.delete(id: a.id)
        XCTAssertEqual(store.summaries().count, 1)
        XCTAssertNil(store.load(id: a.id))
    }

    func testSaveSkipsEmptyThread() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConversationArchiveStore(directory: dir)
        store.save(ConversationThread(turns: []))
        XCTAssertTrue(store.summaries().isEmpty)
    }

    func testUpdatingExistingThreadDoesNotDuplicate() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConversationArchiveStore(directory: dir)

        var t = thread("draft")
        store.save(t)
        t.turns.append(ChatTurn(id: 2, kind: .user("more")))
        t.updatedAt = Date(timeIntervalSinceNow: 5)
        store.save(t)

        XCTAssertEqual(store.summaries().count, 1)
        XCTAssertEqual(store.load(id: t.id)?.turns.count, 2)
    }

    func testDeleteAllClearsArchive() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConversationArchiveStore(directory: dir)
        store.save(thread("a"))
        store.save(thread("b"))
        store.deleteAll()
        XCTAssertTrue(store.summaries().isEmpty)
    }

    func testRetentionPrunesOldestOverCountCap() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConversationArchiveStore(directory: dir, maxThreads: 3)

        var ids: [UUID] = []
        for i in 0..<5 {
            let t = thread("chat \(i)", updatedAt: Date(timeIntervalSinceNow: Double(i)))
            ids.append(t.id)
            store.save(t)
        }

        let remaining = store.summaries().map(\.id)
        XCTAssertEqual(remaining.count, 3)
        XCTAssertFalse(remaining.contains(ids[0]), "Oldest should be pruned")
        XCTAssertFalse(remaining.contains(ids[1]), "Second oldest should be pruned")
        XCTAssertTrue(remaining.contains(ids[4]), "Newest should survive")
    }

    func testMigratesLegacySingleFile() throws {
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

        let store = ConversationArchiveStore(directory: dir, legacyFileURL: legacyURL)
        let migrated = store.migrateLegacyIfNeeded()

        XCTAssertNotNil(migrated)
        XCTAssertEqual(migrated?.contextWindow, 4096)
        XCTAssertEqual(store.summaries().count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path), "Legacy file should be removed after migration")

        // Idempotent: a second call (index now exists) migrates nothing.
        XCTAssertNil(store.migrateLegacyIfNeeded())
    }

    func testMigrationSkippedWhenArchiveAlreadyExists() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConversationArchiveStore(directory: dir, legacyFileURL: dir.appendingPathComponent("conversation.v1.json"))
        store.save(thread("existing"))

        // Write a legacy file after the archive exists, it must be ignored.
        let legacyURL = dir.appendingPathComponent("conversation.v1.json")
        let legacy = PersistedConversation(turns: [ChatTurn(id: 9, kind: .assistant("old"))], contextWindow: nil, turnCounter: 9, lastPromptTokens: nil)
        try JSONEncoder().encode(legacy).write(to: legacyURL)

        XCTAssertNil(store.migrateLegacyIfNeeded())
        XCTAssertEqual(store.summaries().count, 1)
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
