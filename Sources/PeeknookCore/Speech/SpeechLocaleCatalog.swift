// SPDX-License-Identifier: Apache-2.0

import Foundation

#if canImport(Speech)
import Speech
#endif

/// One speech-recognition source language offered in the profile editor's caption picker. The
/// `identifier` is the BCP-47 locale id (e.g. `ko-KR`); `displayName` is its human label
/// (e.g. "Korean (South Korea)"). The picker persists `displayName` into
/// ``ProfileOutputConfig/sourceLanguage`` — a label ``SpeechLocaleResolver`` resolves back to the
/// locale at arm, and that the translate prompt reads directly.
public struct SpeechSourceLanguage: Identifiable, Sendable, Equatable {
    public var id: String { identifier }
    public let identifier: String
    public let displayName: String

    public init(identifier: String, displayName: String) {
        self.identifier = identifier
        self.displayName = displayName
    }
}

/// The catalog of languages a caption can transcribe FROM. The actual set is device-specific (it comes
/// from the Speech framework), so the device probe is split from the pure formatting/sorting in
/// ``languages(from:)`` — the only part that must be deterministic and unit-testable. A picker built on
/// this list is what makes the source language typo-proof (no free text) and keeps the user from picking
/// a language the recognizer has never heard of; an installed-on-device check still happens at arm
/// (``RotatingSFSpeechTranscriber`` fails closed on a missing pack), so this is the discovery surface,
/// not the final authority.
public enum SpeechLocaleCatalog {
    /// Every language `SFSpeechRecognizer` advertises support for on this device, labeled + sorted.
    /// Device-gated: an empty list where Speech is unavailable (so `swift test` and non-Speech builds
    /// degrade to "no picker options", never a crash).
    public static func supportedSourceLanguages() -> [SpeechSourceLanguage] {
        #if canImport(Speech)
        return languages(from: Array(SFSpeechRecognizer.supportedLocales()))
        #else
        return []
        #endif
    }

    /// PURE: map locales to labeled source languages, English-named for a stable label (so the persisted
    /// value doesn't shift with the UI language), de-duplicated by display name, sorted alphabetically.
    /// Split out so the labeling/sorting is unit-testable apart from the device's locale set.
    public static func languages(from locales: [Locale]) -> [SpeechSourceLanguage] {
        let english = Locale(identifier: "en")
        var seenNames = Set<String>()
        var result: [SpeechSourceLanguage] = []
        for locale in locales {
            guard let name = displayName(for: locale, in: english) else { continue }
            guard seenNames.insert(name).inserted else { continue }
            result.append(SpeechSourceLanguage(identifier: locale.identifier, displayName: name))
        }
        return result.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// The English display name for a locale: the full region-qualified name when one exists
    /// ("Korean (South Korea)"), else the bare language name ("Korean"). Nil when neither resolves.
    static func displayName(for locale: Locale, in namer: Locale) -> String? {
        if let full = namer.localizedString(forIdentifier: locale.identifier), !full.isEmpty {
            return full
        }
        if let code = locale.language.languageCode?.identifier,
           let name = namer.localizedString(forLanguageCode: code), !name.isEmpty {
            return name
        }
        return nil
    }
}
