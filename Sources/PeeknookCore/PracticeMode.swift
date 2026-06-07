// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Coaching mode routed into prompts and capture heuristics.
public enum PracticeMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case general
    case korean
    case explain
    case code
    case chessCoach

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .general: "General"
        case .korean: "Korean"
        case .explain: "Explain"
        case .code: "Code"
        case .chessCoach: "Chess"
        }
    }

    public var symbolName: String {
        switch self {
        case .general: "sparkles.rectangle.stack"
        case .korean: "character.book.closed"
        case .explain: "text.magnifyingglass"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .chessCoach: "checkerboard.rectangle"
        }
    }

    /// Modes exposed in product UI. Add modes here only when behavior is clearly distinct
    /// at scale (not per-language pills, General infers gloss/translate/etc. from the screen).
    public static let shipped: [PracticeMode] = [.general]
}
