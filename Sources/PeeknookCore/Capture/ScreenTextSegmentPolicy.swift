// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Pure, clock-free decision for when an on-screen caption candidate has settled into a NEW stable
/// segment worth translating. The temporal sibling of ``OnScreenLineExtractor`` (which picks the
/// candidate spatially) and the screen-side analogue of ``CaptionSegmentPolicy`` — but for text that
/// REPLACES rather than grows: a subtitle appears whole, lingers, then is swapped for the next one, and
/// OCR jitters a little while it is on screen. So the rule is "changed from what we last emitted, and
/// visually stable for ``stabilityWindow``", not "the recognizer paused".
///
/// All timing is injected, so the cadence is unit-testable apart from the device-only read. The caller
/// owns the state (`lastEmitted` = the last line it finalized; the seconds the current candidate has
/// held), exactly like ``CaptionSegmentSlicer``'s caller owns the committed prefix.
public enum ScreenTextSegmentPolicy: Sendable {
    public enum Decision: Equatable, Sendable {
        case wait
        case finalize
    }

    /// How long a candidate must hold UNCHANGED before it finalizes — long enough to ride out OCR flicker
    /// and the cross-fade as one subtitle replaces another, short enough to stay live. A growing line
    /// (live auto-captions that extend word by word) keeps resetting this, so only the completed line
    /// finalizes — the partial prefixes never do.
    public static let stabilityWindow: TimeInterval = 0.6
    /// Minimum candidate length to finalize — guards against a stray character becoming a segment.
    public static let minCharacters = 2

    /// Finalize `candidate` as the next stable segment when it carries enough text, differs from
    /// `lastEmitted` (so a still-displayed subtitle is not re-translated), and has held unchanged for
    /// ``stabilityWindow``. Otherwise wait.
    public static func decide(
        candidate: String,
        lastEmitted: String,
        secondsSinceCandidateChanged: TimeInterval
    ) -> Decision {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minCharacters else { return .wait }
        guard normalized(trimmed) != normalized(lastEmitted) else { return .wait }
        guard secondsSinceCandidateChanged >= stabilityWindow else { return .wait }
        return .finalize
    }

    /// Whether two candidates are the SAME line for change detection: case- and whitespace-insensitive,
    /// so trivial OCR re-spacing or capitalization wobble doesn't read as a new subtitle.
    public static func isSameLine(_ lhs: String, _ rhs: String) -> Bool {
        normalized(lhs) == normalized(rhs)
    }

    /// Collapse case and runs of whitespace for stable comparison.
    static func normalized(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }
}
