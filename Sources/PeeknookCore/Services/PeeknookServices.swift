// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Wires production capture + Ollama inference from saved settings.
public enum PeeknookServices {
    public struct Stack {
        public let orchestrator: SessionOrchestrator
        public let setup: SetupCoordinator
        public let usage: UsageStore
        public let settings: PeekSettingsController
        public let modelCatalog: ModelCatalogService
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
        let answerSpeechSynthesizer: any SpeechSynthesizing = AppleSpeechSynthesizer()
        let previewSpeechSynthesizer: any SpeechSynthesizing = AppleSpeechSynthesizer()
        #else
        let speechRecognizer: any SpeechRecognizing = StubSpeechRecognizer()
        let answerSpeechSynthesizer: any SpeechSynthesizing = StubSpeechSynthesizer()
        let previewSpeechSynthesizer: any SpeechSynthesizing = StubSpeechSynthesizer()
        #endif
        let orchestrator = SessionOrchestrator(
            settings: settings,
            capture: MacCaptureProvider(),
            inference: inference,
            speechRecognizer: speechRecognizer,
            speechSynthesizer: answerSpeechSynthesizer,
            previewSpeechSynthesizer: previewSpeechSynthesizer
        )
        orchestrator.setup = setup
        orchestrator.usage = usage
        do {
            orchestrator.conversationArchive = try ConversationArchiveStore.makeDefault()
        } catch {
            orchestrator.conversationArchive = nil
            if settings.persistConversation {
                orchestrator.reportArchiveBootstrapFailure(.keyUnavailable)
            }
        }
        orchestrator.loadPersistedConversationIfEnabled()
        setup.orchestrator = orchestrator
        let settingsController = PeekSettingsController(
            orchestrator: orchestrator,
            setup: setup,
            defaults: defaults,
            inference: inference
        )
        let modelCatalog = ModelCatalogService.makeDefault()
        return Stack(
            orchestrator: orchestrator,
            setup: setup,
            usage: usage,
            settings: settingsController,
            modelCatalog: modelCatalog
        )
    }

    @MainActor
    public static func makeOrchestrator(settings: PeeknookSettings) -> SessionOrchestrator {
        makeStack(settings: settings, defaults: .standard).orchestrator
    }
}
