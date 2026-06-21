// SPDX-License-Identifier: Apache-2.0

import Foundation

#if canImport(AVFoundation)
import AVFoundation
#endif

/// A selectable on-device TTS voice. Empty ``identifier`` means the system default for the locale.
public struct SpeechVoiceOption: Identifiable, Equatable, Sendable, Codable {
    public var identifier: String
    public var displayName: String
    /// Human-readable quality hint, e.g. "Enhanced" for neural voices when available.
    public var qualityLabel: String?

    public var id: String { identifier }

    public init(identifier: String, displayName: String, qualityLabel: String? = nil) {
        self.identifier = identifier
        self.displayName = displayName
        self.qualityLabel = qualityLabel
    }

    public var menuLabel: String {
        guard let qualityLabel, !qualityLabel.isEmpty else { return displayName }
        return "\(displayName) · \(qualityLabel)"
    }
}

public enum SpeechVoiceCatalog {
    /// Voices installed for the given BCP-47 language prefix (defaults to English).
    public static func options(languagePrefix: String = "en") -> [SpeechVoiceOption] {
        var result = [SpeechVoiceOption(identifier: "", displayName: "Automatic", qualityLabel: nil)]
        #if canImport(AVFoundation)
        let prefix = languagePrefix.lowercased()
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix(prefix) && !isNoveltyOrLegacy($0) }
            .sorted { lhs, rhs in
                // Premium/Enhanced first (so a downloaded neural voice sits at the top), then by name.
                let qL = qualityRank(for: lhs), qR = qualityRank(for: rhs)
                if qL != qR { return qL > qR }
                if lhs.name != rhs.name { return lhs.name < rhs.name }
                return lhs.identifier < rhs.identifier
            }
        for voice in voices {
            result.append(
                SpeechVoiceOption(
                    identifier: voice.identifier,
                    displayName: voice.name,
                    qualityLabel: qualityLabel(for: voice)
                )
            )
        }
        #endif
        return result
    }

    public static func displayName(for identifier: String) -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Automatic" }
        return options().first(where: { $0.identifier == trimmed })?.menuLabel
            ?? trimmed
    }

    #if canImport(AVFoundation)
    /// The best installed voice to use when the user leaves the voice on "Automatic". macOS's own
    /// `AVSpeechSynthesisVoice(language:)` default returns the *compact* system voice, which sounds
    /// robotic; this prefers a Premium (the modern neural, "Siri"-class voices) or Enhanced voice when
    /// the user has downloaded one, and otherwise returns nil so the caller keeps the system default
    /// (we never downgrade to a `.default`-quality novelty voice like "Albert" or "Bells").
    public static func bestAvailableVoice(forLanguage language: String) -> AVSpeechSynthesisVoice? {
        let lang = language.lowercased()
        let prefix = String(lang.prefix(2))
        let upgraded = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix(prefix) && qualityRank(for: $0) >= 2 }
            .sorted { lhs, rhs in
                // Exact locale (e.g. en-US over en-AU) first, then higher quality, then a stable name.
                let exactL = lhs.language.lowercased() == lang
                let exactR = rhs.language.lowercased() == lang
                if exactL != exactR { return exactL && !exactR }
                let rankL = qualityRank(for: lhs), rankR = qualityRank(for: rhs)
                if rankL != rankR { return rankL > rankR }
                return lhs.name < rhs.name
            }
        return upgraded.first
    }

    /// Whether a saved identifier still maps to a voice we offer (not novelty/legacy). `speak()` uses
    /// this so an old hidden pick (e.g. a stray "Whisper") falls back to the best voice instead of
    /// being honored after we've removed it from the picker. Empty/unknown ids return false (→ Automatic).
    public static func isOffered(identifier: String) -> Bool {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: trimmed) else { return false }
        return !isNoveltyOrLegacy(voice)
    }

    /// Apple's novelty voices ("Bad News", "Bubbles", "Whisper", "Zarvox", …) and the retro Eloquence
    /// family ("Eddy", "Grandma", … shipped in a dozen locales) sound robotic or comedic and bury the
    /// few real voices in the picker. Both live in stable identifier namespaces, so hide them and keep
    /// the genuine compact/enhanced/premium/Siri voices. Identifier-based, so it stays locale-proof.
    private static func isNoveltyOrLegacy(_ voice: AVSpeechSynthesisVoice) -> Bool {
        let id = voice.identifier.lowercased()
        return id.contains(".speech.synthesis.voice.") || id.contains(".eloquence.")
    }

    /// 3 = Premium, 2 = Enhanced, 1 = default/compact. Drives both the menu label and the "Automatic"
    /// upgrade so the two stay in sync.
    private static func qualityRank(for voice: AVSpeechSynthesisVoice) -> Int {
        if #available(macOS 14.0, *) {
            switch voice.quality {
            case .premium: return 3
            case .enhanced: return 2
            default: break
            }
        }
        if voice.identifier.localizedCaseInsensitiveContains("premium") { return 3 }
        if voice.identifier.localizedCaseInsensitiveContains("enhanced") { return 2 }
        return 1
    }

    private static func qualityLabel(for voice: AVSpeechSynthesisVoice) -> String? {
        switch qualityRank(for: voice) {
        case 3: return "Premium"
        case 2: return "Enhanced"
        default: return nil
        }
    }
    #endif
}
