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
}
