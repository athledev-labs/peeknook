// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Coalesces and briefly caches Ollama GET health probes (`/api/version`, `/api/tags`).
///
/// A single Settings open fires several independent readiness probes — the inference-health check, the
/// setup refresh (which lists tags twice), and the periodic poll — each hitting the same endpoints with
/// no coordination. This actor lets those consumers share one in-flight request and one short-lived
/// result instead of each going to the server, and turns the 3–5s poll loops into cache refreshes
/// rather than a thundering herd. Keyed by `(baseURL, path)` so a remote/endpoint switch is a clean
/// miss and never serves a localhost answer.
///
/// This is a probe-layer optimization only: no readiness *policy* lives here, and consumers keep calling
/// exactly what they call today. It is opt-in by construction — a client coalesces only when a cache is
/// injected (production wiring in `PeeknookServices.makeStack`); without one it calls the network
/// directly, so existing behavior and tests are unchanged.
public actor OllamaProbeCache {
    public struct Key: Hashable, Sendable {
        public let baseURL: String
        public let path: String

        public init(baseURL: String, path: String) {
            self.baseURL = baseURL
            self.path = path
        }
    }

    private struct Entry {
        let data: Data
        let storedAt: Date
    }

    private let now: @Sendable () -> Date
    private var cache: [Key: Entry] = [:]
    private var inFlight: [Key: Task<Data, Error>] = [:]
    /// Bumped by ``invalidate(baseURL:)``. A fetch that started before an invalidation must not write
    /// its now-stale result into the cache (otherwise a `/api/tags` request in flight when a model pull
    /// finishes would re-cache the pre-pull list), so we compare the epoch captured at start.
    private var epoch = 0

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// Returns a fresh cached value, joins an in-flight request for the same key, or starts one via
    /// `perform`. Successful responses are cached for `ttl`; failures are never cached (the next caller
    /// retries), so a transient outage can't pin a stale "unreachable" result.
    public func value(
        for key: Key,
        ttl: TimeInterval,
        perform: @escaping @Sendable () async throws -> Data
    ) async throws -> Data {
        if let hit = cache[key], now().timeIntervalSince(hit.storedAt) < ttl {
            return hit.data
        }
        if let running = inFlight[key] {
            return try await running.value
        }
        let startEpoch = epoch
        let task = Task { try await perform() }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let data = try await task.value
        if epoch == startEpoch {
            cache[key] = Entry(data: data, storedAt: now())
        }
        return data
    }

    /// Drop cached probe results after a state change the cache can't observe — a completed model pull,
    /// for example — so a freshly installed tag isn't masked by a still-fresh `/api/tags` entry. Passing
    /// a `baseURL` drops only that endpoint's entries; passing nil clears everything.
    public func invalidate(baseURL: String? = nil) {
        epoch &+= 1
        guard let baseURL else {
            cache.removeAll()
            return
        }
        cache = cache.filter { $0.key.baseURL != baseURL }
    }
}

public extension OllamaProbeCache {
    /// Route a probe through `cache` when one is present and `ttl > 0`; otherwise run `perform`
    /// directly. Lets the Ollama clients share one coalescing path whether or not a cache was injected,
    /// so an un-wired client (every existing test, any default construction) behaves exactly as before.
    static func resolve(
        _ cache: OllamaProbeCache?,
        baseURL: URL,
        path: String,
        ttl: TimeInterval,
        perform: @escaping @Sendable () async throws -> Data
    ) async throws -> Data {
        guard let cache, ttl > 0 else { return try await perform() }
        let key = Key(baseURL: baseURL.absoluteString, path: path)
        return try await cache.value(for: key, ttl: ttl, perform: perform)
    }

    /// Health probes (`/api/version`, `/api/tags`) coalesce for this long. Matches the setup
    /// auto-refresh cadence so its loop becomes a cache refresh rather than a fresh round trip.
    static let healthTTL: TimeInterval = 3
}
