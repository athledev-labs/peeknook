// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Heuristic detection of secrets in text that must not leave the Mac via web lookup.
public enum SensitiveTextHeuristics: Sendable {
    private static let secretPrefixes: [(prefix: String, minSuffix: Int)] = [
        ("sk-", 16), ("sk_live_", 16), ("sk_test_", 16),
        ("ghp_", 20), ("gho_", 20), ("ghu_", 20), ("ghs_", 20), ("ghr_", 20),
        ("xoxb-", 10), ("xoxp-", 10), ("xoxa-", 10), ("xoxr-", 10),
        ("AKIA", 16), ("ASIA", 16),
    ]

    private static let passwordManagerHints = [
        "1password", "bitwarden", "lastpass", "dashlane", "keepass", "keychain access",
        "proton pass", "enpass", "nordpass", "strongbox", "macpass",
        "vault", "login item", "secure note", "passkey", "recovery code", "emergency kit",
    ]

    private static let scanLimit = 65536

    private static let labeledSecretRegexes: [NSRegularExpression] = {
        let patterns = [
            #"(?i)(api[_-]?key|secret|token|auth(?:orization)?|password)\s*[:=]\s*(\S+)"#,
            #"(?i)\bbearer\s+(\S+)"#,
            #"(?i)\bbasic\s+(\S+)"#,
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    /// Whether outbound web lookup should be skipped for this capture context.
    public static func shouldSkipWebLookup(
        text: String?,
        windowTitle: String?,
        appName: String?
    ) -> Bool {
        if let text, looksSensitive(text) { return true }
        if let title = windowTitle, looksSensitive(title) { return true }
        if let app = appName, isPasswordManagerContext(appName: app, windowTitle: windowTitle) {
            return true
        }
        return false
    }

    public static func looksSensitive(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let limited = String(trimmed.prefix(scanLimit))
        if limited.contains("-----BEGIN") { return true }
        if scanLabeledSecrets(in: limited) { return true }

        for token in tokenize(limited) {
            if classifyToken(token) { return true }
        }

        return false
    }

    private static func scanLabeledSecrets(in text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for regex in labeledSecretRegexes {
            guard let match = regex.firstMatch(in: text, range: range) else { continue }
            let valueRange = match.numberOfRanges > 2 ? match.range(at: 2) : match.range(at: 1)
            guard valueRange.location != NSNotFound,
                  let swiftRange = Range(valueRange, in: text) else { continue }
            let value = String(text[swiftRange])
            if classifyToken(value) { return true }
            if value.count >= 6 { return true }
        }
        return false
    }

    private static func tokenize(_ text: String) -> [String] {
        let delimiters = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "=:,;\"'`()[]{}<>|"))
        return text.components(separatedBy: delimiters).filter { !$0.isEmpty }
    }

    private static func classifyToken(_ token: String) -> Bool {
        if looksLikeJWT(token) { return true }

        for rule in secretPrefixes where token.hasPrefix(rule.prefix) {
            if token.count >= rule.prefix.count + rule.minSuffix { return true }
        }

        if highEntropyToken(token) { return true }

        return false
    }

    private static func looksLikeJWT(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].hasPrefix("eyJ") else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
    }

    private static func highEntropyToken(_ token: String) -> Bool {
        guard token.count >= 40 else { return false }
        if looksLikeUUID(token) { return false }
        return token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "+" || $0 == "/" || $0 == "=" }
    }

    private static func looksLikeUUID(_ token: String) -> Bool {
        let pattern = #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#
        return token.range(of: pattern, options: .regularExpression) != nil
    }

    private static func isPasswordManagerContext(appName: String, windowTitle: String?) -> Bool {
        let combined = (appName + " " + (windowTitle ?? "")).lowercased()
        return passwordManagerHints.contains { combined.contains($0) }
    }
}
