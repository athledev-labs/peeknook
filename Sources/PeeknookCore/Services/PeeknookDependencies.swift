// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Injectable service bag shared by production wiring, unit tests, and the UI test host.
public struct PeeknookDependencies {
    public var capture: any CaptureProviding
    public var inference: any InferenceEngine
    public var webLookup: any WebLookupProviding
    public var speechRecognizer: any SpeechRecognizing
    public var answerSpeechSynthesizer: any SpeechSynthesizing
    public var previewSpeechSynthesizer: any SpeechSynthesizing
    public var modelCatalog: ModelCatalogService
    public var conversationArchive: ConversationArchiveStore?

    public init(
        capture: any CaptureProviding,
        inference: any InferenceEngine,
        webLookup: any WebLookupProviding,
        speechRecognizer: any SpeechRecognizing,
        answerSpeechSynthesizer: any SpeechSynthesizing,
        previewSpeechSynthesizer: any SpeechSynthesizing,
        modelCatalog: ModelCatalogService,
        conversationArchive: ConversationArchiveStore? = nil
    ) {
        self.capture = capture
        self.inference = inference
        self.webLookup = webLookup
        self.speechRecognizer = speechRecognizer
        self.answerSpeechSynthesizer = answerSpeechSynthesizer
        self.previewSpeechSynthesizer = previewSpeechSynthesizer
        self.modelCatalog = modelCatalog
        self.conversationArchive = conversationArchive
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
            capture: MacCaptureProvider(),
            inference: OllamaInferenceEngine(),
            webLookup: WebLookupRunner(),
            speechRecognizer: speechRecognizer,
            answerSpeechSynthesizer: answerSpeechSynthesizer,
            previewSpeechSynthesizer: previewSpeechSynthesizer,
            modelCatalog: ModelCatalogService.makeDefault()
        )
    }

    /// Deterministic doubles for unit tests and the UI test host.
    @MainActor
    public static func testing(
        capture: any CaptureProviding = StubCaptureProvider(sampleText: "screen"),
        inference: any InferenceEngine = MockInferenceEngine(tokens: ["ok"]),
        webLookup: any WebLookupProviding = StubWebLookup(),
        speechRecognizer: any SpeechRecognizing = StubSpeechRecognizer(),
        answerSpeechSynthesizer: any SpeechSynthesizing = StubSpeechSynthesizer(),
        previewSpeechSynthesizer: (any SpeechSynthesizing)? = nil,
        modelCatalog: ModelCatalogService = ModelCatalogService.makeDefault(),
        conversationArchive: ConversationArchiveStore? = nil
    ) -> PeeknookDependencies {
        let preview = previewSpeechSynthesizer ?? answerSpeechSynthesizer
        return PeeknookDependencies(
            capture: capture,
            inference: inference,
            webLookup: webLookup,
            speechRecognizer: speechRecognizer,
            answerSpeechSynthesizer: answerSpeechSynthesizer,
            previewSpeechSynthesizer: preview,
            modelCatalog: modelCatalog,
            conversationArchive: conversationArchive
        )
    }
}
