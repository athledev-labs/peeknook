// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest
@testable import PeeknookCore

@MainActor
final class SessionOrchestratorModelResidencyTests: XCTestCase {
    override func tearDown() {
        OllamaURLProtocolStub.responsesByPath = [:]
        super.tearDown()
    }

    /// A real `OllamaInferenceEngine` whose `/api/ps` probe is stubbed, so residency rides the
    /// engine protocol (not an injected setup client) while the same `/api/ps` JSON fixtures stay
    /// exercised end to end.
    private func stubbedOllamaEngine() -> OllamaInferenceEngine {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OllamaURLProtocolStub.self]
        return OllamaInferenceEngine(session: URLSession(configuration: config))
    }

    private func makeOrchestrator(_ engine: InferenceEngine = ScriptedEngine(responsesPerCall: [["ok"]])) -> SessionOrchestrator {
        SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e4b"),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "hello")]),
            inference: engine
        )
    }

    private func stubRunningModel(_ name: String = "gemma4:e4b") {
        let json = #"{"models":[{"name":"\#(name)","size":1000}]}"#
        OllamaURLProtocolStub.responsesByPath["/api/ps"] = [
            .init(
                statusCode: 200,
                body: Data(json.utf8),
                headers: ["Content-Type": "application/json"]
            ),
        ]
    }

    func testRefreshModelResidencyDetectsLoadedModelAfterRelaunch() async {
        stubRunningModel()
        let orchestrator = makeOrchestrator(stubbedOllamaEngine())

        XCTAssertFalse(orchestrator.modelLikelyWarm)
        await orchestrator.refreshActiveModelResidency()
        XCTAssertTrue(orchestrator.modelLikelyWarm, "Ollama /api/ps should mark the active model warm after relaunch")
    }

    func testRefreshModelResidencyRequiresTagAwareMatch() async {
        stubRunningModel("gemma4:e2b")
        let orchestrator = makeOrchestrator(stubbedOllamaEngine())

        await orchestrator.refreshActiveModelResidency()
        XCTAssertFalse(orchestrator.modelLikelyWarm, "e2b loaded must not satisfy e4b request")
    }

    func testPrewarmSkipsWarmUpWhenModelAlreadyResident() async {
        let engine = ScriptedEngine(responsesPerCall: [["ok"]])
        engine.residentModels = ["gemma4:e4b"]
        let orchestrator = makeOrchestrator(engine)

        orchestrator.prewarm()
        await orchestrator.waitForPrewarmComplete()

        XCTAssertTrue(orchestrator.modelLikelyWarm)
        XCTAssertEqual(engine.warmUpCallCount, 0, "resident model should not trigger warmUp")
    }

    func testRunTurnSnapshotsWarmLabelFromResidency() async {
        let engine = ScriptedEngine(responsesPerCall: [["warm"]], tokenDelayNanoseconds: 200_000_000)
        engine.residentModels = ["gemma4:e4b"]
        let orchestrator = makeOrchestrator(engine)
        orchestrator.conversation = [
            ChatTurn(id: 1, kind: .assistant("prior")),
        ]
        _ = orchestrator.applyPhaseEvent(.openThreadRestored(answer: "prior"))

        orchestrator.sendFollowUp("follow up")
        let sawWarm = await orchestrator.waitUntil(timeout: 2) {
            orchestrator.phase == .inferring && orchestrator.inferenceModelWasWarm
        }

        XCTAssertTrue(sawWarm)
        orchestrator.cancel()
    }

    func testNonResidentEngineLeavesWarmGateOnTimerOnly() async {
        // An engine that can't report residency (nil) must not fake a warm model; the warm gate then
        // rides only the in-session lastInferenceAt timer, which is cold before any turn.
        let engine = ScriptedEngine(responsesPerCall: [["ok"]]) // residentModels nil by default
        let orchestrator = makeOrchestrator(engine)

        await orchestrator.refreshActiveModelResidency()
        XCTAssertFalse(orchestrator.modelLikelyWarm, "unknown residency must not mark the model warm")
    }
}
