// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// Fail-closed downgrade resistance: once the trusted "archive sealed" marker is set, plaintext
/// index/thread files (which an attacker who can write local files could plant) are refused on read.
/// Before the marker is set, plaintext is still accepted and migrated so genuine pre-encryption
/// archives and transient keychain outages never lose History.
final class ConversationArchiveFailClosedTests: XCTestCase {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("peeknook-failclosed-\(UUID().uuidString)", isDirectory: true)
    }

    private func thread(_ text: String, id: UUID = UUID(), updatedAt: Date = Date()) -> ConversationThread {
        ConversationThread(
            id: id,
            createdAt: updatedAt,
            updatedAt: updatedAt,
            turns: [ChatTurn(id: 1, kind: .assistant(text))],
            turnCounter: 1
        )
    }

    private func writePlaintextIndex(_ summaries: [ConversationSummary], to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let index = ConversationArchiveIndex(version: 2, summaries: summaries)
        let url = dir.appendingPathComponent("index.v2.json")
        try JSONEncoder().encode(index).write(to: url)
        XCTAssertFalse(ArchiveEnvelope.isEncrypted(try Data(contentsOf: url)), "precondition: plaintext index")
    }

    private func writePlaintextThread(_ thread: ConversationThread, to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(thread.id.uuidString).json")
        try JSONEncoder().encode(thread).write(to: url)
        XCTAssertFalse(ArchiveEnvelope.isEncrypted(try Data(contentsOf: url)), "precondition: plaintext thread")
    }

    // 1. Marker set ⇒ a downgraded plaintext index is refused (returns no summaries).
    func testSealedMarkerRefusesPlaintextIndex() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let secretTitle = "leaked plaintext title"
        try writePlaintextIndex([thread(secretTitle).summary], to: dir)

        let store = ConversationArchiveTestSupport.makeStore(
            directory: dir,
            protection: MarkerArchiveProtection(box: SealMarkerBox(sealed: true))
        )
        let summaries = await store.summaries()
        XCTAssertTrue(summaries.isEmpty, "a sealed archive must refuse a downgraded plaintext index")
    }

    // 2. Marker set ⇒ a downgraded plaintext thread is refused (load returns nil).
    func testSealedMarkerRefusesPlaintextThread() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let planted = thread("planted plaintext thread")
        try writePlaintextThread(planted, to: dir)

        let store = ConversationArchiveTestSupport.makeStore(
            directory: dir,
            protection: MarkerArchiveProtection(box: SealMarkerBox(sealed: true))
        )
        let loaded = await store.load(id: planted.id)
        XCTAssertNil(loaded, "a sealed archive must refuse a downgraded plaintext thread")
    }

    // 3. Marker unset ⇒ plaintext is accepted and can be migrated/sealed (no data loss pre-seal).
    func testUnsealedMarkerAcceptsAndMigratesPlaintextIndex() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try writePlaintextIndex([thread("legacy plaintext title").summary], to: dir)

        let store = ConversationArchiveTestSupport.makeStore(
            directory: dir,
            protection: MarkerArchiveProtection(box: SealMarkerBox(sealed: false))
        )
        let before = await store.summaries()
        XCTAssertEqual(before.first?.title, "legacy plaintext title", "plaintext accepted while marker is unset")

        let migrated = await store.reencryptPlaintextIndexIfNeeded()
        XCTAssertTrue(migrated, "an unsealed plaintext index should be adopted and sealed")
        let indexURL = dir.appendingPathComponent("index.v2.json")
        XCTAssertTrue(ArchiveEnvelope.isEncrypted(try Data(contentsOf: indexURL)), "index sealed after migration")
    }

    // 3b. A genuine first save records the seal, so a later planted plaintext index is refused.
    // This isolates `recordSealed()` being called from `writeIndex` after the sealed index lands.
    func testFirstSaveRecordsSealAndThenRefusesPlaintextIndex() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let box = SealMarkerBox(sealed: false)
        let store = ConversationArchiveTestSupport.makeStore(
            directory: dir,
            protection: MarkerArchiveProtection(box: box)
        )
        // Genuine save seals the index; writeIndex must flip the trusted marker afterward.
        let saved = await store.save(thread("real chat"))
        XCTAssertTrue(saved.isSuccess)
        XCTAssertEqual(box.value(), true, "writeIndex must record the seal in the trusted marker")

        // Now an attacker overwrites the sealed index with a downgraded plaintext one.
        try Data(try JSONEncoder().encode(
            ConversationArchiveIndex(version: 2, summaries: [thread("forged downgrade").summary])
        )).write(to: dir.appendingPathComponent("index.v2.json"))

        let summaries = await store.summaries()
        XCTAssertTrue(summaries.isEmpty, "after a real seal, a downgraded plaintext index must be refused")
    }

    // 4. Marker unavailable (nil) ⇒ plaintext still accepted (fail-soft, no History loss).
    func testUnavailableMarkerAcceptsPlaintextIndex() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try writePlaintextIndex([thread("still readable title").summary], to: dir)

        let store = ConversationArchiveTestSupport.makeStore(
            directory: dir,
            protection: MarkerArchiveProtection(box: SealMarkerBox(sealed: false, available: false))
        )
        let summaries = await store.summaries()
        XCTAssertEqual(summaries.first?.title, "still readable title", "nil marker must fail soft, not refuse plaintext")
    }

    // 5. Legacy migration still works with the marker present but unset.
    func testLegacyMigrationWorksWithMarkerUnset() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacyURL = dir.appendingPathComponent("conversation.v1.json")

        let legacy = PersistedConversation(
            turns: [ChatTurn(id: 1, kind: .assistant("legacy answer"))],
            contextWindow: 4096,
            turnCounter: 1,
            lastPromptTokens: 120
        )
        try JSONEncoder().encode(legacy).write(to: legacyURL)

        let store = ConversationArchiveTestSupport.makeStore(
            directory: dir,
            legacyFileURL: legacyURL,
            protection: MarkerArchiveProtection(box: SealMarkerBox(sealed: false))
        )
        let migrated = await store.migrateLegacyIfNeeded()
        XCTAssertNotNil(migrated, "legacy migration must still run while the marker is unset")
        XCTAssertEqual(migrated?.contextWindow, 4096)
    }

    // 6. Anti-laundering: marker set ⇒ refuse to adopt+reseal a plaintext index.
    func testSealedMarkerRefusesToLaunderPlaintextIndex() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try writePlaintextIndex([thread("forged plaintext").summary], to: dir)

        let store = ConversationArchiveTestSupport.makeStore(
            directory: dir,
            protection: MarkerArchiveProtection(box: SealMarkerBox(sealed: true))
        )
        let laundered = await store.reencryptPlaintextIndexIfNeeded()
        XCTAssertFalse(laundered, "a sealed archive must not launder a plaintext index into a sealed one")
        // And it remains plaintext (never re-sealed).
        let raw = try Data(contentsOf: dir.appendingPathComponent("index.v2.json"))
        XCTAssertFalse(ArchiveEnvelope.isEncrypted(raw), "the plaintext index must be left untouched, not adopted")
    }

    // 6b. Anti-laundering for threads: marker set ⇒ refuse to adopt+reseal plaintext threads.
    func testSealedMarkerRefusesToLaunderPlaintextThreads() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try writePlaintextThread(thread("forged thread"), to: dir)

        let store = ConversationArchiveTestSupport.makeStore(
            directory: dir,
            protection: MarkerArchiveProtection(box: SealMarkerBox(sealed: true))
        )
        let count = await store.reencryptPlaintextThreadsIfNeeded()
        XCTAssertEqual(count, 0, "a sealed archive must not launder plaintext threads")
    }

    // 7. No data loss across a genuine migration: marker unset, N plaintext threads + index.
    func testGenuineMigrationLosesNoData() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let n = 4
        var threads: [ConversationThread] = []
        for i in 0..<n {
            let t = thread("chat \(i)", updatedAt: Date(timeIntervalSinceNow: Double(i)))
            threads.append(t)
            try writePlaintextThread(t, to: dir)
        }
        try writePlaintextIndex(threads.map(\.summary), to: dir)

        // Each thread `save()` reseals both the thread file and the index; the trusted marker is set
        // by the LAST thread's save, once `isArchiveFullyEncrypted()` finally holds. The index-reseal
        // step is then a no-op here (the saves already sealed the index).
        let box = SealMarkerBox(sealed: false)
        let store = ConversationArchiveTestSupport.makeStore(
            directory: dir,
            protection: MarkerArchiveProtection(box: box)
        )

        // Mirror the orchestrator's launch order: threads then index.
        let resealed = await store.reencryptPlaintextThreadsIfNeeded()
        XCTAssertEqual(resealed, n, "every plaintext thread should be adopted and sealed")
        _ = await store.reencryptPlaintextIndexIfNeeded()
        XCTAssertEqual(box.value(), true, "marker is set once the whole archive is encrypted")

        // All summaries survive.
        let summaries = await store.summaries()
        XCTAssertEqual(summaries.count, n, "no summaries may be lost across migration")

        // Every thread loads back…
        for t in threads {
            let loaded = await store.load(id: t.id)
            XCTAssertNotNil(loaded, "thread \(t.id) must survive migration")
            // …and is now encrypted on disk.
            let raw = try Data(contentsOf: dir.appendingPathComponent("\(t.id.uuidString).json"))
            XCTAssertTrue(ArchiveEnvelope.isEncrypted(raw), "thread \(t.id) must be sealed after migration")
        }

        // The index is sealed too.
        let indexRaw = try Data(contentsOf: dir.appendingPathComponent("index.v2.json"))
        XCTAssertTrue(ArchiveEnvelope.isEncrypted(indexRaw), "the index must be sealed after migration")
    }

    // Seal a JSON-encodable payload with the shared test key, mirroring what the store writes.
    private func writeSealed<T: Encodable>(_ value: T, to url: URL) throws {
        let sealed = try FixedKeyArchiveProtection(key: ConversationArchiveTestSupport.sharedTestKey)
            .seal(try JSONEncoder().encode(value))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try sealed.write(to: url)
        XCTAssertTrue(ArchiveEnvelope.isEncrypted(try Data(contentsOf: url)), "precondition: sealed file")
    }

    // 8. Regression for the data-loss bug: while ANY plaintext thread remains, a save must NOT flip
    // the persistent marker — otherwise an interrupted migration strands the remaining plaintext.
    func testMarkerNotRecordedWhilePlaintextThreadRemains() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sealedThread = thread("already sealed")
        let plaintextThread = thread("still plaintext")
        let live = thread("new chat being saved")
        // Disk: a SEALED index, a SEALED thread, and a stranded PLAINTEXT thread.
        try writeSealed(ConversationArchiveIndex(version: 2, summaries: [sealedThread.summary]),
                        to: dir.appendingPathComponent("index.v2.json"))
        try writeSealed(sealedThread, to: dir.appendingPathComponent("\(sealedThread.id.uuidString).json"))
        try writePlaintextThread(plaintextThread, to: dir)

        let box = SealMarkerBox(sealed: false)
        let store = ConversationArchiveTestSupport.makeStore(
            directory: dir,
            protection: MarkerArchiveProtection(box: box)
        )

        // A normal save writes index→recordSealed→scan. The plaintext thread must keep the marker off.
        let saved = await store.save(live)
        XCTAssertTrue(saved.isSuccess)
        XCTAssertEqual(box.value(), false, "the marker must stay unset while a plaintext thread remains")

        // Once the plaintext thread is removed, a later write may flip the marker.
        try FileManager.default.removeItem(at: dir.appendingPathComponent("\(plaintextThread.id.uuidString).json"))
        let saved2 = await store.save(thread("another chat"))
        XCTAssertTrue(saved2.isSuccess)
        XCTAssertEqual(box.value(), true, "with no plaintext left, the save records the seal")
    }

    // 9. An interrupted thread migration recovers on the next run: marker still unset, plaintext
    // threads + index left on disk; reencrypt recovers everything rather than refusing it.
    func testInterruptedMigrationRecoversOnNextRun() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let b = thread("chat B")
        let c = thread("chat C")
        try writePlaintextThread(b, to: dir)
        try writePlaintextThread(c, to: dir)
        try writePlaintextIndex([b.summary, c.summary], to: dir)

        // Fresh store after a crash: the marker was never set (the fix kept it unset mid-loop).
        let box = SealMarkerBox(sealed: false)
        let store = ConversationArchiveTestSupport.makeStore(
            directory: dir,
            protection: MarkerArchiveProtection(box: box)
        )

        let resealed = await store.reencryptPlaintextThreadsIfNeeded()
        XCTAssertEqual(resealed, 2, "both stranded plaintext threads recover")
        _ = await store.reencryptPlaintextIndexIfNeeded()

        let loadedB = await store.load(id: b.id)
        let loadedC = await store.load(id: c.id)
        let summaryCount = await store.summaries().count
        XCTAssertNotNil(loadedB, "chat B must recover, not be refused")
        XCTAssertNotNil(loadedC, "chat C must recover, not be refused")
        XCTAssertEqual(summaryCount, 2, "no summaries lost")

        for id in [b.id, c.id] {
            let raw = try Data(contentsOf: dir.appendingPathComponent("\(id.uuidString).json"))
            XCTAssertTrue(ArchiveEnvelope.isEncrypted(raw), "thread sealed after recovery")
        }
        XCTAssertTrue(ArchiveEnvelope.isEncrypted(try Data(contentsOf: dir.appendingPathComponent("index.v2.json"))),
                      "index sealed after recovery")
        XCTAssertEqual(box.value(), true, "the marker is finally set once the archive is fully encrypted")
    }

    // 10. Realistic 6ee46ac shape: ENCRYPTED threads + a PLAINTEXT index. The index-reseal step is
    // the one that seals the index; the thread-reseal step finds nothing plaintext and is a no-op.
    func testPlaintextIndexWithEncryptedThreadsSealsViaIndexReseal() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let t = thread("sealed thread, plaintext index")
        try writeSealed(t, to: dir.appendingPathComponent("\(t.id.uuidString).json"))
        try writePlaintextIndex([t.summary], to: dir)

        let box = SealMarkerBox(sealed: false)
        let store = ConversationArchiveTestSupport.makeStore(
            directory: dir,
            protection: MarkerArchiveProtection(box: box)
        )

        let resealed = await store.reencryptPlaintextThreadsIfNeeded()
        XCTAssertEqual(resealed, 0, "no plaintext threads to reseal")
        XCTAssertEqual(box.value(), false, "marker stays unset: the plaintext index is still on disk")

        let sealedIndex = await store.reencryptPlaintextIndexIfNeeded()
        XCTAssertTrue(sealedIndex, "the index-reseal step seals the plaintext index")
        XCTAssertTrue(ArchiveEnvelope.isEncrypted(try Data(contentsOf: dir.appendingPathComponent("index.v2.json"))),
                      "index sealed after reseal")
        let loadedT = await store.load(id: t.id)
        XCTAssertNotNil(loadedT, "the thread is still readable, nothing lost")
        XCTAssertEqual(box.value(), true, "marker set once index is sealed and no plaintext remains")
    }
}
