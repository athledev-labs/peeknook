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
            .filter { $0.language.lowercased().hasPrefix(prefix) }
            .sorted { lhs, rhs in
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
    private static func qualityLabel(for voice: AVSpeechSynthesisVoice) -> String? {
        if #available(macOS 14.0, *) {
            switch voice.quality {
            case .enhanced: return "Enhanced"
            case .premium: return "Premium"
            default: break
            }
        }
        if voice.identifier.localizedCaseInsensitiveContains("enhanced") { return "Enhanced" }
        if voice.identifier.localizedCaseInsensitiveContains("premium") { return "Premium" }
        return nil
    }
    #endif
}
