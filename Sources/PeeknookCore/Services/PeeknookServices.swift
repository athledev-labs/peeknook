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
        public let storageFootprint: any StorageFootprinting
    }

    @MainActor
    public static func makeStack(
        settings: PeeknookSettings,
        defaults: UserDefaults,
        dependencies: PeeknookDependencies = .production()
    ) -> Stack {
        var settings = settings
        let setup = SetupCoordinator(settings: settings, defaults: defaults)
        setup.applyRecommendedModelIfNeeded()
        settings = setup.settings

        let usage = UsageStore(defaults: defaults)
        let orchestrator = SessionOrchestrator(
            settings: settings,
            capture: dependencies.capture,
            inference: dependencies.inference,
            webLookup: dependencies.webLookup,
            speechRecognizer: dependencies.speechRecognizer,
            speechSynthesizer: dependencies.answerSpeechSynthesizer,
            previewSpeechSynthesizer: dependencies.previewSpeechSynthesizer
        )
        orchestrator.setup = setup
        orchestrator.usage = usage
        if let archive = dependencies.conversationArchive {
            orchestrator.conversationArchive = archive
            orchestrator.captureBlobStore = archive.blobStore
        } else {
            do {
                let archive = try ConversationArchiveStore.makeDefault()
                orchestrator.conversationArchive = archive
                orchestrator.captureBlobStore = archive.blobStore
            } catch {
                orchestrator.conversationArchive = nil
                orchestrator.captureBlobStore = nil
                if settings.persistConversation {
                    orchestrator.reportArchiveBootstrapFailure(.keyUnavailable)
                }
            }
        }
        orchestrator.loadPersistedConversationIfEnabled()
        setup.orchestrator = orchestrator
        let settingsController = PeekSettingsController(
            orchestrator: orchestrator,
            setup: setup,
            defaults: defaults,
            inference: dependencies.inference
        )
        let storageFootprint = StorageFootprintService(archive: orchestrator.conversationArchive)
        return Stack(
            orchestrator: orchestrator,
            setup: setup,
            usage: usage,
            settings: settingsController,
            modelCatalog: dependencies.modelCatalog,
            storageFootprint: storageFootprint
        )
    }

    @MainActor
    public static func makeOrchestrator(settings: PeeknookSettings) -> SessionOrchestrator {
        makeStack(settings: settings, defaults: .standard).orchestrator
    }

}
