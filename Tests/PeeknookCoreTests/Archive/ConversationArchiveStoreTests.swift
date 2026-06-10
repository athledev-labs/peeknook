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

    func testFailedThreadWriteDoesNotPruneExistingThreads() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConversationArchiveTestSupport.makeStore(directory: dir, maxThreads: 2)

        let oldest = thread("oldest", updatedAt: Date(timeIntervalSinceNow: 0))
        let middle = thread("middle", updatedAt: Date(timeIntervalSinceNow: 1))
        let saveOldest = await store.save(oldest)
        let saveMiddle = await store.save(middle)
        XCTAssertTrue(saveOldest.isSuccess)
        XCTAssertTrue(saveMiddle.isSuccess)

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)

        let newest = thread("newest", updatedAt: Date(timeIntervalSinceNow: 2))
        let failed = await store.save(newest)
        XCTAssertEqual(failed.archiveFailure, .threadWriteFailed)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)

        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(oldest.id.uuidString).json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(middle.id.uuidString).json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(newest.id.uuidString).json").path))
        let summaries = await store.summaries()
        XCTAssertEqual(summaries.count, 2)
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

    func testIndexFileIsEncryptedAtRest() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConversationArchiveTestSupport.makeStore(directory: dir)

        // The derived title is an excerpt of the user's text, so it must not sit on disk in cleartext.
        let secretTitle = "my secret api key question"
        let save = await store.save(thread(secretTitle))
        XCTAssertTrue(save.isSuccess)

        let indexURL = dir.appendingPathComponent("index.v2.json")
        let raw = try Data(contentsOf: indexURL)
        XCTAssertTrue(ArchiveEnvelope.isEncrypted(raw), "the index must be sealed at rest")
        XCTAssertNil(raw.range(of: Data(secretTitle.utf8)), "the derived title leaks in cleartext in the index")

        // …and it still round-trips through the switcher (decrypts on read).
        let summaries = await store.summaries()
        XCTAssertEqual(summaries.first?.title, secretTitle)
    }

    func testReencryptsPlaintextIndex() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Simulate a pre-encryption archive: a plaintext `index.v2.json`.
        let indexURL = dir.appendingPathComponent("index.v2.json")
        let summary = thread("legacy plaintext title").summary
        let plaintextIndex = ConversationArchiveIndex(version: 2, summaries: [summary])
        try JSONEncoder().encode(plaintextIndex).write(to: indexURL)
        XCTAssertFalse(ArchiveEnvelope.isEncrypted(try Data(contentsOf: indexURL)), "precondition: plaintext index")

        let store = ConversationArchiveTestSupport.makeStore(directory: dir)
        // Readable before migration (tolerant read).
        let before = await store.summaries()
        XCTAssertEqual(before.first?.title, "legacy plaintext title")

        let migrated = await store.reencryptPlaintextIndexIfNeeded()
        XCTAssertTrue(migrated, "should upgrade a plaintext index")
        XCTAssertTrue(ArchiveEnvelope.isEncrypted(try Data(contentsOf: indexURL)), "index sealed after migration")
        let after = await store.summaries()
        XCTAssertEqual(after.first?.title, "legacy plaintext title", "still readable after sealing")
        let secondRun = await store.reencryptPlaintextIndexIfNeeded()
        XCTAssertFalse(secondRun, "second run is a no-op once sealed")
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

    func testCustomTitleOverridesDerivedTitle() {
        let thread = ConversationThread(
            turns: [ChatTurn(id: 1, kind: .user("What is Swift?"))],
            customTitle: "Swift notes"
        )
        XCTAssertEqual(thread.title, "Swift notes")
    }

    func testRenamePersistsCustomTitleInIndex() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConversationArchiveTestSupport.makeStore(directory: dir)

        let original = thread("draft question")
        let save = await store.save(original)
        XCTAssertTrue(save.isSuccess)

        let renamed = await store.rename(id: original.id, customTitle: "My project")
        XCTAssertTrue(renamed.isSuccess)

        let summaries = await store.summaries()
        XCTAssertEqual(summaries.first?.title, "My project")
        let loaded = await store.load(id: original.id)
        XCTAssertEqual(loaded?.customTitle, "My project")
        XCTAssertEqual(loaded?.title, "My project")
    }

    func testCustomTitlePreservedWhenTurnsAppend() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConversationArchiveTestSupport.makeStore(directory: dir)

        var t = ConversationThread(
            turns: [ChatTurn(id: 1, kind: .user("first question"))],
            customTitle: "Pinned name"
        )
        let firstSave = await store.save(t)
        XCTAssertTrue(firstSave.isSuccess)

        t.turns.append(ChatTurn(id: 2, kind: .assistant("answer")))
        t.updatedAt = Date(timeIntervalSinceNow: 5)
        let secondSave = await store.save(t)
        XCTAssertTrue(secondSave.isSuccess)

        let loaded = await store.load(id: t.id)
        XCTAssertEqual(loaded?.customTitle, "Pinned name")
        XCTAssertEqual(loaded?.title, "Pinned name")
        let summaries = await store.summaries()
        XCTAssertEqual(summaries.first?.title, "Pinned name")
    }

    func testClearCustomTitleRevertsToDerived() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConversationArchiveTestSupport.makeStore(directory: dir)

        let original = thread("derived label")
        let save = await store.save(original)
        XCTAssertTrue(save.isSuccess)
        let tempRename = await store.rename(id: original.id, customTitle: "Temporary")
        XCTAssertTrue(tempRename.isSuccess)
        let clearRename = await store.rename(id: original.id, customTitle: "")
        XCTAssertTrue(clearRename.isSuccess)

        let loaded = await store.load(id: original.id)
        XCTAssertNil(loaded?.customTitle)
        XCTAssertEqual(loaded?.title, "derived label")
        let summaries = await store.summaries()
        XCTAssertEqual(summaries.first?.title, "derived label")
    }

    func testLegacyThreadDecodesWithoutCustomTitle() throws {
        struct LegacyWire: Encodable {
            let id: UUID
            let createdAt: Date
            let updatedAt: Date
            let turns: [ChatTurn]
            let turnCounter: Int
        }
        let data = try JSONEncoder().encode(
            LegacyWire(
                id: UUID(),
                createdAt: Date(),
                updatedAt: Date(),
                turns: [ChatTurn(id: 1, kind: .assistant("hello"))],
                turnCounter: 1
            )
        )
        let decoded = try JSONDecoder().decode(ConversationThread.self, from: data)
        XCTAssertNil(decoded.customTitle)
        XCTAssertEqual(decoded.title, "hello")
    }
}
