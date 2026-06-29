// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Pure resolution of the user's free-text source-language label (the M3 `ProfileOutputConfig.sourceLanguage`)
/// to a BCP-47 `Locale`, chosen from a supplied set of on-device-supported locales. Split from the
/// hardware capability probe (the caller passes `supported`, e.g. `SFSpeechRecognizer.supportedLocales()`)
/// so the mapping is deterministically unit-testable.
///
/// Resolution order: exact identifier match, then a bare language-code match, then a localized
/// display-name match (so "ja", "ja-JP", and "Japanese" all resolve when the device supports a `ja`
/// locale). Returns `nil` when the label matches no supported locale — the caller then fail-closes
/// (refuses to arm) rather than silently transcribing in the wrong language.
public enum SpeechLocaleResolver: Sendable {
    public static func locale(forLanguageLabel label: String?, supported: [Locale]) -> Locale? {
        guard let raw = label?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let needle = raw.lowercased()
        let dashedNeedle = needle.replacingOccurrences(of: "_", with: "-")

        // 1) Exact identifier match (e.g. "pt-BR", "ja-JP", "en_US").
        for locale in supported where normalizedID(locale) == dashedNeedle {
            return locale
        }
        // 2) Bare language-code match (e.g. "ja" → the first supported "ja-*"), only for an unqualified
        // needle so "pt" never silently grabs "pt-BR" over a plain "pt" if both are present.
        if !dashedNeedle.contains("-") {
            for locale in supported where languageCode(locale) == needle {
                return locale
            }
        }
        // 3) Localized display-name match, tried as both the full identifier name and the bare language
        // name, in English and in the locale's own language (so "Japanese" and "日本語" both resolve).
        for locale in supported where displayNames(for: locale).contains(needle) {
            return locale
        }
        return nil
    }

    private static func normalizedID(_ locale: Locale) -> String {
        locale.identifier.lowercased().replacingOccurrences(of: "_", with: "-")
    }

    private static func languageCode(_ locale: Locale) -> String? {
        locale.language.languageCode?.identifier.lowercased()
    }

    private static func displayNames(for locale: Locale) -> Set<String> {
        let english = Locale(identifier: "en")
        var names: Set<String> = []
        for namer in [english, locale] {
            if let n = namer.localizedString(forIdentifier: locale.identifier) { names.insert(n.lowercased()) }
            if let code = languageCode(locale), let n = namer.localizedString(forLanguageCode: code) {
                names.insert(n.lowercased())
            }
        }
        return names
    }
}
