// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Product preferences under the `peeknook.*` namespace (never `opennook.*`).
public struct PeeknookSettings: Codable, Equatable, Sendable {
    public static let defaultsKey = "peeknook.settings.v1"

    public var mode: PracticeMode
    public var previewBeforeInfer: Bool
    public var ollamaBaseURL: String
    public var textModel: String
    /// Faster, terser answers: caps output length and asks the model for 2–3 lines.
    public var quickMode: Bool
    /// Window under the cursor vs the whole display under the cursor.
    public var captureScope: CaptureScope
    /// Ask the model to propose 2–3 next questions after each answer (the dynamic action pills).
    public var suggestFollowUps: Bool
    /// Global capture shortcut (default ⌘⇧P).
    public var captureHotkey: CaptureHotkey
    /// Opt-in: keep the active chat (including its screenshots) in a local file so it survives a
    /// quit. Off by default, captures are private user data. Cleared when turned off.
    public var persistConversation: Bool
    /// Opt-in: run a live web search from capture context and show results alongside the answer.
    /// Queries leave this Mac via DuckDuckGo HTML. Off by default.
    public var webLookupEnabled: Bool
    /// User-added models (any Ollama tag) shown alongside the curated catalog in the picker.
    public var customModels: [CustomModelEntry]
    /// Optional nickname for the idle greeting. Empty falls back to the macOS account first name.
    public var displayName: String
    /// When false, the idle home headline is hidden.
    public var showGreeting: Bool
    /// When false, answers render as plain text instead of lightweight inline Markdown.
    public var renderAnswerMarkdown: Bool
    /// Opt-in: dictate briefs and follow-ups with on-device speech recognition.
    public var voiceInputEnabled: Bool
    /// Opt-in: read assistant answers aloud with on-device text-to-speech.
    public var speakAnswersEnabled: Bool
    /// Highlight the spoken words in the answer while TTS is active.
    public var highlightSpeechWhileReading: Bool
    /// AVSpeechSynthesisVoice identifier, or empty for the system default voice.
    public var speechVoiceIdentifier: String
    /// Global shortcut to focus the session-brief composer (default ⌘⇧B).
    public var briefHotkey: CaptureHotkey
    /// Global shortcut to open the live camera preview (default ⌘⇧C).
    public var cameraHotkey: CaptureHotkey
    /// How many screenshots replay as vision payloads per inference request (suggestions stay at 0).
    public var inferenceImageReplay: InferenceImageReplay
    /// Opt-in: allow plain HTTP to a non-loopback Ollama host (screenshots in cleartext).
    public var acceptInsecureRemoteOllama: Bool
    /// The active ground-profile id (capture-surface bundle). Resolves via ``activeProfile``; an
    /// unknown/stale id falls back to `screen.default`. Only the id persists — the profile catalog is
    /// code-defined in phase 1.
    public var activeProfileID: String
    /// Which inference backend answers captures. `textModel` stays the Ollama tag (and is always
    /// written, so old builds keep resolving a real local model); the OpenAI-compatible backend
    /// keeps its own overlay fields below. See ``answerModel``.
    public var answerBackend: InferenceBackend
    /// Base URL of the user's OpenAI-compatible server (LM Studio, vLLM). Empty until configured.
    public var openAICompatibleBaseURL: String
    /// The chosen `/v1/models` id on the OpenAI-compatible server. Empty until chosen.
    public var openAICompatibleModelTag: String
    /// Opt-in: allow plain HTTP to a non-loopback OpenAI-compatible host (screenshots in cleartext).
    public var acceptInsecureRemoteOpenAICompatible: Bool

