// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest
@testable import PeeknookCore

/// Guards the probe-coalescing contract: when a shared ``OllamaProbeCache`` is injected, the several
/// health probes that fire on a single Settings open (`inferenceHealth` + `setup.refresh`, which lists
/// tags more than once) collapse to one `/api/version` and one `/api/tags` request — and without a
/// cache injected, behavior is unchanged (each call hits the network), which is what keeps every other
/// test in the suite valid.
final class OllamaProbeCacheTests: XCTestCase {
    private let base = "http://127.0.0.1:11434"
    private let model = "gemma4:e2b"

    override func setUp() {
        super.setUp()
        OllamaURLProtocolStub.responsesByPath = [:]
        OllamaURLProtocolStub.requestCountByPath = [:]
        OllamaURLProtocolStub.recordedBodies = []
        OllamaURLProtocolStub.recordedAuthorizationHeaders = []
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OllamaURLProtocolStub.self]
        return URLSession(configuration: config)
    }

    private func ok(_ body: String) -> OllamaURLProtocolStub.QueuedResponse {
        OllamaURLProtocolStub.QueuedResponse(statusCode: 200, body: Data(body.utf8), headers: [:])
    }

    private var versionBody: String { #"{"version":"0.30.4"}"# }
    private var tagsBody: String { #"{"models":[{"name":"gemma4:e2b","size":123}]}"# }

    // MARK: - The headline contract

    /// Three concurrent consumers (setup status, inference health, installed-model list) request
    /// `/api/version` twice and `/api/tags` three times between them; sharing one cache must collapse
    /// each endpoint to a single round trip.
    func testConcurrentReadinessProbesCoalesceAcrossClients() async {
        let session = makeSession()
        let cache = OllamaProbeCache()
        let setup = OllamaSetupClient(session: session, probeCache: cache)
        let engine = OllamaInferenceEngine(session: session, probeCache: cache)
        OllamaURLProtocolStub.responsesByPath = [
            "/api/version": [ok(versionBody)],
            "/api/tags": [ok(tagsBody)],
        ]

        async let status = setup.status(baseURL: base, model: model)        // version + tags
        async let health = engine.health(baseURL: base, model: model, acceptInsecureRemote: false) // version + tags
        async let names = setup.installedModelNames(baseURL: base)          // tags
        let (statusResult, healthResult, nameResult) = await (status, health, names)

        XCTAssertEqual(OllamaURLProtocolStub.requestCountByPath["/api/version"], 1, "version probe should coalesce to one request")
        XCTAssertEqual(OllamaURLProtocolStub.requestCountByPath["/api/tags"], 1, "tags probe should coalesce to one request")
        // And every consumer still got a correct answer off the single shared response.
        XCTAssertTrue(statusResult.isInferenceReady)
        XCTAssertEqual(healthResult, .ready)
        XCTAssertEqual(nameResult, [model])
    }

    /// A second probe inside the TTL window is served from cache, not the network.
    func testSequentialProbeWithinTTLIsServedFromCache() async {
        let session = makeSession()
        let cache = OllamaProbeCache()
        let setup = OllamaSetupClient(session: session, probeCache: cache)
        OllamaURLProtocolStub.responsesByPath = [
            "/api/version": [ok(versionBody)],
            "/api/tags": [ok(tagsBody)],
        ]

        _ = await setup.status(baseURL: base, model: model)
        _ = await setup.status(baseURL: base, model: model)

        XCTAssertEqual(OllamaURLProtocolStub.requestCountByPath["/api/version"], 1)
        XCTAssertEqual(OllamaURLProtocolStub.requestCountByPath["/api/tags"], 1)
    }

    /// `invalidate` drops the cache so a state change the cache can't observe (a model pull) is picked
    /// up by the next probe instead of being masked for the TTL.
    func testInvalidateForcesAFreshProbe() async {
        let session = makeSession()
        let cache = OllamaProbeCache()
        let setup = OllamaSetupClient(session: session, probeCache: cache)
        OllamaURLProtocolStub.responsesByPath = [
            "/api/version": [ok(versionBody), ok(versionBody)],
            "/api/tags": [ok(tagsBody), ok(tagsBody)],
        ]

        _ = await setup.status(baseURL: base, model: model)
        await cache.invalidate(baseURL: base)
        _ = await setup.status(baseURL: base, model: model)

        XCTAssertEqual(OllamaURLProtocolStub.requestCountByPath["/api/version"], 2)
        XCTAssertEqual(OllamaURLProtocolStub.requestCountByPath["/api/tags"], 2)
    }

    /// The opt-in guarantee: a client built WITHOUT a cache behaves exactly as before — every call
    /// hits the network. This is what keeps the rest of the suite (which injects no cache) valid.
    func testWithoutCacheEachProbeHitsTheNetwork() async {
        let session = makeSession()
        let setup = OllamaSetupClient(session: session) // no probeCache
        OllamaURLProtocolStub.responsesByPath = [
            "/api/version": [ok(versionBody), ok(versionBody)],
            "/api/tags": [ok(tagsBody), ok(tagsBody)],
        ]

        _ = await setup.status(baseURL: base, model: model)
        _ = await setup.status(baseURL: base, model: model)

        XCTAssertEqual(OllamaURLProtocolStub.requestCountByPath["/api/version"], 2)
        XCTAssertEqual(OllamaURLProtocolStub.requestCountByPath["/api/tags"], 2)
    }

    // MARK: - Single-pass status (independent of caching)

    /// `status` carries the installed-model list off the SAME `/api/tags` fetch it uses to decide
    /// `isModelInstalled`, so a `setup.refresh()` no longer needs a second list probe. Proven WITHOUT a
    /// cache so it's a structural single fetch, not cache dedup.
    func testStatusCarriesInstalledNamesFromASingleTagsFetch() async {
        let session = makeSession()
        let setup = OllamaSetupClient(session: session) // no probeCache
        OllamaURLProtocolStub.responsesByPath = [
            "/api/version": [ok(versionBody)],
            "/api/tags": [ok(tagsBody)],
        ]

        let status = await setup.status(baseURL: base, model: model)

        XCTAssertTrue(status.isReachable)
        XCTAssertTrue(status.isModelInstalled)
        XCTAssertEqual(status.installedNames, [model])
        XCTAssertEqual(OllamaURLProtocolStub.requestCountByPath["/api/tags"], 1, "status reads the list from its one tags fetch")
    }

    // MARK: - Cache mechanism

    /// Failures are never cached: a transient outage must not pin an "unreachable" result for the TTL.
    func testFailuresAreNotCached() async {
        let cache = OllamaProbeCache()
        let key = OllamaProbeCache.Key(baseURL: base, path: "api/tags")
        let counter = Counter()

        struct Boom: Error {}
        for _ in 0..<2 {
            _ = try? await cache.value(for: key, ttl: 60) {
                await counter.increment()
                throw Boom()
            }
        }
        let failingRuns = await counter.value
        XCTAssertEqual(failingRuns, 2, "each call should re-run perform because failures aren't cached")

        // A subsequent success is then cached and reused.
        let successCounter = Counter()
        for _ in 0..<2 {
            _ = try? await cache.value(for: key, ttl: 60) {
                await successCounter.increment()
                return Data("ok".utf8)
            }
        }
        let successRuns = await successCounter.value
        XCTAssertEqual(successRuns, 1, "a cached success should be reused within the TTL")
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
