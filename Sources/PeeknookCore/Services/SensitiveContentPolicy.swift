// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Unified gate for outbound text that could carry secrets (web lookup, catalog search).
public struct SensitiveContentPolicy: Sendable {
    public enum Egress: Sendable {
        case webLookup
        case catalogSearch
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
        }
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
