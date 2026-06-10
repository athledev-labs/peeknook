// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

final class ActiveEndpointTests: XCTestCase {
    func testActiveEndpointForOllamaMatchesFromSettings() {
        var settings = PeeknookSettings()
        settings.ollamaBaseURL = "http://127.0.0.1:11434"
        settings.acceptInsecureRemoteOllama = true
        XCTAssertEqual(
            settings.activeEndpoint,
            .ollama(baseURL: "http://127.0.0.1:11434", acceptInsecureRemote: true)
        )
        XCTAssertEqual(settings.activeEndpoint, .from(settings: settings))
    }

    func testActiveEndpointForOpenAICompatibleUsesOverlayFields() {
        var settings = PeeknookSettings()
        settings.answerBackend = .openAICompatible
        settings.openAICompatibleBaseURL = "http://127.0.0.1:1234"
        settings.acceptInsecureRemoteOpenAICompatible = false
        XCTAssertEqual(
            settings.activeEndpoint,
            .openAICompatible(
                baseURL: "http://127.0.0.1:1234",
                apiKeyRef: .openAICompatiblePrimary,
                acceptInsecureRemote: false
            )
        )
    }

    /// Guards the resolved design blocker: after a backend switch, prewarm must warm the server
    /// the next turn actually hits — never the stale Ollama URL.
    @MainActor
    func testPrewarmAfterBackendSwitchTargetsActiveEndpoint() async {
        let engine = WarmUpRecordingEngine()
        var settings = PeeknookSettings()
        settings.answerBackend = .openAICompatible
        settings.openAICompatibleBaseURL = "http://127.0.0.1:1234"
        settings.openAICompatibleModelTag = "qwen2-vl-7b-instruct"
        let orchestrator = SessionOrchestrator(
            settings: settings,
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "x")]),
            inferenceRegistry: .uniform(engine)
        )

        orchestrator.prewarm()
        for _ in 0..<200 {
            if !engine.calls().isEmpty { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(
            engine.calls(),
            [WarmUpCall(model: "qwen2-vl-7b-instruct", baseURL: "http://127.0.0.1:1234")],
            "prewarm must decompose the ACTIVE endpoint, not the Ollama settings fields."
        )
    }
}

private struct WarmUpCall: Equatable {
    var model: String
    var baseURL: String
}

private final class WarmUpRecordingEngine: InferenceEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [WarmUpCall] = []

    func calls() -> [WarmUpCall] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func health(baseURL: String, model: String, acceptInsecureRemote: Bool) async -> InferenceHealth { .ready }

    func stream(request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func warmUp(model: String, baseURL: String, acceptInsecureRemote: Bool) async -> Bool {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(WarmUpCall(model: model, baseURL: baseURL))
        return true
    }

    func contextLength(model: String, baseURL: String, acceptInsecureRemote: Bool) async -> Int? { nil }

    func capabilities(model: String, baseURL: String, acceptInsecureRemote: Bool) async -> [String]? { nil }
}
