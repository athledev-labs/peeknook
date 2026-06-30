// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Pure, clock-free leaf policy for the Whisper caption engine's "chunk on a pause" segmentation.
///
/// Whisper transcribes a finite audio array, not a live stream, so the device-glue transcriber
/// accumulates system-audio samples and asks this policy WHEN the accumulated buffer is a complete
/// utterance worth transcribing: after a short trailing silence (the natural end of a spoken line), or
/// when the buffer hits a hard ceiling so a long unbroken stretch still flushes. This is deliberately
/// simpler than the SFSpeech rolling-hypothesis model — one transcribe per utterance avoids the
/// cumulative-overlap drift that made the SFSpeech path degrade over time — and every threshold lives
/// here, unit-tested, rather than as a magic constant in an audio callback.
public enum WhisperUtterancePolicy: Sendable {
    /// Don't transcribe a buffer shorter than this: a sub-second blip is almost always a transient (a
    /// click, a key, a breath), not a line worth a Whisper pass.
    public static let minUtteranceSeconds: TimeInterval = 0.7

    /// Trailing silence that marks the end of a spoken line. Long enough not to cut mid-sentence on a
    /// natural breath, short enough that a finished line appears promptly.
    public static let silenceFinalizeSeconds: TimeInterval = 0.6

    /// Hard ceiling: flush even without a pause so continuous speech (a fast talker, overlapping
    /// dialogue) still produces lines instead of growing an unbounded buffer.
    public static let maxUtteranceSeconds: TimeInterval = 9.0

    /// Normalized 0...1 loudness at or above which the moment counts as speech (resets the silence
    /// clock). Above the meter's rest floor so room tone / faint hiss does not read as a voice.
    public static let voiceLevelThreshold: Float = 0.08

    public enum Decision: Sendable, Equatable {
        /// Keep accumulating; the utterance is not finished.
        case keepListening
        /// The buffer is a complete utterance — transcribe and clear it.
        case finalize
    }

    /// Whether a normalized loudness reading should count as speech (resetting the silence clock).
    public static func isVoice(level: Float) -> Bool {
        level >= voiceLevelThreshold
    }

    /// Decide whether the accumulated buffer is a finished utterance.
    /// - Parameters:
    ///   - hadSpeech: whether any voiced audio has landed since the last finalize (silence alone never
    ///     finalizes, so a quiet tap emits nothing).
    ///   - bufferSeconds: how much audio has accumulated.
    ///   - secondsSinceVoice: how long since the last voiced reading.
    public static func decide(
        hadSpeech: Bool,
        bufferSeconds: TimeInterval,
        secondsSinceVoice: TimeInterval
    ) -> Decision {
        guard hadSpeech, bufferSeconds >= minUtteranceSeconds else { return .keepListening }
        if secondsSinceVoice >= silenceFinalizeSeconds { return .finalize }
        if bufferSeconds >= maxUtteranceSeconds { return .finalize }
        return .keepListening
    }

    /// Normalize a raw Whisper transcript into a caption-worthy line, or `nil` to drop it.
    ///
    /// Whisper emits bracketed non-speech annotations on music/silence (`[BLANK_AUDIO]`, `(music)`,
    /// `[Applause]`, a bare `...`). Surfacing those as captions is the "randomly writes junk" failure in
    /// a different costume, so a transcript that is ENTIRELY such an annotation (or empty) is dropped;
    /// otherwise the trimmed text is returned. Pure and case/whitespace-insensitive so it's unit-tested
    /// apart from the model.
    public static func cleaned(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Strip a single matched bracket/paren wrapper and see if anything substantive remains.
        let stripped = strippedAnnotation(trimmed)
        guard !stripped.isEmpty else { return nil }
        // A line that is only punctuation/ellipsis (no letters or digits anywhere) carries no caption.
        guard stripped.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return trimmed
    }

    /// If `text` is wholly wrapped in `[...]` or `(...)` (a non-speech annotation), return its inside;
    /// otherwise return `text` unchanged. Only a fully-wrapped line is treated as an annotation, so a
    /// real caption that merely contains a parenthetical is preserved.
    private static func strippedAnnotation(_ text: String) -> String {
        guard let first = text.first, let last = text.last else { return text }
        if (first == "[" && last == "]") || (first == "(" && last == ")") {
            let inner = text.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
            // Only treat as an annotation if there's no further bracket inside (avoid eating real text).
            if !inner.contains("[") && !inner.contains("(") {
                let lowered = inner.lowercased()
                if Self.nonSpeechAnnotations.contains(lowered) || lowered.allSatisfy({ !$0.isLetter && !$0.isNumber }) {
                    return ""
                }
            }
        }
        return text
    }

    /// Common Whisper non-speech annotation contents (lowercased, sans wrapper).
    private static let nonSpeechAnnotations: Set<String> = [
        "blank_audio", "music", "applause", "laughter", "silence", "no speech", "inaudible"
    ]
}
