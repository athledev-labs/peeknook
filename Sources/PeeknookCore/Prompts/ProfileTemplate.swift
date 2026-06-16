// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Sanitizer + fencer for the per-profile free-text prompt template — a SECOND shaping channel,
/// distinct from the standing ``ProfileInstruction``: where the instruction sets a persona, the
/// template lets a profile shape the system message further (format, ground rules, examples). Like
/// the instruction it is deliberately NOT a mode enum — profiles stay user-created free text, never a
/// curated mode list.
///
/// Safety: the template is sanitized (trim + cap) on decode and FENCED when folded into the system
/// prompt, so user-pasted text — even text that itself contains `## headings` — reads as the template
/// block's CONTENT and can never inject new top-level prompt sections or break the stable contract.
public enum ProfileTemplate {
    /// Hard cap: roomy enough for a real template (format + examples), short enough that a paste-bomb
    /// can't crowd the context window before the capture even lands.
    public static let maxLength = 4_000

    /// Trim + cap; nil when empty or whitespace-only (callers treat nil as "no template").
    public static func sanitized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxLength))
    }
}
