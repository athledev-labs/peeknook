// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Sanitizer for the per-profile free-text instruction (the user-written persona that injects into
/// the system prompt via `InferenceRequest.agentSystemAppendix`). Deliberately NOT a mode enum —
/// profiles stay user-created free text, never a curated mode list.
public enum ProfileInstruction {
    /// Hard cap: long enough for a rich persona, short enough that a paste-bomb can't crowd the
    /// context window before the capture even lands.
    public static let maxLength = 2_000

    /// Trim + cap; nil when empty or whitespace-only (callers treat nil as "no instruction").
    public static func sanitized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxLength))
    }
}
