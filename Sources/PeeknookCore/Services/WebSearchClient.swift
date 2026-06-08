// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct WebSearchResult: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public let title: String
    public let url: URL
    public let snippet: String

    public init(id: UUID = UUID(), title: String, url: URL, snippet: String) {
        self.id = id
        self.title = title
        self.url = url
        self.snippet = snippet
    }

    public var host: String {
        url.host?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString
    }
}

public struct WebLookupSnapshot: Equatable, Sendable, Codable, Identifiable {
    public enum Failure: String, Codable, Sendable, Equatable {
        case unavailable
        case rateLimited
        case sensitiveContent
    }

    public let id: UUID
    public let query: String
    public let results: [WebSearchResult]
    public let fetchedAt: Date
    /// True when lookup was attempted but failed or was throttled (distinct from zero organic results).
    public var lookupFailed: Bool
    public var lookupFailure: Failure?

    public init(
        id: UUID = UUID(),
        query: String,
        results: [WebSearchResult],
        fetchedAt: Date = Date(),
        lookupFailed: Bool = false,
        lookupFailure: Failure? = nil
    ) {
        self.id = id
        self.query = query
        self.results = results
        self.fetchedAt = fetchedAt
        self.lookupFailed = lookupFailed
        self.lookupFailure = lookupFailure
    }

    private enum CodingKeys: String, CodingKey {
        case id, query, results, fetchedAt, lookupFailed, lookupFailure
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.query = try c.decodeIfPresent(String.self, forKey: .query) ?? ""
        self.results = try c.decodeIfPresent([WebSearchResult].self, forKey: .results) ?? []
        self.fetchedAt = try c.decodeIfPresent(Date.self, forKey: .fetchedAt) ?? Date()
        self.lookupFailed = try c.decodeIfPresent(Bool.self, forKey: .lookupFailed) ?? false
        self.lookupFailure = try c.decodeIfPresent(Failure.self, forKey: .lookupFailure)
    }
}

public enum WebSearchError: Error, Equatable, Sendable {
    case emptyQuery
    case unavailable
    case noResults
}

/// Opt-in web lookup, queries DuckDuckGo HTML (no API key). Network leaves this Mac.
public struct WebSearchClient: Sendable {
    public static let minimumIntervalBetweenSearches: TimeInterval = 2

    public var session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func search(query: String, maxResults: Int = 8) async throws -> [WebSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WebSearchError.emptyQuery }

        var request = URLRequest(url: URL(string: "https://html.duckduckgo.com/html/")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Peeknook/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 12
        let body = "q=\(trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed)"
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw WebSearchError.unavailable
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw WebSearchError.unavailable
        }

        let parsed = Self.parseHTMLResults(html, limit: maxResults)
        guard !parsed.isEmpty else { throw WebSearchError.noResults }
        return parsed
    }

    /// Build a search query from capture context, prefers selected text, then window title.
    /// Returns nil when the context looks sensitive (API keys, tokens, password managers).
    public static func query(
        from capture: CaptureResult,
        policy: SensitiveContentPolicy = SensitiveContentPolicy()
    ) -> String? {
        guard policy.allowsEgress(
            text: capture.text,
            windowTitle: capture.windowTitle,
            appName: capture.appName,
            for: .webLookup
        ) else {
            return nil
        }
        if let text = capture.text?.trimmingCharacters(in: .whitespacesAndNewlines), text.count >= 4 {
            let firstLine = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
            return String(firstLine.prefix(120))
        }
        if let title = capture.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        if let app = capture.appName?.trimmingCharacters(in: .whitespacesAndNewlines), !app.isEmpty {
            return app
        }
        return nil
    }

    /// Snippet block for the vision model when web lookup is enabled.
    public static func promptContext(from snapshot: WebLookupSnapshot, limit: Int = 4) -> String {
        let top = snapshot.results.prefix(limit)
        guard !top.isEmpty else { return "" }
        var lines = ["Live web lookup for \"\(snapshot.query)\" (opt-in; may be stale):"]
        for (index, result) in top.enumerated() {
            lines.append("\(index + 1). \(result.title) · \(result.url.absoluteString)")
            if !result.snippet.isEmpty {
                lines.append("   \(result.snippet)")
            }
        }
        lines.append("Use these only to supplement the screenshot, prefer what is visible on screen.")
        return lines.joined(separator: "\n")
    }

    // MARK: - HTML parsing (DuckDuckGo lite layout)

    static func parseHTMLResults(_ html: String, limit: Int) -> [WebSearchResult] {
        var results: [WebSearchResult] = []
        var searchStart = html.startIndex

        while results.count < limit {
            guard let anchorRange = html.range(of: "class=\"result__a\"", range: searchStart..<html.endIndex) else {
                break
            }
            guard let hrefRange = html.range(of: "href=\"", range: anchorRange.upperBound..<html.endIndex),
                  let hrefEnd = html.range(of: "\"", range: hrefRange.upperBound..<html.endIndex) else {
                searchStart = anchorRange.upperBound
                continue
            }
            let href = String(html[hrefRange.upperBound..<hrefEnd.lowerBound])
            guard let url = URL(string: href), url.scheme?.hasPrefix("http") == true else {
                searchStart = anchorRange.upperBound
                continue
            }

            guard let titleStart = html.range(of: ">", range: hrefEnd.upperBound..<html.endIndex),
                  let titleEnd = html.range(of: "</a>", range: titleStart.upperBound..<html.endIndex) else {
                searchStart = anchorRange.upperBound
                continue
            }
            let title = decodeHTMLEntities(String(html[titleStart.upperBound..<titleEnd.lowerBound]))
                .trimmingCharacters(in: .whitespacesAndNewlines)

            var snippet = ""
            if let snippetClass = html.range(of: "class=\"result__snippet\"", range: titleEnd.upperBound..<html.endIndex),
               let snippetStart = html.range(of: ">", range: snippetClass.upperBound..<html.endIndex),
               let snippetEnd = html.range(of: "</", range: snippetStart.upperBound..<html.endIndex) {
                snippet = decodeHTMLEntities(String(html[snippetStart.upperBound..<snippetEnd.lowerBound]))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            if !title.isEmpty {
                results.append(WebSearchResult(title: title, url: url, snippet: snippet))
            }
            searchStart = titleEnd.upperBound
        }
        return results
    }

    private static func decodeHTMLEntities(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}

/// Per-session throttle for opt-in web lookup (DuckDuckGo HTML).
public actor WebSearchRateLimiter {
    public static let shared = WebSearchRateLimiter()

    private var lastSearchAt: Date?

    public func allowSearch(minimumInterval: TimeInterval = WebSearchClient.minimumIntervalBetweenSearches) -> Bool {
        if let last = lastSearchAt, Date().timeIntervalSince(last) < minimumInterval {
            return false
        }
        lastSearchAt = Date()
        return true
    }

    public func reset() {
        lastSearchAt = nil
    }
}
