// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Canonical tag identity for model matching and deduplication across backends.
public enum ModelTag: Sendable {
    /// Canonical form of a model tag: trimmed, with an implied `:latest` when no tag is given.
    /// Bare "gemma4" → "gemma4:latest". Used for tag-aware matching and dedupe.
    public static func normalized(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed.contains(":") ? trimmed : "\(trimmed):latest"
    }

    /// Tag-aware match. Distinct tags are distinct models — `gemma4:e2b` must NOT satisfy
    /// a request for `gemma4:e4b`.
    public static func matches(installedNames: [String], wanted: String) -> Bool {
        let target = normalized(wanted)
        guard !target.isEmpty else { return false }
        return installedNames.contains { normalized($0) == target }
    }

    public static func isSame(_ lhs: String, _ rhs: String) -> Bool {
        matches(installedNames: [lhs], wanted: rhs)
    }
}
