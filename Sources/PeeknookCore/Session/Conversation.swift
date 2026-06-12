// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One rendered turn in the notch conversation.
///
/// A chat is a sequence of these: an `.image` turn marks a screenshot the user captured (the
/// first one, plus any added mid-chat), `.user` is a typed/pill follow-up, `.assistant` is an
/// answer. Modeling images as their own turn is what lets a single chat span several screenshots.
public struct ChatTurn: Identifiable, Equatable, Sendable, Codable {
    public enum Kind: Equatable, Sendable, Codable {
        case image(CaptureResult)
        case user(String)
        case assistant(String)
    }

    public let id: Int
    public var kind: Kind
    /// Telemetry for this turn's inference (assistant answers). `promptTokens` is the full
    /// prompt Ollama evaluated, the whole thread so far, not an isolated message slice.
    public var turnUsage: TurnUsage?
    /// Non-nil when this `.image` turn is one leg of a composite question (screen + camera asked as
    /// one turn). Two `.image` turns sharing this id are the legs, ordered screen-then-camera by
    /// `id`. Additive `Optional` → synthesized Codable decode-if-present/encode-if-present: legacy
    /// turns and old readers see `nil` and treat each leg as a standalone image — never throws,
    /// never writes a key for non-composite turns (so the archive stays byte-identical by default).
    public var compositeGroupID: UUID?
    /// The typed question this `.image` turn was promoted with (a live "Answer now" / "Update & ask"
    /// with composer text, or a follow-up that consumed a pending live frame). Folded into the image's
    /// single grounded user message so the screenshot and the question ride together — never as a
    /// second adjacent `.user` message. Same additive Optional discipline as ``compositeGroupID``:
    /// `nil` writes no key (archive byte-identical for every non-promoted turn) and legacy turns decode
    /// `nil`.
    public var question: String?

    public init(
        id: Int,
        kind: Kind,
        turnUsage: TurnUsage? = nil,
        compositeGroupID: UUID? = nil,
        question: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.turnUsage = turnUsage
        self.compositeGroupID = compositeGroupID
        self.question = question
    }

    public var isAssistant: Bool {
        if case .assistant = kind { return true }
        return false
    }

    public var isImage: Bool {
        if case .image = kind { return true }
        return false
    }
}

/// Per-turn inference footprint shown in History (and the thread usage chart).
public struct TurnUsage: Equatable, Sendable, Codable {
    public var promptTokens: Int
    public var responseTokens: Int
    public var generationSeconds: Double
    public var contextWindow: Int?
    /// Separate schema-constrained pass that proposes action pills (best-effort).
    public var suggestionPass: InferenceStats?

    public init(
        promptTokens: Int,
        responseTokens: Int,
        generationSeconds: Double,
        contextWindow: Int? = nil,
        suggestionPass: InferenceStats? = nil
    ) {
        self.promptTokens = promptTokens
        self.responseTokens = responseTokens
        self.generationSeconds = generationSeconds
        self.contextWindow = contextWindow
        self.suggestionPass = suggestionPass
    }

    public init(stats: InferenceStats, contextWindow: Int?, suggestionPass: InferenceStats? = nil) {
        self.init(
            promptTokens: stats.promptTokens,
            responseTokens: stats.responseTokens,
            generationSeconds: stats.generationSeconds,
            contextWindow: contextWindow,
            suggestionPass: suggestionPass
        )
    }

    /// Share of the model context window consumed by the prompt on this turn.
    public var contextFraction: Double? {
        guard let contextWindow, contextWindow > 0, promptTokens > 0 else { return nil }
        return min(1, Double(promptTokens) / Double(contextWindow))
    }

    /// Extra prompt tokens vs the previous assistant answer in this chat (0 for the first).
    public func promptDelta(sincePreviousPrompt previous: Int) -> Int {
        max(0, promptTokens - previous)
    }
}

/// Result of the non-streaming suggestion pass.
public struct FollowUpGenerationResult: Sendable, Equatable {
    public var suggestions: [String]
    public var stats: InferenceStats?

    public init(suggestions: [String], stats: InferenceStats? = nil) {
        self.suggestions = suggestions
        self.stats = stats
    }
}

/// Builds per-answer usage points for History charts and breakdowns.
public enum TurnUsageTimeline {
    public struct Point: Identifiable, Equatable, Sendable {
        public let id: Int
        public let label: String
        public let usage: TurnUsage
        public let promptDelta: Int
        public let fraction: Double

        public var turnID: Int { id }
    }

    public static func points(from conversation: [ChatTurn]) -> [Point] {
        var previousPrompt = 0
        var index = 0
        var result: [Point] = []
        let peakPrompt = conversation.compactMap { turn -> Int? in
            guard turn.isAssistant else { return nil }
            return turn.turnUsage?.promptTokens
        }.max() ?? 0

        for turn in conversation where turn.isAssistant {
            guard let usage = turn.turnUsage, usage.promptTokens > 0 else { continue }
            index += 1
            let delta = previousPrompt == 0 ? 0 : usage.promptDelta(sincePreviousPrompt: previousPrompt)
            previousPrompt = usage.promptTokens
            let fraction: Double
            if let window = usage.contextWindow, window > 0 {
                fraction = min(1, Double(usage.promptTokens) / Double(window))
            } else if peakPrompt > 0 {
                fraction = Double(usage.promptTokens) / Double(peakPrompt)
            } else {
                fraction = 0.3
            }
            result.append(
                Point(
                    id: turn.id,
                    label: "A\(index)",
                    usage: usage,
                    promptDelta: delta,
                    fraction: fraction
                )
            )
        }
        return result
    }

    public static func previousPromptTokens(before turnID: Int, in conversation: [ChatTurn]) -> Int {
        var last = 0
        for turn in conversation where turn.isAssistant {
            if turn.id == turnID { break }
            last = turn.turnUsage?.promptTokens ?? last
        }
        return last
    }
}

/// A turn replayed to the model. The captured image rides on the user message that introduced it
/// (Ollama keeps it in context afterward), so several `.user` messages in one request can each
/// carry their own screenshot.
public struct InferenceMessage: Sendable, Equatable {
    public enum Role: String, Sendable, Equatable {
        case user
        case assistant
    }

    public var role: Role
    public var text: String
    /// The image payload(s) this message carries. Usually 0 or 1; a composite question (screen +
    /// camera) rides as a single user message with two images, ordered screen-then-camera. In-memory
    /// only (``InferenceMessage`` is not Codable), so widening this never touched the archive.
    public var imagesBase64: [String]

    public init(role: Role, text: String, imagesBase64: [String] = []) {
        self.role = role
        self.text = text
        self.imagesBase64 = imagesBase64
    }

    /// Back-compat single-image init for the many call sites that carry at most one screenshot.
    public init(role: Role, text: String, imageBase64: String?) {
        self.init(role: role, text: text, imagesBase64: imageBase64.map { [$0] } ?? [])
    }
}
