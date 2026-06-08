// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One archived chat: a stable identity, lifecycle timestamps, and the full turn list (screenshots
/// included, base64). The on-disk unit of the conversation archive, one JSON file per thread so the
/// list view never has to parse every screenshot just to show a row.
public struct ConversationThread: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var turns: [ChatTurn]
    public var contextWindow: Int?
    public var turnCounter: Int
    public var lastPromptTokens: Int?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        turns: [ChatTurn],
        contextWindow: Int? = nil,
        turnCounter: Int = 0,
        lastPromptTokens: Int? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.turns = turns
        self.contextWindow = contextWindow
        self.turnCounter = turnCounter
        self.lastPromptTokens = lastPromptTokens
    }

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, updatedAt, turns, contextWindow, turnCounter, lastPromptTokens
    }

    // Tolerant decode so adding a field later never invalidates a saved thread.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? self.createdAt
        self.turns = try c.decodeIfPresent([ChatTurn].self, forKey: .turns) ?? []
        self.contextWindow = try c.decodeIfPresent(Int.self, forKey: .contextWindow)
        self.turnCounter = try c.decodeIfPresent(Int.self, forKey: .turnCounter) ?? 0
        self.lastPromptTokens = try c.decodeIfPresent(Int.self, forKey: .lastPromptTokens)
    }

    /// Human label for the switcher, first question, else first answer, else the capture target.
    public var title: String {
        ConversationThread.derivedTitle(from: turns)
    }

    public var hasImage: Bool {
        turns.contains { if case .image = $0.kind { return true } else { return false } }
    }

    /// Lightweight row used by the list/switcher (no screenshots) so listing stays cheap.
    public var summary: ConversationSummary {
        ConversationSummary(
            id: id,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            turnCount: turns.count,
            hasImage: hasImage
        )
    }

    public static func derivedTitle(from turns: [ChatTurn]) -> String {
        for turn in turns {
            if case .user(let text) = turn.kind {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return condense(trimmed) }
            }
        }
        for turn in turns {
            if case .assistant(let text) = turn.kind {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return condense(trimmed) }
            }
        }
        for turn in turns {
            if case .image(let capture) = turn.kind {
                let label = capture.targetLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                if !label.isEmpty { return condense(label) }
            }
        }
        return "Conversation"
    }

    private static func condense(_ text: String) -> String {
        let oneLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard oneLine.count > 48 else { return oneLine }
        return String(oneLine.prefix(48)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// Lightweight, screenshot-free descriptor for the archive list/switcher. Persisted in the index so
/// the History list loads instantly without decoding every thread's base64 image payloads.
public struct ConversationSummary: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var turnCount: Int
    public var hasImage: Bool

    public init(
        id: UUID,
        title: String,
        createdAt: Date,
        updatedAt: Date,
        turnCount: Int,
        hasImage: Bool
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.turnCount = turnCount
        self.hasImage = hasImage
    }
}

/// Structured failure from archive writes so callers can surface persistence issues instead of
/// silently dropping saves.
public enum ConversationArchiveError: Error, Sendable, Equatable {
    case encodeFailed
    case directoryUnavailable
    case threadWriteFailed
    case indexWriteFailed
    case decryptFailed
    case keyUnavailable

    public var userFacingMessage: String {
        switch self {
        case .encodeFailed:
            return "Couldn't encode your conversation for saving."
        case .directoryUnavailable:
            return "Couldn't access the conversation storage folder."
        case .threadWriteFailed:
            return "Couldn't write your conversation to disk."
        case .indexWriteFailed:
            return "Couldn't update the conversation history index."
        case .decryptFailed:
            return "Couldn't read a saved conversation. It may be corrupted."
        case .keyUnavailable:
            return "Couldn't access the encryption key for saved conversations."
        }
    }
}

/// On-disk index of the archive, a list of ``ConversationSummary`` so the switcher avoids parsing
/// every thread file. Versioned to gate the one-time legacy migration.
struct ConversationArchiveIndex: Codable, Sendable {
    var version: Int
    var summaries: [ConversationSummary]
}

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
    private let protection: (any ConversationArchiveProtection)?

    public init(
        directory: URL,
        legacyFileURL: URL? = nil,
        maxThreads: Int = ConversationArchiveStore.defaultMaxThreads,
        maxBytes: Int = ConversationArchiveStore.defaultMaxBytes,
        protection: (any ConversationArchiveProtection)? = nil
    ) {
        self.directory = directory
        self.indexURL = directory.appendingPathComponent("index.v2.json")
        self.legacyFileURL = legacyFileURL
        self.maxThreads = maxThreads
        self.maxBytes = maxBytes
        self.protection = protection
    }

    public static func makeDefault() -> ConversationArchiveStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let peeknook = base.appendingPathComponent("Peeknook", isDirectory: true)
        return ConversationArchiveStore(
            directory: peeknook.appendingPathComponent("Conversations", isDirectory: true),
            legacyFileURL: peeknook.appendingPathComponent("conversation.v1.json"),
            protection: KeychainArchiveProtection.makeDefault()
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
        if let protection {
            do {
                data = try protection.seal(encoded)
            } catch ArchiveProtectionError.keyUnavailable {
                return .failure(.keyUnavailable)
            } catch {
                return .failure(.encodeFailed)
            }
        } else {
            data = encoded
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failure(.directoryUnavailable)
        }

        do {
            try data.write(to: threadURL(thread.id), options: .atomic)
        } catch {
            return .failure(.threadWriteFailed)
        }

        var index = readIndex()
        index.summaries.removeAll { $0.id == thread.id }
        index.summaries.append(thread.summary)
        prune(&index)
        switch writeIndex(index) {
        case .success:
            return .success(())
        case .failure:
            return .failure(.indexWriteFailed)
        }
    }

    public func delete(id: UUID) {
        try? FileManager.default.removeItem(at: threadURL(id))
        var index = readIndex()
        index.summaries.removeAll { $0.id == id }
        writeIndex(index)
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
        if let protection, let sealed = try? protection.seal(encoded) {
            fileData = sealed
        } else {
            fileData = encoded
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fileData.write(to: threadURL(thread.id), options: .atomic)
        writeIndex(ConversationArchiveIndex(version: Self.indexVersion, summaries: [thread.summary]))
        try? FileManager.default.removeItem(at: legacyFileURL)
        return thread
    }

    // MARK: - Internals

    private func threadURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    /// Decrypt when protected, or decode legacy plaintext threads.
    private func decodeThread(from raw: Data) -> ConversationThread? {
        if let protection, ArchiveEnvelope.isEncrypted(raw) {
            guard let plaintext = try? protection.open(raw) else { return nil }
            return try? JSONDecoder().decode(ConversationThread.self, from: plaintext)
        }
        if let thread = try? JSONDecoder().decode(ConversationThread.self, from: raw) {
            return thread
        }
        return nil
    }

    private func readIndex() -> ConversationArchiveIndex {
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode(ConversationArchiveIndex.self, from: data)
        else { return ConversationArchiveIndex(version: Self.indexVersion, summaries: []) }
        return index
    }

    private func writeIndex(_ index: ConversationArchiveIndex) -> Result<Void, ConversationArchiveError> {
        let data: Data
        do {
            data = try JSONEncoder().encode(index)
        } catch {
            return .failure(.encodeFailed)
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failure(.directoryUnavailable)
        }

        do {
            try data.write(to: indexURL, options: .atomic)
        } catch {
            return .failure(.indexWriteFailed)
        }

        return .success(())
    }

    /// Drop oldest threads (by `updatedAt`) until under both the count and byte caps.
    private func prune(_ index: inout ConversationArchiveIndex) {
        index.summaries.sort { $0.updatedAt > $1.updatedAt }

        while index.summaries.count > maxThreads, let oldest = index.summaries.last {
            try? FileManager.default.removeItem(at: threadURL(oldest.id))
            index.summaries.removeLast()
        }

        while totalBytes(of: index.summaries) > maxBytes, index.summaries.count > 1,
              let oldest = index.summaries.last {
            try? FileManager.default.removeItem(at: threadURL(oldest.id))
            index.summaries.removeLast()
        }
    }

    private func totalBytes(of summaries: [ConversationSummary]) -> Int {
        summaries.reduce(0) { running, summary in
            let size = (try? FileManager.default.attributesOfItem(atPath: threadURL(summary.id).path)[.size]) as? Int
            return running + (size ?? 0)
        }
    }
}
