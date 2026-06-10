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
        public let profileStore: ProfileStore
    }

    @MainActor
    public static func makeStack(
        settings: PeeknookSettings,
        defaults: UserDefaults,
        dependencies: PeeknookDependencies = .production()
    ) -> Stack {
        var settings = settings
        let profileStore = ProfileStore(defaults: defaults)
        let setup = SetupCoordinator(settings: settings, defaults: defaults)
        setup.profileStore = profileStore
        setup.applyRecommendedModelIfNeeded()
        settings = setup.settings

        let usage = UsageStore(defaults: defaults)
        let orchestrator = SessionOrchestrator(
            settings: settings,
            captureRegistry: dependencies.captureRegistry,
            inferenceRegistry: dependencies.inferenceRegistry,
            webLookup: dependencies.webLookup,
            speechRecognizer: dependencies.speechRecognizer,
            speechSynthesizer: dependencies.answerSpeechSynthesizer,
            previewSpeechSynthesizer: dependencies.previewSpeechSynthesizer
        )
        orchestrator.setup = setup
        orchestrator.usage = usage
        orchestrator.profileStore = profileStore
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
            inferenceRegistry: dependencies.inferenceRegistry,
            credentialStore: dependencies.credentialStore
        )
        let storageFootprint = StorageFootprintService(archive: orchestrator.conversationArchive)
        return Stack(
            orchestrator: orchestrator,
            setup: setup,
            usage: usage,
            settings: settingsController,
            modelCatalog: dependencies.modelCatalog,
            storageFootprint: storageFootprint,
            profileStore: profileStore
        )
    }

    @MainActor
    public static func makeOrchestrator(settings: PeeknookSettings) -> SessionOrchestrator {
        makeStack(settings: settings, defaults: .standard).orchestrator
    }

}
