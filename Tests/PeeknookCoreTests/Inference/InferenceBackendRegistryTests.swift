// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

final class InferenceBackendRegistryTests: XCTestCase {
    func testResolvesEngineForEachBackend() {
        let registry = InferenceBackendRegistry([
            .ollama: MarkerEngine(name: "ollama"),
            .openAICompatible: MarkerEngine(name: "openai"),
        ])
        XCTAssertEqual((registry.engine(for: .ollama) as? MarkerEngine)?.name, "ollama")
        XCTAssertEqual((registry.engine(for: .openAICompatible) as? MarkerEngine)?.name, "openai")
    }

    func testEngineForEndpointDelegatesToBackend() {
        let registry = InferenceBackendRegistry([
            .ollama: MarkerEngine(name: "ollama"),
            .openAICompatible: MarkerEngine(name: "openai"),
        ])
        let endpoint = InferenceEndpoint.openAICompatible(
            baseURL: "http://127.0.0.1:1234",
            apiKeyRef: .openAICompatiblePrimary,
            acceptInsecureRemote: false
        )
        XCTAssertEqual((registry.engine(for: endpoint) as? MarkerEngine)?.name, "openai")
    }

    func testUniformRegistersOneEngineForAllBackends() {
        let registry = InferenceBackendRegistry.uniform(MarkerEngine(name: "shared"))
        for backend in InferenceBackend.allCases {
            XCTAssertEqual((registry.engine(for: backend) as? MarkerEngine)?.name, "shared")
        }
    }

    /// The orchestrator resolves its engine through the registry per `answerModel.backend` —
    /// default settings (Ollama) must route to the Ollama-registered engine.
    @MainActor
    func testOrchestratorResolvesOllamaEngineForDefaultSettings() {
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "x")]),
            inferenceRegistry: InferenceBackendRegistry([
                .ollama: MarkerEngine(name: "ollama"),
                .openAICompatible: MarkerEngine(name: "openai"),
            ])
        )
        XCTAssertEqual((orchestrator.inference as? MarkerEngine)?.name, "ollama")
    }
}

private struct MarkerEngine: InferenceEngine {
    let name: String

    func health(baseURL: String, model: String, acceptInsecureRemote: Bool) async -> InferenceHealth { .ready }

    func stream(request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func warmUp(model: String, baseURL: String, acceptInsecureRemote: Bool) async -> Bool { true }

    func contextLength(model: String, baseURL: String, acceptInsecureRemote: Bool) async -> Int? { nil }

    func capabilities(model: String, baseURL: String, acceptInsecureRemote: Bool) async -> [String]? { nil }
}
