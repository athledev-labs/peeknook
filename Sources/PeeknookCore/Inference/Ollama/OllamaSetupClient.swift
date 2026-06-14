// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct OllamaSetupStatus: Sendable, Equatable {
    public var isReachable: Bool
    public var reachabilityMessage: String
    public var isModelInstalled: Bool
    /// Installed tags read off the SAME `/api/tags` fetch that decided `isModelInstalled`, so a
    /// `setup.refresh()` doesn't fetch the list a second time. Empty when unreachable.
    public var installedNames: [String] = []

    public var isInferenceReady: Bool { isReachable && isModelInstalled }
}

public enum OllamaPullEvent: Sendable, Equatable {
    case progress(PullProgress)
    case completed
}

/// One structured download-progress sample. `fraction` is the share of bytes pulled across ALL
/// layers (nil before any total is known), so a bar driven by it advances monotonically instead of
/// resetting per blob.
public struct PullProgress: Sendable, Equatable {
    public var phase: PullPhase
    public var fraction: Double?
    public var completedBytes: Int64?
    public var totalBytes: Int64?

    public init(phase: PullPhase, fraction: Double? = nil, completedBytes: Int64? = nil, totalBytes: Int64? = nil) {
        self.phase = phase
        self.fraction = fraction
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }
}

/// Friendly phase mapped from Ollama's raw `/api/pull` status verbs, so the UI never shows a sha256
/// digest. The single point to extend if Ollama changes its wording.
public enum PullPhase: Sendable, Equatable {
    case preparing, downloading, verifying, finishing

    public static func from(ollamaStatus status: String) -> PullPhase {
        let s = status.lowercased()
        if s.contains("manifest"), s.contains("pulling") { return .preparing }
        if s.hasPrefix("pulling") || s.contains("downloading") { return .downloading }
        if s.contains("verifying") { return .verifying }
        if s.contains("writing") || s.contains("removing") || s.contains("success") { return .finishing }
        return .preparing
    }
}

/// Ollama install / health / model pull for the setup wizard.
public struct OllamaSetupClient: Sendable {
    public var session: URLSession
    private let client: OllamaHTTPClient
    /// Shared health-probe coalescer (nil = probe the network directly, the original behavior).
    private let probeCache: OllamaProbeCache?

    public init(session: URLSession = .shared, probeCache: OllamaProbeCache? = nil) {
        self.session = session
        self.client = OllamaHTTPClient(session: session)
        self.probeCache = probeCache
    }

    public func installedModelNames(baseURL: String, acceptInsecureRemote: Bool = false) async -> [String] {
        (try? await installedModelFootprints(baseURL: baseURL, acceptInsecureRemote: acceptInsecureRemote).map(\.name)) ?? []
    }

    /// Installed model tags and on-disk sizes from `/api/tags` (local footprint).
    public func installedModelFootprints(
        baseURL: String,
        acceptInsecureRemote: Bool = false
    ) async throws -> [OllamaModelFootprint] {
        let base = try resolveBaseURL(baseURL, acceptInsecureRemote: acceptInsecureRemote)
        return try await fetchTagModels(baseURL: base).map { model in
            OllamaModelFootprint(name: model.name, sizeBytes: model.size ?? 0)
        }
    }

    /// Models currently loaded in memory from `/api/ps` (warm `keep_alive` residents).
    public func runningModelFootprints(
        baseURL: String,
        acceptInsecureRemote: Bool = false
    ) async throws -> [OllamaLoadedModelFootprint] {
        let base = try resolveBaseURL(baseURL, acceptInsecureRemote: acceptInsecureRemote)
        let data = try await getJSON(baseURL: base, path: "api/ps", timeout: 4)
        let ps = try JSONDecoder().decode(OllamaPsResponse.self, from: data)
        return ps.models.map { model in
            OllamaLoadedModelFootprint(name: model.name, sizeBytes: model.size ?? 0)
        }
    }

    public func status(baseURL: String, model: String, acceptInsecureRemote: Bool = false) async -> OllamaSetupStatus {
        do {
            let base = try resolveBaseURL(baseURL, acceptInsecureRemote: acceptInsecureRemote)
            try await ping(baseURL: base)
            // One `/api/tags` fetch yields both "is this model installed" and the full installed list
            // the caller needs, instead of probing tags here and again for the list.
            let installedNames = try await fetchTagModels(baseURL: base).map(\.name)
            return OllamaSetupStatus(
                isReachable: true,
                reachabilityMessage: "Ollama is running.",
                isModelInstalled: Self.matchesModel(installedNames: installedNames, wanted: model),
                installedNames: installedNames
            )
        } catch let error as InferenceError {
            return OllamaSetupStatus(
                isReachable: false,
                reachabilityMessage: error.localizedDescription,
                isModelInstalled: false
            )
        } catch {
            return OllamaSetupStatus(
                isReachable: false,
                reachabilityMessage: error.localizedDescription,
                isModelInstalled: false
            )
        }
    }

    public func pullModel(baseURL: String, model: String, acceptInsecureRemote: Bool = false) -> AsyncThrowingStream<OllamaPullEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let base = try resolveBaseURL(baseURL, acceptInsecureRemote: acceptInsecureRemote)
                    try await streamPull(baseURL: base, model: model, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - HTTP

    private func resolveBaseURL(_ string: String, acceptInsecureRemote: Bool) throws -> URL {
        try EndpointURLPolicy.resolveOrThrow(string, acceptInsecureRemote: acceptInsecureRemote)
    }

    private func ping(baseURL: URL) async throws {
        let session = self.session
        _ = try await OllamaProbeCache.resolve(
            probeCache, baseURL: baseURL, path: "api/version", ttl: OllamaProbeCache.healthTTL
        ) {
            let url = baseURL.appendingPathComponent("api/version")
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.timeoutInterval = 4
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw InferenceError.ollamaUnreachable(OllamaUnreachableCopy.notRunning)
            }
            return data
        }
    }

