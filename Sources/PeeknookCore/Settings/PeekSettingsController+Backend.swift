// SPDX-License-Identifier: Apache-2.0

import Foundation

// Inference backend configuration: capture quality, the HTTPS-gated Ollama URL, and the
// OpenAI-compatible cluster (backend switch, URL/key, text-only follow-up routing, health).
@MainActor
extension PeekSettingsController {
    public func setCaptureQuality(_ quality: CaptureQuality) {
        guard settings.captureQuality != quality else { return }
        update { $0.captureQuality = quality }
    }

    public func setAcceptInsecureRemoteOllama(_ enabled: Bool) {
        guard settings.acceptInsecureRemoteOllama != enabled else { return }
        update { $0.acceptInsecureRemoteOllama = enabled }
    }

    /// Validates and persists an Ollama server URL. Returns false when the URL is rejected.
    @discardableResult
    public func setOllamaBaseURL(_ url: String) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.ollamaBaseURL != trimmed else { return true }
        switch EndpointURLPolicy.validate(trimmed, acceptInsecureRemote: settings.acceptInsecureRemoteOllama) {
        case .valid:
            update { $0.ollamaBaseURL = trimmed }
            return true
        case .invalidURL, .unsupportedScheme, .insecureRemoteHTTP:
            return false
        }
    }

    // MARK: - Answer backend

    /// Switch which backend answers captures. Refreshes setup readiness (the Ollama steps
    /// short-circuit off-Ollama) and prewarms the newly active endpoint.
    public func setAnswerBackend(_ backend: InferenceBackend) {
        guard settings.answerBackend != backend else { return }
        update { $0.answerBackend = backend }
        Task {
            await setup.refresh()
            orchestrator.prewarm()
        }
    }

    public func setAcceptInsecureRemoteOpenAICompatible(_ enabled: Bool) {
        guard settings.acceptInsecureRemoteOpenAICompatible != enabled else { return }
        update { $0.acceptInsecureRemoteOpenAICompatible = enabled }
    }

    // MARK: - Text-only follow-up routing (model roles)

    /// Opt in to routing a pure text follow-up to the cheaper ``PeeknookSettings/textOnlyModelTag``
    /// instead of the vision model. Off by default; with no text model chosen this stays inert.
    public func setFastTextFollowUps(_ enabled: Bool) {
        guard settings.fastTextFollowUps != enabled else { return }
        update { $0.fastTextFollowUps = enabled }
    }

    /// Which backend hosts the text-only follow-up model.
    public func setTextOnlyBackend(_ backend: InferenceBackend) {
        guard settings.textOnlyBackend != backend else { return }
        update { $0.textOnlyBackend = backend }
    }

    /// Sets the text-only follow-up model tag (no download path — the user picks an already-available
    /// local/served model). Empty clears it (feature off, byte-identical default restored).
    public func setTextOnlyModelTag(_ tag: String) {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.textOnlyModelTag != trimmed else { return }
        update { $0.textOnlyModelTag = trimmed }
    }

    /// Validates and persists the OpenAI-compatible server URL through the same HTTPS gate as
    /// Ollama. Returns false when the URL is rejected.
    @discardableResult
    public func setOpenAICompatibleBaseURL(_ url: String) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.openAICompatibleBaseURL != trimmed else { return true }
        switch EndpointURLPolicy.validate(
            trimmed, acceptInsecureRemote: settings.acceptInsecureRemoteOpenAICompatible
        ) {
        case .valid:
            update { $0.openAICompatibleBaseURL = trimmed }
            return true
        case .invalidURL, .unsupportedScheme, .insecureRemoteHTTP:
            return false
        }
    }

    /// Stores the server API key in the Keychain (never UserDefaults); empty clears it. Returns
    /// false when the Keychain write fails so the field can surface the miss.
    @discardableResult
    public func setOpenAICompatibleAPIKey(_ key: String) -> Bool {
        do {
            try credentialStore.setAPIKey(key, for: .openAICompatiblePrimary)
            return true
        } catch {
            return false
        }
    }

    /// Existence-only ("key is set") — the stored key is never echoed back into the UI.
    public var openAICompatibleKeyIsSet: Bool {
        credentialStore.hasKey(for: .openAICompatiblePrimary)
    }

    /// Model ids served by the configured OpenAI-compatible server, for the Settings picker.
    /// Empty when unconfigured, unreachable, or when the registered engine is a test double —
    /// the picker degrades to its "no models found" hint, never an error.
    public func openAICompatibleServedModels() async -> [String] {
        guard let engine = inferenceRegistry.engine(for: .openAICompatible)
            as? OpenAICompatibleInferenceEngine else { return [] }
        return await engine.listServedModels(
            baseURL: settings.openAICompatibleBaseURL,
            acceptInsecureRemote: settings.acceptInsecureRemoteOpenAICompatible
        )
    }

    public func inferenceHealth() async -> InferenceHealth {
        await inference.health(endpoint: settings.activeEndpoint, model: settings.answerModel.tag)
    }
}
