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
        #if canImport(Speech) && canImport(AVFoundation)
        let speechRecognizer: any SpeechRecognizing = AppleSpeechRecognizer()
        let speechSynthesizer: any SpeechSynthesizing = AppleSpeechSynthesizer()
        #else
        let speechRecognizer: any SpeechRecognizing = StubSpeechRecognizer()
        let speechSynthesizer: any SpeechSynthesizing = StubSpeechSynthesizer()
        #endif
        let orchestrator = SessionOrchestrator(
            settings: settings,
            capture: MacCaptureProvider(),
            inference: inference,
            speechRecognizer: speechRecognizer,
            speechSynthesizer: speechSynthesizer
        )
        orchestrator.setup = setup
        orchestrator.usage = usage
        orchestrator.conversationArchive = ConversationArchiveStore.makeDefault()
        orchestrator.loadPersistedConversationIfEnabled()
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
