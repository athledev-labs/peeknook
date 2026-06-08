// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Multi-thread successor to ``ConversationStore``. Stores each chat as its own JSON file under
/// `Application Support/Peeknook/Conversations/<uuid>.json`, with a small `index.v2.json` listing
/// summaries for the switcher. Best-effort: every method tolerates failure (returns nil / no-op) so
/// a corrupt or missing file is just "no saved chat", never a crash or a data reset.
///
/// Persistence stays opt-in (`PeeknookSettings.persistConversation`); the orchestrator only calls
/// save/load/list when enabled, and `deleteAll` when the user opts out.
/// Serializes all archive I/O so a late save cannot resurrect a discarded thread.
public actor ConversationArchiveStore {
    public static let indexVersion = 2
    /// Cap thread count and total bytes, screenshots are large, so the archive prunes oldest first.
    public static let defaultMaxThreads = 25
    public static let defaultMaxBytes = 250 * 1024 * 1024

    private let directory: URL
    private let indexURL: URL
    /// Single-file `conversation.v1.json` written by the previous ``ConversationStore``; migrated once.
    private let legacyFileURL: URL?
    private let maxThreads: Int
    private let maxBytes: Int
    private let protection: any ConversationArchiveProtection
    /// Sticky cache of the trusted "archive sealed at least once" marker. Once true it never flips
    /// back, so a single sealed write permanently enables fail-closed downgrade resistance for this
    /// actor's lifetime, even if the keychain later becomes transiently unavailable.
    private var sealedMarkerCache: Bool?

    public init(
        directory: URL,
        legacyFileURL: URL? = nil,
        maxThreads: Int = ConversationArchiveStore.defaultMaxThreads,
        maxBytes: Int = ConversationArchiveStore.defaultMaxBytes,
        protection: any ConversationArchiveProtection
    ) {
        self.directory = directory
        self.indexURL = directory.appendingPathComponent("index.v2.json")
        self.legacyFileURL = legacyFileURL
        self.maxThreads = maxThreads
        self.maxBytes = maxBytes
        self.protection = protection
    }

    public static func makeDefault() throws -> ConversationArchiveStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let peeknook = base.appendingPathComponent("Peeknook", isDirectory: true)
        return ConversationArchiveStore(
            directory: peeknook.appendingPathComponent("Conversations", isDirectory: true),
            legacyFileURL: peeknook.appendingPathComponent("conversation.v1.json"),
            protection: try KeychainArchiveProtection()
        )
    }

    // MARK: - Read

    /// Summaries for the switcher, newest first. Cheap, only the index file is read.
    public func summaries() -> [ConversationSummary] {
        readIndex().summaries.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func load(id: UUID) -> ConversationThread? {
        guard let raw = try? Data(contentsOf: threadURL(id)) else { return nil }
        return decodeThread(from: raw)
    }

    /// Newest thread, used to resume the most recent chat at launch.
    public func mostRecent() -> ConversationThread? {
        guard let newest = summaries().first else { return nil }
        return load(id: newest.id)
    }

    // MARK: - Write

    public func save(_ thread: ConversationThread) -> Result<Void, ConversationArchiveError> {
        guard !thread.turns.isEmpty else { return .success(()) }

        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(thread)
        } catch {
            return .failure(.encodeFailed)
        }

        let data: Data
        do {
            data = try protection.seal(encoded)
        } catch ArchiveProtectionError.keyUnavailable {
            return .failure(.keyUnavailable)
        } catch {
            return .failure(.encodeFailed)
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failure(.directoryUnavailable)
        }

        var index = readIndex()
        index.summaries.removeAll { $0.id == thread.id }
        index.summaries.append(thread.summary(fileBytes: data.count))
        prune(&index)

        let priorIndex = readIndex()
        switch writeIndex(index) {
        case .success:
            break
        case .failure:
            return .failure(.indexWriteFailed)
        }

        do {
            try writeProtected(data, to: threadURL(thread.id))
        } catch {
            _ = writeIndex(priorIndex)
            return .failure(.threadWriteFailed)
        }
        recordSealed()
        return .success(())
    }

    public func delete(id: UUID) {
        try? FileManager.default.removeItem(at: threadURL(id))
        var index = readIndex()
        index.summaries.removeAll { $0.id == id }
        if case .success = writeIndex(index) {
            recordSealed()
        }
    }

    /// Wipe the whole archive, called when the user turns persistence off or taps Clear all.
    public func deleteAll() {
        try? FileManager.default.removeItem(at: directory)
        // Also drop any un-migrated legacy file so opting out truly leaves nothing behind.
        if let legacyFileURL { try? FileManager.default.removeItem(at: legacyFileURL) }
    }

    // MARK: - Migration

    /// One-time upgrade from the single-file `conversation.v1.json`. Runs only when no v2 index
    /// exists yet; wraps the saved chat as a thread, then removes the legacy file. Returns the
    /// migrated thread (so the caller can resume it) or nil when there was nothing to migrate.
    @discardableResult
    public func migrateLegacyIfNeeded() -> ConversationThread? {
        guard !FileManager.default.fileExists(atPath: indexURL.path) else { return nil }
        guard let legacyFileURL,
              let data = try? Data(contentsOf: legacyFileURL),
              let legacy = try? JSONDecoder().decode(PersistedConversation.self, from: data),
              !legacy.turns.isEmpty
        else { return nil }

        let mtime = (try? FileManager.default.attributesOfItem(atPath: legacyFileURL.path)[.modificationDate]) as? Date
            ?? Date()
        let thread = ConversationThread(
            createdAt: mtime,
            updatedAt: mtime,
            turns: legacy.turns,
            contextWindow: legacy.contextWindow,
            turnCounter: legacy.turnCounter,
            lastPromptTokens: legacy.lastPromptTokens
        )
        guard let encoded = try? JSONEncoder().encode(thread) else { return nil }
        let fileData: Data
        do {
            fileData = try protection.seal(encoded)
        } catch {
            return nil
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? writeProtected(fileData, to: threadURL(thread.id))
        writeIndex(ConversationArchiveIndex(version: Self.indexVersion, summaries: [thread.summary(fileBytes: fileData.count)]))
        try? FileManager.default.removeItem(at: legacyFileURL)
        return thread
    }

    /// Re-seal any legacy plaintext thread files. Returns how many were upgraded.
    @discardableResult
    public func reencryptPlaintextThreadsIfNeeded() -> Int {
        // Anti-laundering: once the archive is known sealed, never adopt+reseal plaintext threads, or
        // an attacker's forged plaintext would be laundered into a legitimately sealed file. During a
        // genuine pre-encryption migration the marker is still false, so adoption proceeds normally.
        if archiveIsSealed() { return 0 }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return 0 }

        var reencrypted = 0
        for file in files where file.lastPathComponent.hasSuffix(".json") && file.lastPathComponent != "index.v2.json" {
            guard let raw = try? Data(contentsOf: file),
                  !ArchiveEnvelope.isEncrypted(raw),
                  let thread = try? JSONDecoder().decode(ConversationThread.self, from: raw) else { continue }
            if case .success = save(thread) {
                reencrypted += 1
            }
        }
        return reencrypted
    }

    /// Re-seal a legacy plaintext `index.v2.json` (written before the index itself was encrypted), so
    /// the derived titles it holds stop sitting in cleartext on disk. Returns whether it upgraded the
    /// index. No-op once the index is already sealed.
    @discardableResult
    public func reencryptPlaintextIndexIfNeeded() -> Bool {
        // Anti-laundering: refuse to adopt+reseal a plaintext index once the archive is known sealed,
        // so a downgraded/forged plaintext index can't be laundered into a sealed one. The marker is
        // still false during a genuine pre-encryption migration, so that path is unaffected.
        if archiveIsSealed() { return false }
        guard let raw = try? Data(contentsOf: indexURL),
              !ArchiveEnvelope.isEncrypted(raw),
              let index = try? JSONDecoder().decode(ConversationArchiveIndex.self, from: raw)
        else { return false }
        if case .success = writeIndex(index) {
            recordSealed()
            return true
        }
        return false
    }

    // MARK: - Internals

    private func threadURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    /// Whether the archive is *known* to have been sealed at least once (fail-closed gate).
    /// Returns true only when the trusted keychain marker says so (cached sticky). When the marker
    /// store is unavailable (nil), this returns false — fail-soft, so plaintext is accepted rather
    /// than risking History data loss during a transient keychain outage.
    private func archiveIsSealed() -> Bool {
        if sealedMarkerCache == true { return true }
        switch protection.archiveHasBeenSealed() {
        case .some(true):
            sealedMarkerCache = true
            return true
        case .some(false):
            return false
        case .none:
            return false // unavailable: fail soft, do NOT cache so a later check can still succeed
        }
    }

    /// Record (best-effort) that the archive is now sealed, flipping the gate on. Self-defers until
    /// the archive is fully encrypted on disk, so an interrupted migration (which seals threads one
    /// at a time) never sets the marker while plaintext threads still remain — otherwise the next
    /// launch would refuse those stranded legitimate threads (silent data loss).
    private func recordSealed() {
        if sealedMarkerCache == true { return }
        guard isArchiveFullyEncrypted() else { return }
        protection.markArchiveSealed()
        sealedMarkerCache = true
    }

    /// True iff there is NO plaintext index AND NO plaintext thread file on disk. Reads only each
    /// file's prefix (the envelope magic) via a `FileHandle`, never the multi-MB screenshot payloads.
    /// A missing/unreadable index or empty directory counts as "no plaintext" (true).
    private func isArchiveFullyEncrypted() -> Bool {
        if fileExistsAndIsPlaintext(indexURL) { return false }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return true }
        for file in files where file.lastPathComponent.hasSuffix(".json") && file.lastPathComponent != "index.v2.json" {
            if fileExistsAndIsPlaintext(file) { return false }
        }
        return true
    }

    /// Whether `url` exists and its leading bytes are NOT the encrypted-envelope magic. Reads only a
    /// small prefix so it stays cheap regardless of file size. Unreadable/missing files count as not
    /// plaintext (so a transient read error can't strand the marker forever).
    private func fileExistsAndIsPlaintext(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        // Read a few bytes past the envelope magic so `isEncrypted` (which requires count > magic+1)
        // can still recognize a sealed file from its prefix alone.
        let prefix = (try? handle.read(upToCount: 16)) ?? Data()
        guard !prefix.isEmpty else { return false }
        return !ArchiveEnvelope.isEncrypted(prefix)
    }

    /// Decrypt when protected, or decode legacy plaintext threads.
    private func decodeThread(from raw: Data) -> ConversationThread? {
        if ArchiveEnvelope.isEncrypted(raw) {
            guard let plaintext = try? protection.open(raw) else { return nil }
            return try? JSONDecoder().decode(ConversationThread.self, from: plaintext)
        }
        // Fail-closed: once the archive is known sealed, a plaintext thread can only be tampering or
        // corruption (every legitimate thread was sealed before the marker flipped on). Refuse it.
        if archiveIsSealed() { return nil }
        if let thread = try? JSONDecoder().decode(ConversationThread.self, from: raw) {
            return thread
        }
        return nil
    }

    private func readIndex() -> ConversationArchiveIndex {
        let empty = ConversationArchiveIndex(version: Self.indexVersion, summaries: [])
        guard let raw = try? Data(contentsOf: indexURL) else { return empty }
        // The index holds derived titles (excerpts of the user's questions/answers), so it's sealed
        // like the thread files. Fail-closed downgrade resistance is NOW implemented (the same trusted
        // "already sealed" marker gates index *and* threads): once `archiveIsSealed()` is true, a
        // plaintext index is refused below. Plaintext is still accepted while the marker is false or
        // unavailable, deliberately: a pre-encryption archive not yet migrated (re-sealed at launch by
        // `reencryptPlaintextIndexIfNeeded`), or a launch where the keychain (key or marker) was
        // transiently unavailable — fail-soft there preserves migration and avoids History data loss.
        let json: Data
        if ArchiveEnvelope.isEncrypted(raw) {
            guard let opened = try? protection.open(raw) else { return empty }
            json = opened
        } else {
            // Refuse a downgraded plaintext index once the archive is known sealed (see invariant in
            // `writeIndex`): by then no legitimate plaintext index can remain, so this is tampering.
            if archiveIsSealed() { return empty }
            json = raw
        }
        return (try? JSONDecoder().decode(ConversationArchiveIndex.self, from: json)) ?? empty
    }

    private func writeIndex(_ index: ConversationArchiveIndex) -> Result<Void, ConversationArchiveError> {
        let json: Data
        do {
            json = try JSONEncoder().encode(index)
        } catch {
            return .failure(.encodeFailed)
        }

        let data: Data
        do {
            data = try protection.seal(json)
        } catch ArchiveProtectionError.keyUnavailable {
            return .failure(.keyUnavailable)
        } catch {
            return .failure(.encodeFailed)
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failure(.directoryUnavailable)
        }

        do {
            try writeProtected(data, to: indexURL)
        } catch {
            return .failure(.indexWriteFailed)
        }

        return .success(())
    }

    private func writeProtected(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    /// Drop oldest threads (by `updatedAt`) until under both the count and byte caps.
    private func prune(_ index: inout ConversationArchiveIndex) {
        index.summaries.sort { $0.updatedAt > $1.updatedAt }

        while index.summaries.count > maxThreads, let oldest = index.summaries.last {
            try? FileManager.default.removeItem(at: threadURL(oldest.id))
            index.summaries.removeLast()
        }

        var totalBytes = index.summaries.reduce(0) { running, summary in
            running + (summary.fileBytes ?? fileSize(for: summary.id))
        }
        while totalBytes > maxBytes, index.summaries.count > 1, let oldest = index.summaries.last {
            let removed = oldest.fileBytes ?? fileSize(for: oldest.id)
            try? FileManager.default.removeItem(at: threadURL(oldest.id))
            index.summaries.removeLast()
            totalBytes -= removed
        }
    }

    private func fileSize(for id: UUID) -> Int {
        let path = threadURL(id).path
        return (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
    }
}
