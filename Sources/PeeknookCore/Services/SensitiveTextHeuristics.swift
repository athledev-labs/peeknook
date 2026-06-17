// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A matched secret span inside a piece of text — the substring range plus a coarse kind, so a
/// caller can either ask "does this look sensitive?" (any hit) or redact each hit in place.
public struct SecretHit: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case pem            // -----BEGIN … key/cert block
        case labeledSecret  // api_key=…, Bearer …, password: …
        case token          // a bare prefixed/JWT/high-entropy token
    }
    /// Range into the text passed to ``SensitiveTextHeuristics/sensitiveSpans(in:)``.
    public let range: Range<String.Index>
    public let kind: Kind

    public init(range: Range<String.Index>, kind: Kind) {
        self.range = range
        self.kind = kind
    }
}

/// Heuristic detection of secrets in text that must not leave the Mac unredacted (web lookup, catalog
/// search, and remote/cloud inference). ``sensitiveSpans(in:)`` is the single source of truth for what
/// counts as a secret; ``looksSensitive(_:)`` / ``shouldSkipWebLookup(text:windowTitle:appName:)`` are
/// thin wrappers over it, so the boolean egress gates and the span-level redaction can never disagree.
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

    /// True when the text contains at least one secret span. A thin wrapper over
    /// ``sensitiveSpans(in:)`` so the definition of "a secret" never drifts between the boolean gate
    /// and the redactor.
    public static func looksSensitive(_ text: String) -> Bool {
        !sensitiveSpans(in: text).isEmpty
    }

    /// Every secret span in `text`, in ascending, non-overlapping order. The same scan window and
    /// classification as the boolean gate; an empty/whitespace-only string yields none. Ranges index
    /// into the `text` argument (the same string the caller redacts).
    public static func sensitiveSpans(in text: String) -> [SecretHit] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        // Scan only the leading window (matching the boolean gate's bound). The window is a leading
        // slice of `text`, so its `String.Index` values index directly into `text` — the hit ranges
        // returned are valid against the same string the caller redacts.
        let scanEnd = text.index(text.startIndex, offsetBy: scanLimit, limitedBy: text.endIndex)
            ?? text.endIndex
        let limited = text[text.startIndex..<scanEnd]

        var hits: [SecretHit] = []
        hits.append(contentsOf: pemSpans(in: limited))
        hits.append(contentsOf: labeledSecretSpans(in: limited))
        hits.append(contentsOf: tokenSpans(in: limited))
        return mergeNonOverlapping(hits)
    }

    /// `-----BEGIN …` PEM blocks: redact from the BEGIN marker through the matching END line, or to the
    /// end of text when no END is present.
    private static func pemSpans(in text: Substring) -> [SecretHit] {
        var hits: [SecretHit] = []
        var searchStart = text.startIndex
        while let begin = text.range(of: "-----BEGIN", range: searchStart..<text.endIndex) {
            // Prefer the matching END line; fall back to the line containing BEGIN through end of text.
            let endRange = text.range(of: "-----END", range: begin.upperBound..<text.endIndex)
            let blockEnd: String.Index
            if let endRange {
                // Extend through the trailing "-----" of the END marker (and any following dashes).
                var idx = endRange.upperBound
                while idx < text.endIndex, text[idx] != "\n" { idx = text.index(after: idx) }
                blockEnd = idx
            } else {
                var idx = begin.lowerBound
                while idx < text.endIndex, text[idx] != "\n" { idx = text.index(after: idx) }
                blockEnd = idx
            }
            hits.append(SecretHit(range: begin.lowerBound..<blockEnd, kind: .pem))
            searchStart = blockEnd
            if searchStart >= text.endIndex { break }
        }
        return hits
    }

    private static func labeledSecretSpans(in text: Substring) -> [SecretHit] {
        let base = text.base
        let nsString = String(text)
        let range = NSRange(nsString.startIndex..<nsString.endIndex, in: nsString)
        var hits: [SecretHit] = []
        for regex in labeledSecretRegexes {
            for match in regex.matches(in: nsString, range: range) {
                let valueNSRange = match.numberOfRanges > 2 ? match.range(at: 2) : match.range(at: 1)
                guard valueNSRange.location != NSNotFound,
                      let localRange = Range(valueNSRange, in: nsString),
                      let valueRange = mapRange(localRange, from: nsString, ontoSubstring: text, base: base)
                else { continue }
                let value = String(base[valueRange])
                // Only the VALUE span is a secret (the label "api_key=" stays); same accept rule as the
                // boolean gate: a classified token, or any value of length >= 6.
                if classifyToken(value) || value.count >= 6 {
                    hits.append(SecretHit(range: valueRange, kind: .labeledSecret))
                }
            }
        }
        return hits
    }

    /// Translates a range found in a standalone copy of the scan window back onto the original string's
    /// indices, by character offset from the window's start. The window is a leading slice, so a
    /// character offset within it is the same offset within the original.
    private static func mapRange(
        _ local: Range<String.Index>,
        from copy: String,
        ontoSubstring window: Substring,
        base: String
    ) -> Range<String.Index>? {
        let lowerOffset = copy.distance(from: copy.startIndex, to: local.lowerBound)
        let upperOffset = copy.distance(from: copy.startIndex, to: local.upperBound)
        guard let lower = base.index(window.startIndex, offsetBy: lowerOffset, limitedBy: base.endIndex),
              let upper = base.index(window.startIndex, offsetBy: upperOffset, limitedBy: base.endIndex)
        else { return nil }
        return lower..<upper
    }

    /// Bare tokens classified as secrets (prefixed keys, JWTs, high-entropy strings). Splits on the
    /// same delimiter set as the boolean tokenizer, but tracks each token's range so it can be redacted.
    private static func tokenSpans(in text: Substring) -> [SecretHit] {
        let delimiters = Set("=:,;\"'`()[]{}<>|")
        var hits: [SecretHit] = []
        var tokenStart: String.Index?
        func flush(_ end: String.Index) {
            guard let start = tokenStart else { return }
            let token = String(text[start..<end])
            if classifyToken(token) {
                hits.append(SecretHit(range: start..<end, kind: .token))
            }
            tokenStart = nil
        }
        var idx = text.startIndex
        while idx < text.endIndex {
            let char = text[idx]
            if char.isWhitespace || char.isNewline || delimiters.contains(char) {
                flush(idx)
            } else if tokenStart == nil {
                tokenStart = idx
            }
            idx = text.index(after: idx)
        }
        flush(text.endIndex)
        return hits
    }

    /// Sorts hits and drops any contained in an earlier (typically wider) hit so a labeled secret's
    /// value and the same span found as a bare token never redact twice or nest.
    private static func mergeNonOverlapping(_ hits: [SecretHit]) -> [SecretHit] {
        let sorted = hits.sorted { lhs, rhs in
            if lhs.range.lowerBound != rhs.range.lowerBound {
                return lhs.range.lowerBound < rhs.range.lowerBound
            }
            return lhs.range.upperBound > rhs.range.upperBound // widest first at the same start
        }
        var result: [SecretHit] = []
        for hit in sorted {
            if let last = result.last, hit.range.lowerBound < last.range.upperBound {
                continue // overlaps / nested inside the previous span — already covered
            }
            result.append(hit)
        }
        return result
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
