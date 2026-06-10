// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// The endpoint-typed engine methods are pure adapters over the `baseURL: String` requirements —
/// these tests pin that decomposition so a refactor can't silently drop the insecure flag.
final class EndpointTypedOverloadTests: XCTestCase {
    private let endpoint = InferenceEndpoint.openAICompatible(
        baseURL: "http://127.0.0.1:1234",
        apiKeyRef: .openAICompatiblePrimary,
        acceptInsecureRemote: true
    )

    func testHealthEndpointOverloadDecomposesToStringRequirement() async {
        let engine = RecordingEngine()
        _ = await engine.health(endpoint: endpoint, model: "qwen2-vl")
        XCTAssertEqual(engine.calls(), [
            RecordedCall(
                method: "health", model: "qwen2-vl",
                baseURL: "http://127.0.0.1:1234", acceptInsecureRemote: true
            )
        ])
    }

    func testWarmContextCapabilitiesVisionOverloadsForwardConnection() async {
        let engine = RecordingEngine()
        _ = await engine.warmUp(model: "m", endpoint: endpoint)
        _ = await engine.contextLength(model: "m", endpoint: endpoint)
        _ = await engine.capabilities(model: "m", endpoint: endpoint)
        _ = await engine.supportsVision(model: "m", endpoint: endpoint)
        let calls = engine.calls()
        // supportsVision routes through capabilities, so four overloads → four underlying calls.
        XCTAssertEqual(
            calls.map(\.method),
            ["warmUp", "contextLength", "capabilities", "capabilities"]
        )
        for call in calls {
            XCTAssertEqual(call.baseURL, "http://127.0.0.1:1234")
            XCTAssertTrue(call.acceptInsecureRemote)
        }
    }
}

private struct RecordedCall: Equatable {
    var method: String
    var model: String
    var baseURL: String
    var acceptInsecureRemote: Bool
}

private final class RecordingEngine: InferenceEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [RecordedCall] = []

    func calls() -> [RecordedCall] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    private func record(_ call: RecordedCall) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(call)
    }

    func health(baseURL: String, model: String, acceptInsecureRemote: Bool) async -> InferenceHealth {
        record(RecordedCall(
            method: "health", model: model,
            baseURL: baseURL, acceptInsecureRemote: acceptInsecureRemote
        ))
        return .ready
    }

    func stream(request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func warmUp(model: String, baseURL: String, acceptInsecureRemote: Bool) async -> Bool {
        record(RecordedCall(
            method: "warmUp", model: model,
            baseURL: baseURL, acceptInsecureRemote: acceptInsecureRemote
        ))
        return true
    }

    func contextLength(model: String, baseURL: String, acceptInsecureRemote: Bool) async -> Int? {
        record(RecordedCall(
            method: "contextLength", model: model,
            baseURL: baseURL, acceptInsecureRemote: acceptInsecureRemote
        ))
        return nil
    }

    func capabilities(model: String, baseURL: String, acceptInsecureRemote: Bool) async -> [String]? {
        record(RecordedCall(
            method: "capabilities", model: model,
            baseURL: baseURL, acceptInsecureRemote: acceptInsecureRemote
        ))
        return nil
    }
}
