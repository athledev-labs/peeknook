// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

final class WebLookupRunnerTests: XCTestCase {
    private let sampleCapture = CaptureResult(
        text: "swift actors",
        sourceLabel: "Front window (vision)",
        appName: "Safari",
        windowTitle: "Docs",
        screenshotBase64: "x"
    )

    override func tearDown() async throws {
        await WebSearchRateLimiter.shared.reset()
        try await super.tearDown()
    }

    func testOrganicNoResultsIsNotLookupFailed() async {
        let client = WebSearchClient(searchHook: { _, _ in throw WebSearchError.noResults })
        let runner = WebLookupRunner(client: client)

        let snapshot = await runner.lookup(capture: sampleCapture)

        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.query, "swift actors")
        XCTAssertTrue(snapshot?.results.isEmpty == true)
        XCTAssertFalse(snapshot?.lookupFailed == true)
        XCTAssertNil(snapshot?.lookupFailure)
    }

    func testUnavailableMapsToLookupFailure() async {
        let client = WebSearchClient(searchHook: { _, _ in throw WebSearchError.unavailable })
        let runner = WebLookupRunner(client: client)

        let snapshot = await runner.lookup(capture: sampleCapture)

        XCTAssertEqual(snapshot?.lookupFailed, true)
        XCTAssertEqual(snapshot?.lookupFailure, .unavailable)
    }

    func testRateLimitRegressionSkipsSecondSearch() async {
        var searchCalls = 0
        let client = WebSearchClient(searchHook: { _, _ in
            searchCalls += 1
            return [WebSearchResult(title: "Hit", url: URL(string: "https://example.com")!, snippet: "")]
        })
        let runner = WebLookupRunner(client: client)

        let first = await runner.lookup(capture: sampleCapture)
        let second = await runner.lookup(capture: sampleCapture)

        XCTAssertEqual(searchCalls, 1)
        XCTAssertFalse(first?.lookupFailed == true)
        XCTAssertEqual(second?.lookupFailure, .rateLimited)
        XCTAssertEqual(second?.lookupFailed, true)
    }

    func testSensitiveContentBlockedWithoutSearch() async {
        let capture = CaptureResult(
            text: "sk-live-abcdefghijklmnopqrstuvwxyz",
            sourceLabel: "Front window (vision)",
            screenshotBase64: "x"
        )
        var searchCalls = 0
        let client = WebSearchClient(searchHook: { _, _ in
            searchCalls += 1
            return []
        })
        let runner = WebLookupRunner(client: client)

        let snapshot = await runner.lookup(capture: capture)

        XCTAssertEqual(searchCalls, 0)
        XCTAssertEqual(snapshot?.lookupFailure, .sensitiveContent)
        XCTAssertEqual(snapshot?.lookupFailed, true)
    }
}
