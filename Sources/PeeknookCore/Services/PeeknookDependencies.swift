// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Injectable service bag shared by production wiring, unit tests, and the UI test host.
public struct PeeknookDependencies {
    public var captureRegistry: GroundRegistry
    public var inferenceRegistry: InferenceBackendRegistry
    public var webLookup: any WebLookupProviding
    public var speechRecognizer: any SpeechRecognizing
    public var answerSpeechSynthesizer: any SpeechSynthesizing
    public var previewSpeechSynthesizer: any SpeechSynthesizing
    public var modelCatalog: ModelCatalogService
    public var conversationArchive: ConversationArchiveStore?
    public var storageFootprint: any StorageFootprinting
    public var credentialStore: any CredentialStoring
    /// Shared Ollama health-probe coalescer. Created here so the Ollama inference engine (built in this
    /// bag) and the setup refresh (wired in `makeStack`) share ONE cache and their overlapping
    /// `/api/version` + `/api/tags` probes on a Settings open collapse to a single request.
    public var probeCache: OllamaProbeCache

    public init(
        captureRegistry: GroundRegistry,
        inferenceRegistry: InferenceBackendRegistry,
        webLookup: any WebLookupProviding,
        speechRecognizer: any SpeechRecognizing,
        answerSpeechSynthesizer: any SpeechSynthesizing,
        previewSpeechSynthesizer: any SpeechSynthesizing,
        modelCatalog: ModelCatalogService,
        conversationArchive: ConversationArchiveStore? = nil,
        storageFootprint: (any StorageFootprinting)? = nil,
        credentialStore: any CredentialStoring = InMemoryCredentialStore(),
        probeCache: OllamaProbeCache = OllamaProbeCache()
    ) {
        self.captureRegistry = captureRegistry
        self.inferenceRegistry = inferenceRegistry
        self.webLookup = webLookup
        self.speechRecognizer = speechRecognizer
        self.answerSpeechSynthesizer = answerSpeechSynthesizer
        self.previewSpeechSynthesizer = previewSpeechSynthesizer
        self.modelCatalog = modelCatalog
        self.conversationArchive = conversationArchive
        self.storageFootprint = storageFootprint
            ?? StorageFootprintService(archive: conversationArchive)
        self.credentialStore = credentialStore
        self.probeCache = probeCache
    }

    /// Production defaults: live capture, Ollama inference, on-device speech when available.
    @MainActor
    public static func production() -> PeeknookDependencies {
        #if canImport(Speech) && canImport(AVFoundation)
        let speechRecognizer: any SpeechRecognizing = AppleSpeechRecognizer()
        let answerSpeechSynthesizer: any SpeechSynthesizing = AppleSpeechSynthesizer()
        let previewSpeechSynthesizer: any SpeechSynthesizing = AppleSpeechSynthesizer()
        #else
        let speechRecognizer: any SpeechRecognizing = StubSpeechRecognizer()
        let answerSpeechSynthesizer: any SpeechSynthesizing = StubSpeechSynthesizer()
        let previewSpeechSynthesizer: any SpeechSynthesizing = StubSpeechSynthesizer()
        #endif
        let credentialStore = KeychainCredentialStore()
        // One coalescer shared by the Ollama engine here and the setup refresh in `makeStack`.
        let probeCache = OllamaProbeCache()
        return PeeknookDependencies(
            captureRegistry: GroundRegistry([
                .screen: MacCaptureProvider(),
                // Registered but dormant: no built-in profile resolves to .camera and no hotkey
                // opens the live preview until the camera slices that wire them.
                .camera: CameraCaptureProvider(),
                // File import: resolved via the registry's FileImporting arm, never the capture path.
                .file: FileImportCaptureProvider(),
            ]),
            inferenceRegistry: InferenceBackendRegistry([
                .ollama: OllamaInferenceEngine(probeCache: probeCache),
                // The same store instance the deps expose — the engine reads the key per request,
                // so the orchestrator never sees key material.
                .openAICompatible: OpenAICompatibleInferenceEngine(
                    resolveAPIKey: { credentialStore.apiKey(for: $0) }
                ),
            ]),
            webLookup: WebLookupRunner(),
            speechRecognizer: speechRecognizer,
            answerSpeechSynthesizer: answerSpeechSynthesizer,
            previewSpeechSynthesizer: previewSpeechSynthesizer,
            modelCatalog: ModelCatalogService.makeDefault(),
            credentialStore: credentialStore,
            probeCache: probeCache
        )
    }

    /// Deterministic doubles for unit tests and the UI test host. `capture` stays a single
    /// provider (wrapped as the screen entry) and `inference` a single engine (wrapped as a
    /// uniform registry) so existing call sites don't churn; `openAICompatibleInference`
    /// overrides just that backend's entry when a test needs the engines to differ;
    /// `cameraSession` (typically a `StubCameraSession`) registers under `.camera` when supplied.
    @MainActor
    public static func testing(
        capture: any CaptureProviding = StubCaptureProvider(sampleText: "screen"),
        inference: any InferenceEngine = MockInferenceEngine(tokens: ["ok"]),
        webLookup: any WebLookupProviding = StubWebLookup(),
        speechRecognizer: any SpeechRecognizing = StubSpeechRecognizer(),
        answerSpeechSynthesizer: any SpeechSynthesizing = StubSpeechSynthesizer(),
        previewSpeechSynthesizer: (any SpeechSynthesizing)? = nil,
        modelCatalog: ModelCatalogService = ModelCatalogService.makeDefault(),
        conversationArchive: ConversationArchiveStore? = nil,
        cameraSession: (any CaptureProviding)? = nil,
        credentialStore: any CredentialStoring = InMemoryCredentialStore(),
        openAICompatibleInference: (any InferenceEngine)? = nil
    ) -> PeeknookDependencies {
        let preview = previewSpeechSynthesizer ?? answerSpeechSynthesizer
        var providers: [Ground: any CaptureProviding] = [.screen: capture]
        if let cameraSession { providers[.camera] = cameraSession }
        providers[.file] = FileImportCaptureProvider()  // real, pure decoder — deterministic in tests
        var engines: [InferenceBackend: any InferenceEngine] = Dictionary(
            uniqueKeysWithValues: InferenceBackend.allCases.map { ($0, inference) }
        )
        if let openAICompatibleInference { engines[.openAICompatible] = openAICompatibleInference }
        return PeeknookDependencies(
            captureRegistry: GroundRegistry(providers),
            inferenceRegistry: InferenceBackendRegistry(engines),
            webLookup: webLookup,
            speechRecognizer: speechRecognizer,
            answerSpeechSynthesizer: answerSpeechSynthesizer,
            previewSpeechSynthesizer: preview,
            modelCatalog: modelCatalog,
            conversationArchive: conversationArchive,
            credentialStore: credentialStore
        )
    }
}
