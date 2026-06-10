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

    private func stubbedOllamaClient() -> OllamaSetupClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OllamaURLProtocolStub.self]
        return OllamaSetupClient(session: URLSession(configuration: config))
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
        let orchestrator = makeOrchestrator()
        orchestrator._ollamaResidencyClient = stubbedOllamaClient()

        XCTAssertFalse(orchestrator.modelLikelyWarm)
        await orchestrator.refreshActiveModelResidency()
        XCTAssertTrue(orchestrator.modelLikelyWarm, "Ollama /api/ps should mark the active model warm after relaunch")
    }

    func testRefreshModelResidencyRequiresTagAwareMatch() async {
        stubRunningModel("gemma4:e2b")
        let orchestrator = makeOrchestrator()
        orchestrator._ollamaResidencyClient = stubbedOllamaClient()

        await orchestrator.refreshActiveModelResidency()
        XCTAssertFalse(orchestrator.modelLikelyWarm, "e2b loaded must not satisfy e4b request")
    }

    func testPrewarmSkipsWarmUpWhenModelAlreadyResident() async {
        stubRunningModel()
        let engine = ScriptedEngine(responsesPerCall: [["ok"]])
        let orchestrator = makeOrchestrator(engine)
        orchestrator._ollamaResidencyClient = stubbedOllamaClient()

        orchestrator.prewarm()
        await orchestrator.waitForPrewarmComplete()

        XCTAssertTrue(orchestrator.modelLikelyWarm)
        XCTAssertEqual(engine.warmUpCallCount, 0, "resident model should not trigger warmUp")
    }

    func testRunTurnSnapshotsWarmLabelFromOllamaPs() async {
        stubRunningModel()
        let engine = ScriptedEngine(responsesPerCall: [["warm"]], tokenDelayNanoseconds: 200_000_000)
        let orchestrator = makeOrchestrator(engine)
        orchestrator._ollamaResidencyClient = stubbedOllamaClient()
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
}