    public init(
        mode: PracticeMode = .general,
        previewBeforeInfer: Bool = false,
        ollamaBaseURL: String = "http://127.0.0.1:11434",
        textModel: String = SystemProfile.current().suggestedTextModel,
        quickMode: Bool = false,
        captureScope: CaptureScope = .window,
        suggestFollowUps: Bool = true,
        captureHotkey: CaptureHotkey = .default,
        persistConversation: Bool = false,
        webLookupEnabled: Bool = false,
        customModels: [CustomModelEntry] = [],
        displayName: String = "",
        showGreeting: Bool = true,
        renderAnswerMarkdown: Bool = true,
        voiceInputEnabled: Bool = false,
        speakAnswersEnabled: Bool = false,
        highlightSpeechWhileReading: Bool = true,
        speechVoiceIdentifier: String = "",
        briefHotkey: CaptureHotkey = .defaultBrief,
        inferenceImageReplay: InferenceImageReplay = .latestOnly,
        acceptInsecureRemoteOllama: Bool = false,
        activeProfileID: String = GroundProfile.screenDefault.id,
        cameraHotkey: CaptureHotkey = .defaultCamera,
        answerBackend: InferenceBackend = .ollama,
        openAICompatibleBaseURL: String = "",
        openAICompatibleModelTag: String = "",
        acceptInsecureRemoteOpenAICompatible: Bool = false
    ) {
        self.mode = mode
        self.previewBeforeInfer = previewBeforeInfer
        self.ollamaBaseURL = ollamaBaseURL
        self.textModel = textModel
        self.quickMode = quickMode
        self.captureScope = captureScope
        self.suggestFollowUps = suggestFollowUps
        self.captureHotkey = captureHotkey
        self.persistConversation = persistConversation
        self.webLookupEnabled = webLookupEnabled
        self.customModels = customModels
        self.displayName = displayName
        self.showGreeting = showGreeting
        self.renderAnswerMarkdown = renderAnswerMarkdown
        self.voiceInputEnabled = voiceInputEnabled
        self.speakAnswersEnabled = speakAnswersEnabled
        self.highlightSpeechWhileReading = highlightSpeechWhileReading
        self.speechVoiceIdentifier = speechVoiceIdentifier
        self.briefHotkey = briefHotkey
        self.cameraHotkey = cameraHotkey
        self.inferenceImageReplay = inferenceImageReplay
        self.acceptInsecureRemoteOllama = acceptInsecureRemoteOllama
        self.activeProfileID = activeProfileID
        self.answerBackend = answerBackend
        self.openAICompatibleBaseURL = openAICompatibleBaseURL
        self.openAICompatibleModelTag = openAICompatibleModelTag
        self.acceptInsecureRemoteOpenAICompatible = acceptInsecureRemoteOpenAICompatible
    }

    /// True when inference is configured to a host other than the default local Ollama loopback.
    public var usesRemoteOllama: Bool {
        EndpointURLPolicy.usesRemoteHost(ollamaBaseURL)
    }

