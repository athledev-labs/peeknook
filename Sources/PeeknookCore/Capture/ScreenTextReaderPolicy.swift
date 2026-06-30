// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Pure decision for whether a cheap accessibility read was good enough or the composite reader should
/// escalate to the heavier on-device OCR pass. Kept a leaf so the "when do we pay for a screenshot +
/// Vision" cost/quality trade-off is tunable by data and tested apart from either reader.
///
/// The accessibility tree is cheap and exact for text surfaces (articles, chat) but typically CANNOT see
/// rendered subtitles or canvas-drawn lyrics — the very case "watch a foreign show" lives in. So the
/// rule is conservative: trust accessibility only when it yielded a real caption-class candidate;
/// otherwise read pixels. OCR is the workhorse for media; accessibility is the cheap fast path when it
/// genuinely carries the caption.
public enum ScreenTextReaderPolicy: Sendable {
    /// An accessibility candidate at least this long counts as a real caption; shorter (or empty) means
    /// the subtitle is almost certainly rendered, not structural, so escalate to OCR.
    public static let minAccessibilityCaptionLength = 8

    /// Escalate to OCR when accessibility produced no usable caption-class candidate.
    public static func shouldEscalateToOCR(accessibilityCandidate: String?) -> Bool {
        let trimmed = (accessibilityCandidate ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count < minAccessibilityCaptionLength
    }
}
