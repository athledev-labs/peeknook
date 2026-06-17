// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

final class WebSearchClientTests: XCTestCase {
    func testHTMLParsingExtractsTitleURLAndSnippet() {
        let html = """
        <a class="result__a" href="https://example.com/page">Example Title</a>
        <span class="result__snippet">A helpful snippet about the page.</span>
        <a class="result__a" href="https://docs.swift.org/swift-book/">Swift Book</a>
        <span class="result__snippet">Official Swift documentation.</span>
        """
        let results = WebSearchClient.parseHTMLResults(html, limit: 4)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].title, "Example Title")
        XCTAssertEqual(results[0].url.absoluteString, "https://example.com/page")
        XCTAssertEqual(results[0].snippet, "A helpful snippet about the page.")
        XCTAssertEqual(results[1].title, "Swift Book")
    }

    func testQueryPrefersSelectedText() {
        let capture = CaptureResult(
            text: "What is a monad?\nExtra lines ignored for query.",
            sourceLabel: "Front window (vision)",
            appName: "Safari",
            windowTitle: "Haskell Wiki",
            screenshotBase64: "x"
        )
        XCTAssertEqual(WebSearchClient.query(from: capture), "What is a monad?")
    }

    func testQueryFallsBackToWindowTitle() {
        let capture = CaptureResult(
            text: nil,
            sourceLabel: "Front window (vision)",
            appName: "Safari",
            windowTitle: "Swift Programming Language",
            screenshotBase64: "x"
        )
        XCTAssertEqual(WebSearchClient.query(from: capture), "Swift Programming Language")
    }

    func testPromptContextIncludesTopResults() {
        let snapshot = WebLookupSnapshot(
            query: "swift actors",
            results: [
                WebSearchResult(title: "Actors", url: URL(string: "https://example.com")!, snippet: "Concurrency model")
            ]
        )
        let context = WebSearchClient.promptContext(from: snapshot)
        XCTAssertTrue(context.contains("swift actors"))
        XCTAssertTrue(context.contains("Actors"))
        XCTAssertTrue(context.contains("https://example.com"))
    }

    func testWebLookupEnabledDefaultsFalseAndRoundTrips() throws {
        let legacy = Data(#"{"mode":"general","textModel":"gemma4:e4b"}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(PeeknookSettings.self, from: legacy).webLookupEnabled)

        let on = PeeknookSettings(textModel: "gemma4:e4b", webLookupEnabled: true)
        XCTAssertTrue(try JSONDecoder().decode(PeeknookSettings.self, from: JSONEncoder().encode(on)).webLookupEnabled)
    }
}

/// Records the request URL and returns a canned 200 body so catalog tests can assert the honored
/// host without any real network egress.
final class CatalogURLProtocolStub: URLProtocol {
    static var recordedURLs: [URL] = []
    static var body = Data("{\"pages\":[],\"tags\":[]}".utf8)
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let url = request.url {
            Self.lock.lock()
            Self.recordedURLs.append(url)
            Self.lock.unlock()
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class OllamaCatalogClientTests: XCTestCase {
    func testVisionHeuristicMatchesKnownFamilies() {
        XCTAssertTrue(OllamaCatalogClient.likelySupportsVision(modelID: "library/gemma4"))
        XCTAssertTrue(OllamaCatalogClient.likelySupportsVision(modelID: "library/qwen2.5", tags: ["qwen2.5-vl:7b"]))
        XCTAssertFalse(OllamaCatalogClient.likelySupportsVision(modelID: "library/llama3.2"))
    }

    func testCloudTagDetection() {
        XCTAssertTrue(OllamaCatalogClient.isCloudTag("nemotron-3-ultra:cloud"))
        XCTAssertFalse(OllamaCatalogClient.isCloudTag("gemma4:e4b"))
    }

    func testDefaultCatalogBaseURLIsPinned() {
        XCTAssertEqual(
            OllamaCatalogClient.defaultCatalogBaseURL,
            "https://ollama-models-api.devcomfort.workers.dev"
        )
    }

    func testInjectedBaseURLIsHonoredForSearchAndTags() async throws {
        CatalogURLProtocolStub.recordedURLs = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CatalogURLProtocolStub.self]
        let client = OllamaCatalogClient(session: URLSession(configuration: config), baseURL: "https://example.test")

        _ = try await client.search(query: "gemma")
        _ = try await client.tags(for: "gemma4")

        XCTAssertEqual(CatalogURLProtocolStub.recordedURLs.count, 2)
        XCTAssertEqual(CatalogURLProtocolStub.recordedURLs[0].host, "example.test")
        XCTAssertEqual(CatalogURLProtocolStub.recordedURLs[0].path, "/search")
        XCTAssertEqual(CatalogURLProtocolStub.recordedURLs[1].host, "example.test")
        XCTAssertEqual(CatalogURLProtocolStub.recordedURLs[1].path, "/model")
    }
}

final class CatalogBaseURLSettingTests: XCTestCase {
    func testCatalogBaseURLDefaultsEmptyAndResolvesToBuiltInDefault() throws {
        let legacy = Data(#"{"mode":"general","textModel":"gemma4:e4b"}"#.utf8)
        let decoded = try JSONDecoder().decode(PeeknookSettings.self, from: legacy)
        XCTAssertEqual(decoded.catalogBaseURL, "")
        XCTAssertEqual(decoded.resolvedCatalogBaseURL, OllamaCatalogClient.defaultCatalogBaseURL)
    }

    func testCatalogBaseURLRoundTripsAndResolves() throws {
        let custom = PeeknookSettings(textModel: "gemma4:e4b", catalogBaseURL: "https://catalog.example")
        let decoded = try JSONDecoder().decode(
            PeeknookSettings.self,
            from: JSONEncoder().encode(custom)
        )
        XCTAssertEqual(decoded.catalogBaseURL, "https://catalog.example")
        XCTAssertEqual(decoded.resolvedCatalogBaseURL, "https://catalog.example")
    }

    func testResolvedCatalogBaseURLTreatsWhitespaceAsDefault() {
        let blank = PeeknookSettings(textModel: "gemma4:e4b", catalogBaseURL: "   ")
        XCTAssertEqual(blank.resolvedCatalogBaseURL, OllamaCatalogClient.defaultCatalogBaseURL)
    }
}