    /// True when a remote Ollama URL uses plain HTTP without the insecure opt-in.
    public var remoteOllamaUsesInsecureHTTP: Bool {
        guard usesRemoteOllama else { return false }
        guard let url = URL(string: ollamaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" && !acceptInsecureRemoteOllama
    }

    /// True when the OpenAI-compatible server targets a host other than local loopback.
    public var openAICompatibleUsesRemoteHost: Bool {
        EndpointURLPolicy.usesRemoteHost(openAICompatibleBaseURL)
    }

    /// True when a remote OpenAI-compatible URL uses plain HTTP without the insecure opt-in.
    public var openAICompatibleUsesInsecureHTTP: Bool {
        guard openAICompatibleUsesRemoteHost else { return false }
        guard let url = URL(string: openAICompatibleBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" && !acceptInsecureRemoteOpenAICompatible
    }

    private enum CodingKeys: String, CodingKey {
        case mode, previewBeforeInfer, ollamaBaseURL, textModel, quickMode, captureScope, suggestFollowUps, captureHotkey, persistConversation, webLookupEnabled, customModels, displayName, showGreeting, renderAnswerMarkdown, voiceInputEnabled, speakAnswersEnabled, highlightSpeechWhileReading, speechVoiceIdentifier, briefHotkey, inferenceImageReplay, acceptInsecureRemoteOllama, activeProfileID, cameraHotkey, answerBackend, openAICompatibleBaseURL, openAICompatibleModelTag, acceptInsecureRemoteOpenAICompatible
    }

    // Tolerant decode, a saved blob missing a newer key keeps the rest of the user's
    // settings instead of resetting everything to defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.mode = try c.decodeIfPresent(PracticeMode.self, forKey: .mode) ?? .general
        self.previewBeforeInfer = try c.decodeIfPresent(Bool.self, forKey: .previewBeforeInfer) ?? false
        self.ollamaBaseURL = try c.decodeIfPresent(String.self, forKey: .ollamaBaseURL) ?? "http://127.0.0.1:11434"
        self.textModel = try c.decodeIfPresent(String.self, forKey: .textModel)
            ?? SystemProfile.current().suggestedTextModel
        self.quickMode = try c.decodeIfPresent(Bool.self, forKey: .quickMode) ?? false
        self.captureScope = try c.decodeIfPresent(CaptureScope.self, forKey: .captureScope) ?? .window
        self.suggestFollowUps = try c.decodeIfPresent(Bool.self, forKey: .suggestFollowUps) ?? true
        self.captureHotkey = try c.decodeIfPresent(CaptureHotkey.self, forKey: .captureHotkey) ?? .default
        self.persistConversation = try c.decodeIfPresent(Bool.self, forKey: .persistConversation) ?? false
        self.webLookupEnabled = try c.decodeIfPresent(Bool.self, forKey: .webLookupEnabled) ?? false
        self.customModels = try c.decodeIfPresent([CustomModelEntry].self, forKey: .customModels) ?? []
        self.displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        self.showGreeting = try c.decodeIfPresent(Bool.self, forKey: .showGreeting) ?? true
        self.renderAnswerMarkdown = try c.decodeIfPresent(Bool.self, forKey: .renderAnswerMarkdown) ?? true
        self.voiceInputEnabled = try c.decodeIfPresent(Bool.self, forKey: .voiceInputEnabled) ?? false
        self.speakAnswersEnabled = try c.decodeIfPresent(Bool.self, forKey: .speakAnswersEnabled) ?? false
        self.highlightSpeechWhileReading = try c.decodeIfPresent(Bool.self, forKey: .highlightSpeechWhileReading) ?? true
        self.speechVoiceIdentifier = try c.decodeIfPresent(String.self, forKey: .speechVoiceIdentifier) ?? ""
        self.briefHotkey = try c.decodeIfPresent(CaptureHotkey.self, forKey: .briefHotkey) ?? .defaultBrief
        self.cameraHotkey = try c.decodeIfPresent(CaptureHotkey.self, forKey: .cameraHotkey) ?? .defaultCamera
        self.inferenceImageReplay = try c.decodeIfPresent(InferenceImageReplay.self, forKey: .inferenceImageReplay) ?? .latestOnly
        self.acceptInsecureRemoteOllama = try c.decodeIfPresent(Bool.self, forKey: .acceptInsecureRemoteOllama) ?? false
        self.activeProfileID = try c.decodeIfPresent(String.self, forKey: .activeProfileID) ?? GroundProfile.screenDefault.id
        // Decoded as a raw String so an unknown future backend (e.g. "sidecar" written by a newer
        // build) degrades to Ollama instead of throwing and resetting every setting.
        let backendRaw = try c.decodeIfPresent(String.self, forKey: .answerBackend)
        self.answerBackend = backendRaw.flatMap(InferenceBackend.init(rawValue:)) ?? .ollama
        self.openAICompatibleBaseURL = try c.decodeIfPresent(String.self, forKey: .openAICompatibleBaseURL) ?? ""
        self.openAICompatibleModelTag = try c.decodeIfPresent(String.self, forKey: .openAICompatibleModelTag) ?? ""
        self.acceptInsecureRemoteOpenAICompatible = try c.decodeIfPresent(Bool.self, forKey: .acceptInsecureRemoteOpenAICompatible) ?? false
    }

    public static let `default` = PeeknookSettings(
        textModel: SystemProfile.current().suggestedTextModel
    )

    public static func load(from defaults: UserDefaults) -> PeeknookSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              var settings = try? JSONDecoder().decode(PeeknookSettings.self, from: data)
        else { return .default }
        if !PracticeMode.shipped.contains(settings.mode) {
            settings.mode = PracticeMode.shipped[0]
        }
        return settings
    }

    public func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
