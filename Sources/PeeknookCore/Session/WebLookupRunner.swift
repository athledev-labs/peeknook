// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Network-bound web lookup work, kept off the orchestrator's observable surface until complete.
public protocol WebLookupProviding: Sendable {
    func lookup(capture: CaptureResult) async -> WebLookupSnapshot?
}

/// No-network double for unit tests and the UI test host.
public struct StubWebLookup: WebLookupProviding, Sendable {
    public init() {}

    public func lookup(capture: CaptureResult) async -> WebLookupSnapshot? { nil }
}

public struct WebLookupRunner: WebLookupProviding, Sendable {
    public var client: WebSearchClient
    public var policy: SensitiveContentPolicy

    public init(client: WebSearchClient = WebSearchClient(), policy: SensitiveContentPolicy = SensitiveContentPolicy()) {
        self.client = client
        self.policy = policy
    }

    /// Run opt-in DuckDuckGo lookup for a capture turn. Returns a snapshot even when blocked or failed.
    public func lookup(capture: CaptureResult) async -> WebLookupSnapshot? {
        if let failure = policy.webLookupFailureIfBlocked(capture: capture) {
            return WebLookupSnapshot(
                query: "",
                results: [],
                lookupFailed: true,
                lookupFailure: failure
            )
        }
        guard let query = WebSearchClient.query(from: capture, policy: policy) else { return nil }

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
