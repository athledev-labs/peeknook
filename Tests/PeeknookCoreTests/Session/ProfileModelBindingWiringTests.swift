// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// Per-profile model binding resolution: binding wins over global, the endpoint derives from the
/// binding's own backend, and built-ins fall back to global everywhere.
@MainActor
final class ProfileModelBindingWiringTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "peeknook.tests.profileBinding")!
        defaults.removePersistentDomain(forName: "peeknook.tests.profileBinding")
    }

    private func settingsFixture() -> PeeknookSettings {
        var settings = PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e4b")
        settings.openAICompatibleBaseURL = "http://127.0.0.1:1234"
        return settings
    }

    private func boundProfile(_ binding: ProfileModelBinding?) -> GroundProfile {
        GroundProfile(
            id: "u-bound", displayNameKey: "Screen", symbol: "macwindow",
            primaryGround: .screen, activeGrounds: [.screen], isBuiltIn: false,
            displayName: "Bound", modelBinding: binding
        )
    }

    func testActiveAnswerModelFallsBackToGlobalWhenUnbound() {
        let settings = settingsFixture()
        XCTAssertEqual(settings.answerModel(for: .screenDefault), settings.answerModel)
        XCTAssertEqual(settings.endpoint(for: .screenDefault), settings.activeEndpoint)
    }

    func testEmptyTagBindingFallsBackToGlobal() {
        let settings = settingsFixture()
        let profile = boundProfile(ProfileModelBinding(backend: .openAICompatible, tag: "   "))
        XCTAssertEqual(settings.answerModel(for: profile), settings.answerModel)
        XCTAssertEqual(settings.endpoint(for: profile), settings.activeEndpoint)
    }

    func testEndpointDerivesFromBindingBackendNotGlobal() {
        let settings = settingsFixture()
        XCTAssertEqual(settings.answerBackend, .ollama, "Global stays Ollama in this fixture.")
        let profile = boundProfile(ProfileModelBinding(backend: .openAICompatible, tag: "qwen2-vl"))
        XCTAssertEqual(
            settings.endpoint(for: profile),
            .openAICompatible(
                baseURL: "http://127.0.0.1:1234",
                apiKeyRef: .openAICompatiblePrimary,
                acceptInsecureRemote: false
            ),
            "The bound model must ship to ITS backend's server, never the global backend's."
        )
        XCTAssertEqual(settings.answerModel(for: profile).tag, "qwen2-vl")
    }

    func testOrchestratorResolvesEngineAndRequestThroughBinding() async throws {
        let engine = ScriptedEngine(responsesPerCall: [["ok"]])
        let orchestrator = SessionOrchestrator(
            settings: settingsFixture(),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "hello")]),
            inference: engine
        )
        let store = ProfileStore(defaults: defaults)
        orchestrator.profileStore = store
        let copy = try XCTUnwrap(store.duplicate(.screenDefault, name: "Bound"))
        store.update(copy.with(
            displayName: copy.displayName,
            instruction: nil,
            promptTemplate: nil,
            modelBinding: ProfileModelBinding(backend: .openAICompatible, tag: "qwen2-vl"),
            moduleOverrides: .none
        ))
        orchestrator.settings.activeProfileID = copy.id

        XCTAssertEqual(orchestrator.activeAnswerModel.tag, "qwen2-vl")
        XCTAssertEqual(orchestrator.activeInferenceEndpoint.backend, .openAICompatible)

        orchestrator.beginCapture()
        _ = await orchestrator.waitForResult("ok")
        let request = try XCTUnwrap(engine.requests.first)
        XCTAssertEqual(request.model, "qwen2-vl")
        XCTAssertEqual(request.endpoint.backend, .openAICompatible)
    }

    func testUsageRecordsBoundTag() async throws {
        let engine = ScriptedEngine(responsesPerCall: [["ok"]])
        engine.inferenceStats = InferenceStats(promptTokens: 5, responseTokens: 2, generationSeconds: 0.1)
        let orchestrator = SessionOrchestrator(
            settings: settingsFixture(),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "hello")]),
            inference: engine
        )
        let store = ProfileStore(defaults: defaults)
        orchestrator.profileStore = store
        let usage = UsageStore(defaults: defaults)
        orchestrator.usage = usage
        let copy = try XCTUnwrap(store.duplicate(.screenDefault, name: "Bound"))
        store.update(copy.with(
            displayName: copy.displayName,
            instruction: nil,
            promptTemplate: nil,
            modelBinding: ProfileModelBinding(backend: .ollama, tag: "llava:13b"),
            moduleOverrides: .none
        ))
        orchestrator.settings.activeProfileID = copy.id

        orchestrator.beginCapture()
        _ = await orchestrator.waitForResult("ok")
        XCTAssertEqual(usage.stats.events.last?.modelTag, "llava:13b")
    }
}
