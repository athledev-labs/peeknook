// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct OllamaSetupStatus: Sendable, Equatable {
    public var isReachable: Bool
    public var reachabilityMessage: String
    public var isModelInstalled: Bool

    public var isInferenceReady: Bool { isReachable && isModelInstalled }
}

public enum OllamaPullEvent: Sendable, Equatable {
    case status(String)
    case completed
}

/// Ollama install / health / model pull for the setup wizard.
public struct OllamaSetupClient: Sendable {
    public var session: URLSession
    private let client: OllamaHTTPClient

    public init(session: URLSession = .shared) {
        self.session = session
        self.client = OllamaHTTPClient(session: session)
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
        let data = try await getJSON(baseURL: base, path: "api/tags", timeout: 8)
        let tags = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
        return tags.models.map { model in
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
            let installed = try await isModelInstalled(baseURL: base, model: model)
            return OllamaSetupStatus(
                isReachable: true,
                reachabilityMessage: "Ollama is running.",
                isModelInstalled: installed
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
        let url = baseURL.appendingPathComponent("api/version")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 4
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw InferenceError.ollamaUnreachable(
                "Ollama is not running. Install from ollama.com, then open the Ollama app or run `ollama serve`."
            )
        }
    }

    private func isModelInstalled(baseURL: URL, model: String) async throws -> Bool {
        let data = try await getJSON(baseURL: baseURL, path: "api/tags", timeout: 8)
        let tags = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
        return Self.matchesModel(installedNames: tags.models.map(\.name), wanted: model)
    }

    private func getJSON(baseURL: URL, path: String, timeout: TimeInterval) async throws -> Data {
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

        for try await line in bytes.lines {
            if Task.isCancelled { return }
            guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
            let chunk = try JSONDecoder().decode(OllamaPullChunk.self, from: data)
            if let status = chunk.status {
                if status == "success" {
                    continuation.yield(.completed)
                    continuation.finish()
                    return
                }
                let detail: String
                if let completed = chunk.completed, let total = chunk.total, total > 0 {
                    let pct = Int((Double(completed) / Double(total)) * 100)
                    detail = "\(status) (\(pct)%)"
                } else {
                    detail = status
                }
                continuation.yield(.status(detail))
            }
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
    let completed: Int?
    let total: Int?
}
