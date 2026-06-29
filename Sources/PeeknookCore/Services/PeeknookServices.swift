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
        let setup = SetupCoordinator(settings: settings, defaults: defaults, probeCache: dependencies.probeCache)
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
            previewSpeechSynthesizer: dependencies.previewSpeechSynthesizer,
            streamingTranscriber: dependencies.streamingTranscriber
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
        // Release the resident local model if the system hits critical memory pressure, so a capture
        // doesn't overcommit RAM and swap-thrash the Mac. Production-only (the running app), not in
        // unit-constructed orchestrators.
        orchestrator.startMemoryPressureMonitoring()
        setup.orchestrator = orchestrator
        let settingsController = PeekSettingsController(
            orchestrator: orchestrator,
            setup: setup,
            defaults: defaults,
            inferenceRegistry: dependencies.inferenceRegistry,
            credentialStore: dependencies.credentialStore
        )
        let storageFootprint = StorageFootprintService(archive: orchestrator.conversationArchive)
        let modelCatalog = resolvedModelCatalog(settings: settings, fallback: dependencies.modelCatalog)
        return Stack(
            orchestrator: orchestrator,
            setup: setup,
            usage: usage,
            settings: settingsController,
            modelCatalog: modelCatalog,
            storageFootprint: storageFootprint,
            profileStore: profileStore
        )
    }

    @MainActor
    public static func makeOrchestrator(settings: PeeknookSettings) -> SessionOrchestrator {
        makeStack(settings: settings, defaults: .standard).orchestrator
    }

    /// Resolves the model-catalog service from settings, HTTPS-gating any catalog override through the
    /// same ``EndpointURLPolicy`` as inference. An empty/whitespace override means "use the built-in
    /// default" and reuses the injected service unchanged (byte-identical to today). A validated custom
    /// host builds a fresh catalog client; an invalid or insecure-remote override falls back to the
    /// built-in default rather than ever pointing the client at an unvalidated host.
    private static func resolvedModelCatalog(
        settings: PeeknookSettings,
        fallback: ModelCatalogService
    ) -> ModelCatalogService {
        let resolved = settings.resolvedCatalogBaseURL
        guard resolved != OllamaCatalogClient.defaultCatalogBaseURL else { return fallback }
        switch EndpointURLPolicy.validate(resolved, acceptInsecureRemote: settings.acceptInsecureRemoteOllama) {
        case .valid:
            return ModelCatalogService.makeDefault(catalogBaseURL: resolved)
        case .invalidURL, .unsupportedScheme, .insecureRemoteHTTP:
            return ModelCatalogService.makeDefault(catalogBaseURL: OllamaCatalogClient.defaultCatalogBaseURL)
        }
    }

}
