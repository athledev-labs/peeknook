// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One model page from the public Ollama library (via ollama-models community API).
public struct OllamaCatalogModel: Identifiable, Equatable, Sendable {
    public var id: String { modelID }
    public let modelID: String
    public let pageURL: URL

    /// Short display name, last path component of the model id.
    public var displayName: String {
        modelID.split(separator: "/").last.map(String.init) ?? modelID
    }

    public init(modelID: String, pageURL: URL) {
        self.modelID = modelID
        self.pageURL = pageURL
    }
}

public struct OllamaCatalogTagDetail: Equatable, Sendable {
    public let tag: String
    public let pullCommand: String

    public init(tag: String) {
        self.tag = tag
        self.pullCommand = "ollama pull \(tag)"
    }
}

/// Searches ollama.com's model library. Network-only, not used during capture inference.
public struct OllamaCatalogClient: Sendable {
    /// The built-in browse proxy for public model-catalog metadata (a community-hosted mirror of the
    /// Ollama library). This is the lone catalog egress host and the single place the trust lives;
    /// it is overridable via `PeeknookSettings.catalogBaseURL` and validated through `EndpointURLPolicy`
    /// at the wiring seam, so the dependency is explicit rather than silently hardcoded.
    public static let defaultCatalogBaseURL = "https://ollama-models-api.devcomfort.workers.dev"

    public var session: URLSession
    public var baseURL: String

    public init(
        session: URLSession = .shared,
        baseURL: String = OllamaCatalogClient.defaultCatalogBaseURL
    ) {
        self.session = session
        self.baseURL = baseURL
    }

    public func search(query: String, page: Int = 1) async throws -> [OllamaCatalogModel] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var components = URLComponents(string: baseURL + "/search")!
        var items = [URLQueryItem(name: "page", value: String(max(1, page)))]
        if !trimmed.isEmpty { items.append(URLQueryItem(name: "q", value: trimmed)) }
        components.queryItems = items

        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OllamaCatalogError.unavailable
        }
        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        return decoded.pages.compactMap { page in
            guard let url = URL(string: page.http_url) else { return nil }
            return OllamaCatalogModel(modelID: page.model_id, pageURL: url)
        }
    }

    public func tags(for modelID: String) async throws -> [OllamaCatalogTagDetail] {
        var components = URLComponents(string: baseURL + "/model")!
        components.queryItems = [URLQueryItem(name: "name", value: normalizedModelID(modelID))]

        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OllamaCatalogError.unavailable
        }
        let decoded = try JSONDecoder().decode(ModelResponse.self, from: data)
        return decoded.tags.map(OllamaCatalogTagDetail.init(tag:))
    }

    /// Heuristic vision filter for catalog rows before tags are loaded.
    public static func likelySupportsVision(modelID: String, tags: [String] = []) -> Bool {
        let haystack = (modelID + " " + tags.joined(separator: " ")).lowercased()
        let visionHints = ["vl", "vision", "llava", "moondream", "gemma4", "gemma-4", "minicpm-v", "bakllava"]
        return visionHints.contains { haystack.contains($0) }
    }

    public static func isCloudTag(_ tag: String) -> Bool {
        tag.lowercased().hasSuffix(":cloud")
    }

    private func normalizedModelID(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("/") { return trimmed }
        return "library/\(trimmed)"
    }

    private struct SearchResponse: Decodable {
        struct Page: Decodable {
            let http_url: String
            let model_id: String
        }
        let pages: [Page]
    }

    private struct ModelResponse: Decodable {
        let tags: [String]
    }
}

public enum OllamaCatalogError: Error, Equatable, Sendable {
    case unavailable
}
