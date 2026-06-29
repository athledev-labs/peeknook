// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Pure, clock-free slicing of a recognizer's GROWING cumulative transcript into the not-yet-finalized
/// tail. `SFSpeechRecognizer` reports `bestTranscription.formattedString` as the whole hypothesis-so-far
/// for the current session, so to emit more than one stable segment per session (the common case — one
/// recognizer session spans up to the ~60s rollover ceiling) the adapter must extract the DELTA since
/// the last finalized point. That extraction is the one place dropped or duplicated words hide, so it
/// lives here as a deterministically unit-testable leaf — the speech analogue of ``CaptionSegmentPolicy``
/// (which decides WHEN to finalize) — not as inline string math in the device tap.
///
/// The adapter owns the state (`committedPrefix` = what it has already emitted as stable for the current
/// session) and feeds it back in; this policy stays stateless like its siblings
/// ``CaptionSegmentPolicy`` / ``RecognizerRolloverPolicy``.
public enum CaptionSegmentSlicer: Sendable {
    /// The text the recognizer has added since `committedPrefix` was finalized — what a `.finalize`
    /// decision should emit as the next stable segment, and what a `.wait` shows as the "hearing…" cue.
    ///
    /// Whitespace-tolerant. When `committedPrefix` is no longer a prefix of `cumulative` (the recognizer
    /// REVISED a word we already committed — rare, since we only commit a tail that has gone quiet, and a
    /// rollover's true `isFinal` re-states the session cleanly), it falls back to the whole cumulative so
    /// revised words are re-surfaced rather than silently dropped. The consumer dedupes by `sequence`, so
    /// a re-surfaced tail corrects the line; it never deletes one.
    public static func pending(cumulative: String, committedPrefix: String) -> String {
        let full = cumulative.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = committedPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { return full }
        guard full.hasPrefix(prefix) else { return full }   // revision fallback: never drop words
        return String(full.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
