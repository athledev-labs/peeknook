// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Network-bound web lookup work, kept off the orchestrator's observable surface until complete.
public struct WebLookupRunner: Sendable {
    public var client: WebSearchClient

    public init(client: WebSearchClient = WebSearchClient()) {
        self.client = client
    }

    /// Run opt-in DuckDuckGo lookup for a capture turn. Returns a snapshot even when blocked or failed.
    public func lookup(capture: CaptureResult) async -> WebLookupSnapshot? {
        let sensitive = SensitiveTextHeuristics.shouldSkipWebLookup(
            text: capture.text,
            windowTitle: capture.windowTitle,
            appName: capture.appName
        )
        if sensitive {
            return WebLookupSnapshot(
                query: "",
                results: [],
                lookupFailed: true,
                lookupFailure: .sensitiveContent
            )
        }
        guard let query = WebSearchClient.query(from: capture) else { return nil }

        let allowed = await WebSearchRateLimiter.shared.allowSearch()
        if !allowed {
            return WebLookupSnapshot(
                query: query,
                results: [],
                lookupFailed: true,
                lookupFailure: .rateLimited
            )
        }

        do {
            let results = try await client.search(query: query)
            return WebLookupSnapshot(query: query, results: results)
        } catch {
            return WebLookupSnapshot(
                query: query,
                results: [],
                lookupFailed: true,
                lookupFailure: .unavailable
            )
        }
    }
}
