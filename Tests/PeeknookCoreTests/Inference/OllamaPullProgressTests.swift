// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

final class OllamaPullProgressTests: XCTestCase {
    func testPullPhaseMapsOllamaVerbs() {
        XCTAssertEqual(PullPhase.from(ollamaStatus: "pulling manifest"), .preparing)
        XCTAssertEqual(PullPhase.from(ollamaStatus: "pulling 4c27e0f5b5ad"), .downloading)
        XCTAssertEqual(PullPhase.from(ollamaStatus: "verifying sha256 digest"), .verifying)
        XCTAssertEqual(PullPhase.from(ollamaStatus: "writing manifest"), .finishing)
        XCTAssertEqual(PullPhase.from(ollamaStatus: "removing any unused layers"), .finishing)
        XCTAssertEqual(PullPhase.from(ollamaStatus: "something new"), .preparing, "Unknown verbs degrade to preparing.")
    }

    func testPullProgressAggregatesAcrossLayersAndCompletes() async throws {
        let ndjson = [
            #"{"status":"pulling manifest"}"#,
            #"{"status":"pulling a","digest":"a","total":100,"completed":0}"#,
            #"{"status":"pulling b","digest":"b","total":100,"completed":0}"#,
            #"{"status":"pulling a","digest":"a","total":100,"completed":100}"#,
            #"{"status":"pulling b","digest":"b","total":100,"completed":100}"#,
            #"{"status":"verifying sha256 digest"}"#,
            #"{"status":"writing manifest"}"#,
            #"{"status":"success"}"#,
        ].joined(separator: "\n")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OllamaURLProtocolStub.self]
        let session = URLSession(configuration: config)
        OllamaURLProtocolStub.responsesByPath = [
            "/api/pull": [.init(statusCode: 200, body: Data(ndjson.utf8), headers: [:])]
        ]
        defer { OllamaURLProtocolStub.responsesByPath = [:] }

        let client = OllamaSetupClient(session: session)
        var events: [OllamaPullEvent] = []
        for try await event in client.pullModel(baseURL: "http://127.0.0.1:11434", model: "gemma4:e4b") {
            events.append(event)
        }

        // Final event is the terminal completion.
        XCTAssertEqual(events.last, .completed)

        // Aggregated fraction is non-decreasing (summed over known layers) and reaches 1.0.
        let fractions = events.compactMap { event -> Double? in
            if case .progress(let p) = event { return p.fraction }
            return nil
        }
        XCTAssertEqual(fractions, fractions.sorted(), "Aggregated fraction must not jump backward across this layer sequence.")
        let lastFraction = try XCTUnwrap(fractions.last)
        XCTAssertEqual(lastFraction, 1.0, accuracy: 0.0001, "Both layers complete → 100%.")

        // The friendly phases all appear, never a raw digest.
        let phases = events.compactMap { event -> PullPhase? in
            if case .progress(let p) = event { return p.phase }
            return nil
        }
        XCTAssertTrue(phases.contains(.preparing))
        XCTAssertTrue(phases.contains(.downloading))
        XCTAssertTrue(phases.contains(.verifying))
        XCTAssertTrue(phases.contains(.finishing))
    }
}
