// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

final class VisionGateTests: XCTestCase {
    private let endpoint = InferenceEndpoint.ollama(
        baseURL: "http://127.0.0.1:11434",
        acceptInsecureRemote: false
    )

    private func gate(
        capabilities: [String]?,
        likelyVision: @escaping @Sendable (String) -> Bool = { _ in false }
    ) -> VisionGate {
        VisionGate(
            inference: StubVisionEngine(capabilitiesResult: capabilities),
            likelyVision: likelyVision
        )
    }

    func testVisionCapabilityIsReady() async {
        let result = await gate(capabilities: ["completion", "vision"])
            .readiness(of: "gemma4:e4b", endpoint: endpoint)
        XCTAssertEqual(result, .ready)
    }

    func testNoVisionCapabilityIsTextOnly() async {
        let result = await gate(capabilities: ["completion"])
            .readiness(of: "llama3:8b", endpoint: endpoint)
        XCTAssertEqual(result, .textOnly)
    }

    func testUnknownCapabilityNeverBlocks() async {
        // Live probe returns nil (not installed / older runtime) and the heuristic also misses.
        let result = await gate(capabilities: nil, likelyVision: { _ in false })
            .readiness(of: "mystery:1b", endpoint: endpoint)
        XCTAssertEqual(result, .unknown, "An uninstalled / unprobeable model must not be blocked.")
    }

    func testUninstalledButHeuristicVisionIsReadyNotTextOnly() async {
        // Pre-install: live probe nil, heuristic says vision → ready (never textOnly).
        let result = await gate(capabilities: nil, likelyVision: { $0.contains("gemma4") })
            .readiness(of: "gemma4:e2b", endpoint: endpoint)
        XCTAssertEqual(result, .ready)
    }

    func testLiveCapabilityWinsOverHeuristic() async {
        // Live /api/show says no vision; the heuristic would say vision. Authoritative live wins.
        let result = await gate(capabilities: ["completion"], likelyVision: { _ in true })
            .readiness(of: "gemma4:e2b", endpoint: endpoint)
        XCTAssertEqual(result, .textOnly, "Authoritative /api/show must override the name heuristic.")
    }

    func testEmptyTagIsUnknown() async {
        let result = await gate(capabilities: ["vision"])
            .readiness(of: "   ", endpoint: endpoint)
        XCTAssertEqual(result, .unknown)
    }

    /// An OpenAI-compatible server reports no capability metadata (`capabilities` is nil) — the
    /// gate must degrade to `.unknown` and never false-block capture on that backend, same as an
    /// uninstalled Ollama model.
    func testOpenAICompatibleEndpointWithNilCapabilitiesIsUnknownNeverTextOnly() async {
        let openAI = InferenceEndpoint.openAICompatible(
            baseURL: "http://127.0.0.1:1234",
            apiKeyRef: .openAICompatiblePrimary,
            acceptInsecureRemote: false
        )
        let result = await gate(capabilities: nil, likelyVision: { _ in false })
            .readiness(of: "qwen2-vl-7b-instruct", endpoint: openAI)
        XCTAssertEqual(result, .unknown, "Unverifiable backend must not block capture.")
    }
}

/// Configurable `InferenceEngine` double — the shipped `MockInferenceEngine` always reports `nil`
/// capabilities, so it can't exercise the `.ready` / `.textOnly` branches.
private struct StubVisionEngine: InferenceEngine {
    var capabilitiesResult: [String]?

    func health(baseURL: String, model: String, acceptInsecureRemote: Bool) async -> InferenceHealth { .ready }

    func stream(request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func warmUp(model: String, baseURL: String, acceptInsecureRemote: Bool) async -> Bool { true }

    func contextLength(model: String, baseURL: String, acceptInsecureRemote: Bool) async -> Int? { nil }

    func capabilities(model: String, baseURL: String, acceptInsecureRemote: Bool) async -> [String]? {
        capabilitiesResult
    }
}
