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
    /// The continuous on-device transcriber that drives the ephemeral caption surface. Defaults to the
    /// fail-closed ``UnavailableStreamingTranscriber`` so a caption can never silently tap nothing; the
    /// real rotating SFSpeechRecognizer tap is wired in ``production()`` via
    /// ``makeProductionStreamingTranscriber()``. Dormant until the user enables `captionEnabled`.
    public var streamingTranscriber: any StreamingTranscribing
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
        probeCache: OllamaProbeCache = OllamaProbeCache(),
        streamingTranscriber: any StreamingTranscribing = UnavailableStreamingTranscriber()
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
        self.streamingTranscriber = streamingTranscriber
    }

    /// The production continuous transcriber for the caption surface. Returns the fail-closed
    /// ``UnavailableStreamingTranscriber`` today; the rotating SFSpeechRecognizer implementation (which is
    /// device-only and not unit-testable) lands behind this one swap point in a follow-up, gated on the
    /// Speech / ScreenCaptureKit frameworks being importable.
    @MainActor
    public static func makeProductionStreamingTranscriber() -> any StreamingTranscribing {
        UnavailableStreamingTranscriber()
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
                // System audio ("hear the screen") is REGISTERED but only resolves to a capture when a
                // user profile includes the `.systemAudio` ground AND the off-by-default
                // `systemAudioEnabled` opt-in is on — both checked at capture time in
                // `CompositeCaptureCoordinator.oneShotCaptureGrounds`. With the opt-in off (the default) the live
                // tap is unreachable. Its permissions (Screen Recording + Speech Recognition) are
                // requested through the active profile's `requiredPermissions`.
                .systemAudio: SystemAudioCaptureProvider(),
                // Clipboard ("read what you copied"): a fully local, zero-permission text ground. It
                // resolves to a capture only when a user profile includes the `.clipboard` ground —
                // the user's copy is itself the trigger and consent, so there is no opt-in to gate.
                .clipboard: ClipboardCaptureProvider(),
                // Accessibility tree ("read the focused window's structure"): a fully local text ground
                // that resolves to a capture only when a user profile includes `.accessibilityTree` AND
                // the off-by-default `accessibilityTreeEnabled` opt-in is on — both checked at capture
                // time in `CompositeCaptureCoordinator.oneShotCaptureGrounds`. The provider also gates on
                // live `AXIsProcessTrusted`. With the opt-in off (the default) the live AX walk is
                // unreachable. Its permission (Accessibility) is requested through the profile's
                // `requiredPermissions`.
                .accessibilityTree: AccessibilityTreeCaptureProvider(),
                // Tool ground ("run my configured local tool"): resolves to a capture only when a user
                // profile sets `.tool` as its primary ground AND carries a usable `ToolSpec`. It composes
                // the screen provider for the frame the tool reads, POSTs through `EndpointURLPolicy`, and
                // is dormant until such a profile exists (no built-in resolves to `.tool`).
                .tool: ToolGroundProvider(screenProvider: MacCaptureProvider()),
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
            modelCatalog: ModelCatalogService.makeDefault(
                catalogBaseURL: OllamaCatalogClient.defaultCatalogBaseURL
            ),
            credentialStore: credentialStore,
            probeCache: probeCache,
            streamingTranscriber: makeProductionStreamingTranscriber()
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
        openAICompatibleInference: (any InferenceEngine)? = nil,
        streamingTranscriber: any StreamingTranscribing = UnavailableStreamingTranscriber()
    ) -> PeeknookDependencies {
        let preview = previewSpeechSynthesizer ?? answerSpeechSynthesizer
        var providers: [Ground: any CaptureProviding] = [.screen: capture]
        if let cameraSession { providers[.camera] = cameraSession }
        providers[.file] = FileImportCaptureProvider()  // real, pure decoder — deterministic in tests
        // Stub-backed so the registry wiring is present and deterministic — no hardware in tests.
        providers[.systemAudio] = SystemAudioCaptureProvider(transcriber: StubSystemAudioTranscriber())
        // Stub-backed clipboard reader: deterministic, never touches the system pasteboard in tests.
        providers[.clipboard] = ClipboardCaptureProvider(reader: StubClipboardReader())
        // Stub-backed accessibility reader with trust forced on: deterministic, never touches the live
        // accessibility API in tests, and exercises the trusted branch of the provider's gate.
        providers[.accessibilityTree] = AccessibilityTreeCaptureProvider(
            reader: StubAccessibilityTreeReader(), isTrusted: { true }
        )
        // Stub-backed tool runner: deterministic, never touches the network. Present so the `.tool`
        // registry entry exists; tests that assert tool behavior inject their own recording client.
        providers[.tool] = ToolGroundProvider(screenProvider: capture, http: StubToolHTTPClient())
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
            credentialStore: credentialStore,
            streamingTranscriber: streamingTranscriber
        )
    }
}
