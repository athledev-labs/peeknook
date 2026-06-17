// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Unified gate for outbound text that could carry secrets (web lookup, catalog search, remote/cloud
/// inference). The boolean egresses BLOCK the whole request; `remoteInference` instead REDACTS the
/// secret spans in place so the request still goes through with the secrets stripped.
public struct SensitiveContentPolicy: Sendable {
    public enum Egress: Sendable {
        case webLookup
        case catalogSearch
        /// Text headed to a remote or `:cloud` inference endpoint. Unlike the other egresses this does
        /// not block; the coordinator redacts via ``redactedForRemoteInference(text:)`` instead.
        case remoteInference
    }

    /// The fixed marker a redacted secret span is replaced with in remote-bound text.
    public static let redactionToken = "[redacted secret]"

    /// The redacted text plus how many spans were stripped, so the caller can both send the cleaned
    /// text and surface "removed N secrets".
    public struct Redaction: Sendable, Equatable {
        public let text: String
        public let hitCount: Int

        public init(text: String, hitCount: Int) {
            self.text = text
            self.hitCount = hitCount
        }
    }

    public init() {}

    public func allowsEgress(
        text: String?,
        windowTitle: String?,
        appName: String?,
        for egress: Egress
    ) -> Bool {
        switch egress {
        case .webLookup:
            return !SensitiveTextHeuristics.shouldSkipWebLookup(
                text: text,
                windowTitle: windowTitle,
                appName: appName
            )
        case .catalogSearch:
            if let text, SensitiveTextHeuristics.looksSensitive(text) { return false }
            if let title = windowTitle, SensitiveTextHeuristics.looksSensitive(title) { return false }
            return true
        case .remoteInference:
            // Remote inference is never blocked at the gate — secrets are redacted in the payload
            // instead (see ``redactedForRemoteInference(text:)``), so the answer still streams.
            return true
        }
    }

    /// Redacts every secret span in `text`, replacing each with ``redactionToken``, and reports how
    /// many were stripped. `nil` in / out passes through unchanged with a zero count, and text with no
    /// secrets returns byte-identical so a clean payload is never rewritten.
    public func redactedForRemoteInference(text: String?) -> Redaction {
        guard let text else { return Redaction(text: "", hitCount: 0) }
        let spans = SensitiveTextHeuristics.sensitiveSpans(in: text)
        guard !spans.isEmpty else { return Redaction(text: text, hitCount: 0) }

        // Splice from the end so earlier ranges stay valid as we replace. Spans are already sorted,
        // ascending and non-overlapping, so reversing gives a safe right-to-left rewrite.
        var redacted = text
        for hit in spans.reversed() {
            redacted.replaceSubrange(hit.range, with: Self.redactionToken)
        }
        return Redaction(text: redacted, hitCount: spans.count)
    }

    public func webLookupFailureIfBlocked(capture: CaptureResult) -> WebLookupSnapshot.Failure? {
        guard !allowsEgress(
            text: capture.text,
            windowTitle: capture.windowTitle,
            appName: capture.appName,
            for: .webLookup
        ) else { return nil }
        return .sensitiveContent
    }
}
