// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Injectable service bag shared by production wiring, unit tests, and the UI test host.
public struct PeeknookDependencies {
    public var captureRegistry: GroundRegistry
    public var inference: any InferenceEngine
    public var webLookup: any WebLookupProviding
    public var speechRecognizer: any SpeechRecognizing
    public var answerSpeechSynthesizer: any SpeechSynthesizing
    public var previewSpeechSynthesizer: any SpeechSynthesizing
    public var modelCatalog: ModelCatalogService
    public var conversationArchive: ConversationArchiveStore?
    public var storageFootprint: any StorageFootprinting
    public var credentialStore: any CredentialStoring

    public init(
        captureRegistry: GroundRegistry,
        inference: any InferenceEngine,
        webLookup: any WebLookupProviding,
        speechRecognizer: any SpeechRecognizing,
        answerSpeechSynthesizer: any SpeechSynthesizing,
        previewSpeechSynthesizer: any SpeechSynthesizing,
        modelCatalog: ModelCatalogService,
        conversationArchive: ConversationArchiveStore? = nil,
        storageFootprint: (any StorageFootprinting)? = nil,
        credentialStore: any CredentialStoring = InMemoryCredentialStore()
    ) {
        self.captureRegistry = captureRegistry
        self.inference = inference
        self.webLookup = webLookup
        self.speechRecognizer = speechRecognizer
        self.answerSpeechSynthesizer = answerSpeechSynthesizer
        self.previewSpeechSynthesizer = previewSpeechSynthesizer
        self.modelCatalog = modelCatalog
        self.conversationArchive = conversationArchive
        self.storageFootprint = storageFootprint
            ?? StorageFootprintService(archive: conversationArchive)
        self.credentialStore = credentialStore
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
        return PeeknookDependencies(
            captureRegistry: GroundRegistry([
                .screen: MacCaptureProvider(),
                // Registered but dormant: no built-in profile resolves to .camera and no hotkey
                // opens the live preview until the camera slices that wire them.
                .camera: CameraCaptureProvider(),
            ]),
            inference: OllamaInferenceEngine(),
            webLookup: WebLookupRunner(),
            speechRecognizer: speechRecognizer,
            answerSpeechSynthesizer: answerSpeechSynthesizer,
            previewSpeechSynthesizer: previewSpeechSynthesizer,
            modelCatalog: ModelCatalogService.makeDefault(),
            credentialStore: KeychainCredentialStore()
        )
    }

    /// Deterministic doubles for unit tests and the UI test host. `capture` stays a single
    /// provider (wrapped as the screen entry) so existing call sites don't churn on the registry;
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
        credentialStore: any CredentialStoring = InMemoryCredentialStore()
    ) -> PeeknookDependencies {
        let preview = previewSpeechSynthesizer ?? answerSpeechSynthesizer
        var providers: [Ground: any CaptureProviding] = [.screen: capture]
        if let cameraSession { providers[.camera] = cameraSession }
        return PeeknookDependencies(
            captureRegistry: GroundRegistry(providers),
            inference: inference,
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