    /// Installed tags from a single (cacheable) `/api/tags` fetch. Both the reachability/model check in
    /// `status` and the footprint list derive from this so a refresh hits the endpoint once.
    private func fetchTagModels(baseURL: URL) async throws -> [OllamaTagsResponse.Model] {
        let data = try await getJSON(baseURL: baseURL, path: "api/tags", timeout: 8, ttl: OllamaProbeCache.healthTTL)
        return try JSONDecoder().decode(OllamaTagsResponse.self, from: data).models
    }

    /// `ttl > 0` routes the GET through the shared probe cache (when one is injected); `ttl == 0`
    /// (the default, used for non-coalesced probes like `/api/ps`) always hits the network.
    private func getJSON(baseURL: URL, path: String, timeout: TimeInterval, ttl: TimeInterval = 0) async throws -> Data {
        let session = self.session
        return try await OllamaProbeCache.resolve(probeCache, baseURL: baseURL, path: path, ttl: ttl) {
            let url = baseURL.appendingPathComponent(path)
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.timeoutInterval = timeout
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw InferenceError.ollamaUnreachable("Could not reach Ollama at \(baseURL.absoluteString).")
            }
            return data
        }
    }

    /// Tag-aware match. Ollama implies `:latest` when a tag is omitted, so bare "gemma4"
    /// resolves to "gemma4:latest". But distinct tags are distinct models, "gemma4:e2b"
    /// must NOT satisfy a request for "gemma4:e4b" (a base-name match did exactly that,
    /// hiding the missing model until inference 404'd).
    public static func matchesModel(installedNames: [String], wanted: String) -> Bool {
        ModelTag.matches(installedNames: installedNames, wanted: wanted)
    }

    /// Canonical form of an Ollama tag: trimmed, with an implied `:latest` when no tag is given.
    public static func normalizedTag(_ name: String) -> String {
        ModelTag.normalized(name)
    }

    private func streamPull(
        baseURL: URL,
        model: String,
        continuation: AsyncThrowingStream<OllamaPullEvent, Error>.Continuation
    ) async throws {
        let url = baseURL.appendingPathComponent("api/pull")
        // `pull` does NOT send `think`. Route through the shared client so a failed pull surfaces
        // Ollama's real error body (falling back to the existing message when it's empty).
        let bytes = try await client.postStream(
            url: url,
            body: ["model": model, "stream": true],
            timeout: 3600,
            fallbackMessage: "Model download failed. Is Ollama running?"
        )

        // Aggregate byte progress across ALL layers so the bar advances monotonically rather than
        // resetting per blob. Ollama sends `digest` + `total` + `completed` on each "pulling <digest>".
        var layers: [String: (total: Int64, completed: Int64)] = [:]
        for try await line in bytes.lines {
            if Task.isCancelled { return }
            guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
            let chunk = try JSONDecoder().decode(OllamaPullChunk.self, from: data)
            guard let status = chunk.status else { continue }
            if status == "success" {
                continuation.yield(.completed)
                continuation.finish()
                return
            }
            if let digest = chunk.digest, let total = chunk.total, total > 0 {
                layers[digest] = (total: total, completed: chunk.completed ?? 0)
            }
            let sumTotal = layers.values.reduce(Int64(0)) { $0 + $1.total }
            let sumCompleted = layers.values.reduce(Int64(0)) { $0 + $1.completed }
            let fraction = sumTotal > 0 ? Double(sumCompleted) / Double(sumTotal) : nil
            continuation.yield(.progress(PullProgress(
                phase: PullPhase.from(ollamaStatus: status),
                fraction: fraction,
                completedBytes: sumTotal > 0 ? sumCompleted : nil,
                totalBytes: sumTotal > 0 ? sumTotal : nil
            )))
        }
        continuation.yield(.completed)
        continuation.finish()
    }
}

public struct OllamaModelFootprint: Sendable, Equatable {
    public var name: String
    public var sizeBytes: Int64

    public init(name: String, sizeBytes: Int64) {
        self.name = name
        self.sizeBytes = sizeBytes
    }
}

struct OllamaTagsResponse: Decodable, Sendable {
    // Shared with OllamaInferenceEngine in this module.
    struct Model: Decodable, Sendable {
        let name: String
        let size: Int64?

        private enum CodingKeys: String, CodingKey {
            case name, size
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.name = try container.decode(String.self, forKey: .name)
            self.size = try container.decodeIfPresent(Int64.self, forKey: .size)
        }
    }
    let models: [Model]
}

struct OllamaPsResponse: Decodable, Sendable {
    struct Model: Decodable, Sendable {
        let name: String
        let size: Int64?

        private enum CodingKeys: String, CodingKey {
            case name, size
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.name = try container.decode(String.self, forKey: .name)
            self.size = try container.decodeIfPresent(Int64.self, forKey: .size)
        }
    }
    let models: [Model]
}

private struct OllamaPullChunk: Decodable, Sendable {
    let status: String?
    let digest: String?
    let completed: Int64?
    let total: Int64?
}
