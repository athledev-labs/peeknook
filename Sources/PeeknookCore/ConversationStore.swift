// SPDX-License-Identifier: Apache-2.0

import Foundation

/// On-disk snapshot of a chat so an opted-in user can resume it after quitting. Screenshots ride
/// along in `turns` (base64), so this lives as a JSON file in Application Support, not UserDefaults.
public struct PersistedConversation: Codable, Sendable {
    public var version: Int
    public var turns: [ChatTurn]
    public var contextWindow: Int?
    public var turnCounter: Int
    public var lastPromptTokens: Int?

    public init(
        version: Int = 1,
        turns: [ChatTurn],
        contextWindow: Int?,
        turnCounter: Int,
        lastPromptTokens: Int?
    ) {
        self.version = version
        self.turns = turns
        self.contextWindow = contextWindow
        self.turnCounter = turnCounter
        self.lastPromptTokens = lastPromptTokens
    }
}

/// Best-effort local persistence for the active chat. All methods tolerate failure (return nil /
/// no-op), a corrupt or missing file just means "no saved chat", never a crash or data reset.
/// Persistence is opt-in (`PeeknookSettings.persistConversation`); the orchestrator only calls
/// `save`/`load` when the user has enabled it, and `clear` whenever a thread is discarded.
public final class ConversationStore: Sendable {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/Peeknook/conversation.v1.json` (temp dir as a last resort).
    public static func makeDefault() -> ConversationStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = base
            .appendingPathComponent("Peeknook", isDirectory: true)
            .appendingPathComponent("conversation.v1.json")
        return ConversationStore(fileURL: url)
    }

    public func load() -> PersistedConversation? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(PersistedConversation.self, from: data)
    }

    public func save(_ conversation: PersistedConversation) {
        guard let data = try? JSONEncoder().encode(conversation) else { return }
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
