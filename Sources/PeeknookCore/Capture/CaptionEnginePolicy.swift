// SPDX-License-Identifier: Apache-2.0

import Foundation

/// How an armed caption tap should produce its line — computed ONCE at arm by the pure
/// ``CaptionEnginePolicy`` from the profile's source/target languages, then handed to the
/// ``StreamingTranscribing`` engine AND read back by the caption coordinator. Carrying both facts in one
/// value is deliberate: the same plan that tells the engine to translate also tells the coordinator to
/// skip the separate LLM translation pass, so the two can never disagree about whether a second pass runs.
public struct CaptionTranscriptionPlan: Sendable, Equatable {
    public enum Mode: Sendable, Equatable {
        /// Emit verbatim source-language text; the coordinator runs a separate LLM pass to localize it.
        case transcribe
        /// Translate audio to English in the SAME pass (the on-device ASR's built-in translate task),
        /// auto-detecting the spoken language. No separate LLM pass — the engine already emits the target.
        case translateToEnglish
    }

    public let mode: Mode
    /// Source-language hint for `.transcribe` (and for engines that cannot auto-detect).
    /// `.translateToEnglish` auto-detects the spoken language and ignores this.
    public let sourceLocale: Locale

    public init(mode: Mode, sourceLocale: Locale) {
        self.mode = mode
        self.sourceLocale = sourceLocale
    }

    /// True when the ENGINE itself emits the caption's target language, so the coordinator must NOT run a
    /// second translation pass — doing so would re-translate already-target text and re-introduce the
    /// per-line latency the single-pass route exists to remove.
    public var producesTargetLanguage: Bool { mode == .translateToEnglish }
}

/// Pure, clock-free leaf policy that picks the caption transcription ``CaptionTranscriptionPlan/Mode`` from
/// the requested translation target.
///
/// The on-device ASR (Whisper) has a built-in translate task that outputs ENGLISH in one pass. When the
/// caption's target language is English we route to it: one model pass instead of transcribe-then-LLM, and
/// the engine auto-detects the spoken language — so a foreign show no longer needs a correct source-language
/// hint, which the surface cannot reliably supply (an unset source falls back to the device locale today).
/// Any other target keeps the transcribe-then-translate route.
///
/// NOTE on ``TranslationDirective`` being "data, not a mode": this is the ONE place the target's VALUE is
/// inspected, and it is a capability-routing decision (does the requested target match what the engine can
/// emit directly?), not a resurrected per-language product mode — there is no pill, no UI branch, and the
/// transcribe route stays value-agnostic exactly as before. Isolated here and unit-tested so the inspection
/// never leaks into the prompt path or a call site.
public enum CaptionEnginePolicy: Sendable {
    /// Decide the transcription plan for a caption's translation `target` and resolved `sourceLocale`.
    public static func plan(target: TranslationDirective, sourceLocale: Locale) -> CaptionTranscriptionPlan {
        let mode: CaptionTranscriptionPlan.Mode =
            targetsBuiltInTranslation(target.targetLanguage) ? .translateToEnglish : .transcribe
        return CaptionTranscriptionPlan(mode: mode, sourceLocale: sourceLocale)
    }

    /// Whether `targetLanguage` names English — the only target the on-device engine can produce in a single
    /// translate pass. Case- and whitespace-insensitive; matches the common English labels a user would type.
    public static func targetsBuiltInTranslation(_ targetLanguage: String) -> Bool {
        let normalized = targetLanguage
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return englishLabels.contains(normalized)
    }

    /// Common spellings/codes for English. A short explicit set rather than a fuzzy contains-match, so a
    /// target like "Englishman" or "Pidgin English" does not accidentally take the English-only route.
    private static let englishLabels: Set<String> = [
        "english", "en", "eng", "en-us", "en_us", "en-gb", "en_gb", "english (us)", "english (uk)"
    ]
}
