// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// Setup stays Ollama-only by design: on a non-Ollama backend the Ollama/model steps
/// short-circuit to complete (the user runs their own server), readiness reduces to permissions,
/// and the recommended-model seeding never touches `textModel`.
@MainActor
final class SetupCoordinatorBackendTests: XCTestCase {
    private func makeCoordinator(
        settings: PeeknookSettings,
        suite: String
    ) -> SetupCoordinator {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return SetupCoordinator(
            settings: settings,
            defaults: defaults,
            permissionStatus: {
                CapturePermissionStatus(accessibilityTrusted: false, screenRecordingGranted: true)
            }
        )
    }

    func testRefreshShortCircuitsOllamaStepsForOpenAICompatible() async {
        var settings = PeeknookSettings()
        settings.answerBackend = .openAICompatible
        // A dead Ollama URL proves no probe happens: a real probe would fail the step.
        settings.ollamaBaseURL = "http://127.0.0.1:1"
        let setup = makeCoordinator(settings: settings, suite: "peeknook.tests.setup-backend-refresh")

        await setup.refresh()

        XCTAssertEqual(setup.ollamaStep, .complete)
        XCTAssertEqual(setup.modelStep, .complete)
    }

    func testReadinessForOpenAICompatibleDoesNotRequireOllama() async {
        var settings = PeeknookSettings()
        settings.answerBackend = .openAICompatible
        settings.ollamaBaseURL = "http://127.0.0.1:1"
        let setup = makeCoordinator(settings: settings, suite: "peeknook.tests.setup-backend-ready")

        await setup.refresh()

        XCTAssertTrue(
            setup.isReady,
            "With the OpenAI-compatible backend, readiness is permissions-only — a dead Ollama must not block."
        )
    }

    func testApplyRecommendedModelSkipsNonOllamaBackend() {
        var settings = PeeknookSettings()
        settings.answerBackend = .openAICompatible
        settings.textModel = ""
        let setup = makeCoordinator(settings: settings, suite: "peeknook.tests.setup-backend-seed")

        setup.applyRecommendedModelIfNeeded()

        XCTAssertEqual(setup.settings.textModel, "", "No Gemma tag may be seeded while off-Ollama.")
    }

    func testApplyRecommendedModelStillSeedsForOllama() {
        var settings = PeeknookSettings()
        settings.textModel = ""
        let setup = makeCoordinator(settings: settings, suite: "peeknook.tests.setup-backend-seed-ollama")

        setup.applyRecommendedModelIfNeeded()

        XCTAssertFalse(setup.settings.textModel.isEmpty, "Ollama first-run seeding must keep working.")
    }
}
