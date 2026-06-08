// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Heuristic detection of secrets in text that must not leave the Mac via web lookup.
public enum SensitiveTextHeuristics: Sendable {
    private static let secretPrefixes = [
        "sk-", "sk_live_", "sk_test_", "ghp_", "gho_", "ghu_", "ghs_", "ghr_",
        "xoxb-", "xoxp-", "xoxa-", "xoxr-", "AKIA", "ASIA", "Bearer ", "Basic "
    ]

    private static let passwordManagerHints = [
        "1password", "bitwarden", "lastpass", "dashlane", "keepass", "keychain access"
    ]

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

        if trimmed.contains("-----BEGIN") { return true }
        if looksLikeJWT(trimmed) { return true }

        for prefix in secretPrefixes where trimmed.hasPrefix(prefix) || trimmed.contains(" \(prefix)") {
            return true
        }

        if trimmed.count >= 24, trimmed.range(of: #"\s"#, options: .regularExpression) == nil {
            let alnum = trimmed.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            if alnum.count == trimmed.count, trimmed.count >= 32 {
                return true
            }
        }

        return false
    }

    private static func looksLikeJWT(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].hasPrefix("eyJ") else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
    }

    private static func isPasswordManagerContext(appName: String, windowTitle: String?) -> Bool {
        let combined = (appName + " " + (windowTitle ?? "")).lowercased()
        return passwordManagerHints.contains { combined.contains($0) }
    }
}
