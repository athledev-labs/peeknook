// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Wires production capture + Ollama inference from saved settings.
public enum PeeknookServices {
    public struct Stack {
        public let orchestrator: SessionOrchestrator
        public let setup: SetupCoordinator
        public let usage: UsageStore
        public let settings: PeekSettingsController
    }

    @MainActor
    public static func makeStack(settings: PeeknookSettings, defaults: UserDefaults) -> Stack {
        var settings = settings
        let setup = SetupCoordinator(settings: settings, defaults: defaults)
        setup.applyRecommendedModelIfNeeded()
        settings = setup.settings

        let usage = UsageStore(defaults: defaults)
        let inference = OllamaInferenceEngine()
        let orchestrator = SessionOrchestrator(
            settings: settings,
            capture: MacCaptureProvider(),
            inference: inference
        )
        orchestrator.setup = setup
        orchestrator.usage = usage
        setup.orchestrator = orchestrator
        let settingsController = PeekSettingsController(
            orchestrator: orchestrator,
            setup: setup,
            defaults: defaults,
            inference: inference
        )
        return Stack(
            orchestrator: orchestrator,
            setup: setup,
            usage: usage,
            settings: settingsController
        )
    }

    @MainActor
    public static func makeOrchestrator(settings: PeeknookSettings) -> SessionOrchestrator {
        makeStack(settings: settings, defaults: .standard).orchestrator
    }
}
