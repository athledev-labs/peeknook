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

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func installedModelNames(baseURL: String) async -> [String] {
        do {
            let base = try resolveBaseURL(baseURL)
            let url = base.appendingPathComponent("api/tags")
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.timeoutInterval = 8
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            let tags = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
            return tags.models.map(\.name)
        } catch {
            return []
        }
    }

    public func status(baseURL: String, model: String) async -> OllamaSetupStatus {
        do {
            let base = try resolveBaseURL(baseURL)
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

    public func pullModel(baseURL: String, model: String) -> AsyncThrowingStream<OllamaPullEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let base = try resolveBaseURL(baseURL)
                    try await streamPull(baseURL: base, model: model, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - HTTP

    private func resolveBaseURL(_ string: String) throws -> URL {
        guard let url = URL(string: string), url.scheme != nil else {
            throw InferenceError.invalidBaseURL
        }
        return url
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
        let url = baseURL.appendingPathComponent("api/tags")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 8
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw InferenceError.ollamaUnreachable("Could not list models.")
        }
        let tags = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
        return Self.matchesModel(installedNames: tags.models.map(\.name), wanted: model)
    }

    /// Tag-aware match. Ollama implies `:latest` when a tag is omitted, so bare "gemma4"
    /// resolves to "gemma4:latest". But distinct tags are distinct models — "gemma4:e2b"
    /// must NOT satisfy a request for "gemma4:e4b" (a base-name match did exactly that,
    /// hiding the missing model until inference 404'd).
    public static func matchesModel(installedNames: [String], wanted: String) -> Bool {
        let target = normalizeModelName(wanted)
        guard !target.isEmpty else { return false }
        return installedNames.contains { normalizeModelName($0) == target }
    }

    private static func normalizeModelName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed.contains(":") ? trimmed : "\(trimmed):latest"
    }

    private func streamPull(
        baseURL: URL,
        model: String,
        continuation: AsyncThrowingStream<OllamaPullEvent, Error>.Continuation
    ) async throws {
        let url = baseURL.appendingPathComponent("api/pull")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 3600

        let body = OllamaPullRequest(model: model, stream: true)
        req.httpBody = try JSONEncoder().encode(body)

        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw InferenceError.http(
                status: (response as? HTTPURLResponse)?.statusCode ?? -1,
                message: "Model download failed. Is Ollama running?"
            )
        }

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

struct OllamaTagsResponse: Decodable, Sendable {
    // Shared with OllamaInferenceEngine in this module.
    struct Model: Decodable, Sendable {
        let name: String
    }
    let models: [Model]
}

private struct OllamaPullRequest: Encodable, Sendable {
    let model: String
    let stream: Bool
}

private struct OllamaPullChunk: Decodable, Sendable {
    let status: String?
    let completed: Int?
    let total: Int?
}
