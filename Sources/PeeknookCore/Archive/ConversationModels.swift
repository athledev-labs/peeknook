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
