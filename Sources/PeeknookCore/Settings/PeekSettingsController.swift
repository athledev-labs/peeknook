// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation

/// Canonical read/write API for ``PeeknookSettings``, keeps orchestrator, setup, and
/// UserDefaults in sync so Home and Settings cannot drift.
@MainActor
@Observable
public final class PeekSettingsController {
    private let orchestrator: SessionOrchestrator
    private let setup: SetupCoordinator
    private let defaults: UserDefaults
    private let inferenceRegistry: InferenceBackendRegistry
    private let credentialStore: any CredentialStoring
    /// The engine for the active backend, resolved per call (matches the orchestrator's shim).
    private var inference: any InferenceEngine {
        inferenceRegistry.engine(for: settings.answerModel.backend)
    }

    public var settings: PeeknookSettings { orchestrator.settings }

    public init(
        orchestrator: SessionOrchestrator,
        setup: SetupCoordinator,
        defaults: UserDefaults,
        inferenceRegistry: InferenceBackendRegistry,
        credentialStore: any CredentialStoring = InMemoryCredentialStore()
    ) {
        self.orchestrator = orchestrator
        self.setup = setup
        self.defaults = defaults
        self.inferenceRegistry = inferenceRegistry
        self.credentialStore = credentialStore
    }

    /// Single-engine convenience for tests and simple hosts (wraps a uniform registry).
    public convenience init(
        orchestrator: SessionOrchestrator,
        setup: SetupCoordinator,
        defaults: UserDefaults,
        inference: any InferenceEngine
    ) {
        self.init(
            orchestrator: orchestrator,
            setup: setup,
            defaults: defaults,
            inferenceRegistry: .uniform(inference)
        )
    }

    /// Mutate in-memory settings and persist once to `peeknook.settings.v1`.
    public func update(_ mutate: (inout PeeknookSettings) -> Void) {
        mutate(&orchestrator.settings)
        persist()
    }

    public func persist() {
        orchestrator.persistSettings(to: defaults)
    }

    public func setQuickMode(_ quick: Bool) {
        guard settings.quickMode != quick else { return }
        update { $0.quickMode = quick }
    }

    public func setCaptureScope(_ scope: CaptureScope) {
        guard settings.captureScope != scope else { return }
        update { $0.captureScope = scope }
    }

    public func setMode(_ mode: PracticeMode) {
        guard settings.mode != mode else { return }
        update { $0.mode = mode }
    }

    public func setPreviewBeforeInfer(_ enabled: Bool) {
        guard settings.previewBeforeInfer != enabled else { return }
        update { $0.previewBeforeInfer = enabled }
    }

    public func setSuggestFollowUps(_ enabled: Bool) {
        guard settings.suggestFollowUps != enabled else { return }
        update { $0.suggestFollowUps = enabled }
    }

    public func setPersistConversation(_ enabled: Bool) {
        guard settings.persistConversation != enabled else { return }
        update { $0.persistConversation = enabled }
        // Start saving the current thread immediately, or wipe the whole archive when opting out.
        if enabled {
            orchestrator.persistConversationNow()
        } else {
            orchestrator.purgeAllConversations()
        }
    }

    public func setWebLookupEnabled(_ enabled: Bool) {
        guard settings.webLookupEnabled != enabled else { return }
        update { $0.webLookupEnabled = enabled }
    }

    public func setInferenceImageReplay(_ replay: InferenceImageReplay) {
        guard settings.inferenceImageReplay != replay else { return }
        update { $0.inferenceImageReplay = replay }
    }

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

    // MARK: - Profiles

    /// Activate a profile by id (built-in or user copy). Refreshes readiness (the permission
    /// matrix follows the profile) and prewarms the profile's bound model.
    public func setActiveProfile(id: String) {
        guard settings.activeProfileID != id else { return }
        update { $0.activeProfileID = id }
        Task {
            await setup.refresh()
            orchestrator.prewarm()
        }
    }

    /// Delete a user profile; when it was the active one, fall back to `screen.default`
    /// explicitly (the resolver would anyway — this keeps the persisted id honest).
    public func deleteProfile(id: String) {
        guard let store = orchestrator.profileStore else { return }
        if store.delete(id: id, activeProfileID: settings.activeProfileID) {
            update { $0.activeProfileID = GroundProfile.screenDefault.id }
            Task {
                await setup.refresh()
                orchestrator.prewarm()
            }
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

    public func setDisplayName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.displayName != trimmed else { return }
        update { $0.displayName = trimmed }
    }

    public func setShowGreeting(_ enabled: Bool) {
        guard settings.showGreeting != enabled else { return }
        update { $0.showGreeting = enabled }
    }

    public func setRenderAnswerMarkdown(_ enabled: Bool) {
        guard settings.renderAnswerMarkdown != enabled else { return }
        update { $0.renderAnswerMarkdown = enabled }
    }

    public func setVoiceInputEnabled(_ enabled: Bool) {
        guard settings.voiceInputEnabled != enabled else { return }
        update { $0.voiceInputEnabled = enabled }
        if !enabled { orchestrator.stopVoiceInput() }
    }

    public func setSpeakAnswersEnabled(_ enabled: Bool) {
        guard settings.speakAnswersEnabled != enabled else { return }
        update { $0.speakAnswersEnabled = enabled }
        if !enabled { orchestrator.stopSpeaking() }
    }

    public func setHighlightSpeechWhileReading(_ enabled: Bool) {
        guard settings.highlightSpeechWhileReading != enabled else { return }
        update { $0.highlightSpeechWhileReading = enabled }
        if !enabled { orchestrator.clearSpeechReadAlongHighlight() }
    }

    public func setSpeechVoiceIdentifier(_ identifier: String) {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.speechVoiceIdentifier != trimmed else { return }
        update { $0.speechVoiceIdentifier = trimmed }
    }

    public func setBriefHotkey(_ hotkey: CaptureHotkey) {
        guard settings.briefHotkey != hotkey else { return }
        update { $0.briefHotkey = hotkey }
    }

    public func setCaptureHotkey(_ hotkey: CaptureHotkey) {
        guard settings.captureHotkey != hotkey else { return }
        update { $0.captureHotkey = hotkey }
    }

    public func setCameraHotkey(_ hotkey: CaptureHotkey) {
        guard settings.cameraHotkey != hotkey else { return }
        update { $0.cameraHotkey = hotkey }
    }

    public enum ModelPickResult: Equatable {
        case selected
        case needsDownload(InferenceModelOption)
    }

    /// Installed models apply immediately; missing models return `.needsDownload` for UI
    /// confirmation. On the OpenAI-compatible backend there is no download path — the server
    /// loads its own models — so a pick always selects (into the overlay tag, never `textModel`).
    public func pickModel(_ option: InferenceModelOption) -> ModelPickResult {
        if settings.answerBackend == .openAICompatible {
            update { $0.openAICompatibleModelTag = option.tag }
            orchestrator.prewarm()
            return .selected
        }
        if setup.isModelInstalled(option.tag) {
            selectInstalledModel(option.tag)
            return .selected
        }
        return .needsDownload(option)
    }

    // MARK: - Custom (bring-your-own) models

    /// Curated catalog plus the user's added models, deduped by tag.
    public var availableModels: [InferenceModelOption] {
        TextModelCatalog.merged(custom: settings.customModels)
    }

    /// Models shown in Home / Setup pickers for the active backend. Pass served OpenAI-compatible
    /// tags from ``openAICompatibleServedModels()``; Ollama ignores the argument.
    public func pickerModels(servedOpenAIModels: [String] = []) -> [InferenceModelOption] {
        switch settings.answerBackend {
        case .ollama:
            return availableModels
        case .openAICompatible:
            return servedOpenAIModels.map {
                InferenceModelOption(
                    tag: $0,
                    displayName: $0,
                    provider: settings.answerBackend.providerLabel
                )
            }
        }
    }

    /// Display name for the active answer model in preflight pickers.
    public var activeModelDisplayName: String {
        TextModelCatalog.displayName(for: settings.answerModel.tag, custom: settings.customModels)
    }

    /// Whether a picker row matches the active answer model (backend-aware via ``answerModel``).
    public func isPickerOptionSelected(_ option: InferenceModelOption, modelCatalog: ModelCatalogService) -> Bool {
        modelCatalog.matchesModel(installedNames: [settings.answerModel.tag], wanted: option.tag)
    }

    /// Whether a picker tag is installed locally. OpenAI-compatible servers load their own models.
    public func isPickerOptionInstalled(_ tag: String) -> Bool {
        switch settings.answerBackend {
        case .ollama: return setup.isModelInstalled(tag)
        case .openAICompatible: return true
        }
    }

    /// Model library browse is Ollama-only; server-managed backends list served tags inline.
    public var showsModelLibraryBrowse: Bool {
        settings.answerBackend == .ollama
    }

    public var customModels: [CustomModelEntry] {
        settings.customModels
    }

    /// Register any Ollama tag the user typed so it joins the picker. Returns the option to act on
    /// (select if already installed, otherwise prompt to download) or nil if the tag was blank.
    @discardableResult
    public func addCustomModel(tag rawTag: String, displayName: String? = nil) -> InferenceModelOption? {
        let entry = CustomModelEntry(tag: rawTag, displayName: displayName)
        guard !entry.tag.isEmpty else { return nil }

        // Don't duplicate a curated tag or one already added, just surface the existing option.
        if let existing = TextModelCatalog.option(for: entry.tag, custom: settings.customModels) {
            return existing
        }

        update { $0.customModels.append(entry) }
        return InferenceModelOption(custom: entry)
    }

    /// Add a typed tag and immediately act on it: select if installed, else report `.needsDownload`
    /// so the caller can confirm the pull. Returns nil for a blank tag.
    public func addAndPickModel(tag rawTag: String) -> ModelPickResult? {
        guard let option = addCustomModel(tag: rawTag) else { return nil }
        return pickModel(option)
    }

    public func removeCustomModel(tag: String) {
        let key = OllamaSetupClient.normalizedTag(tag)
        update { settings in
            settings.customModels.removeAll { OllamaSetupClient.normalizedTag($0.tag) == key }
        }
        // If the deleted model was the active selection, fall back to the recommended tag.
        if OllamaSetupClient.normalizedTag(settings.textModel) == key {
            selectInstalledModel(SystemProfile.current().suggestedTextModel)
        }
    }

    /// Whether the current model can read the captured screenshot. `nil` while unknown (model not
    /// installed yet, an older Ollama that omits capabilities, or an OpenAI-compatible server,
    /// which reports none) so the UI stays quiet.
    public func currentModelSupportsVision() async -> Bool? {
        await supportsVision(for: settings.answerModel.tag)
    }

    /// Vision support for any tag, used by the model library when scanning installed models or
    /// validating a custom tag before add.
    public func supportsVision(for tag: String) async -> Bool? {
        await inference.supportsVision(model: tag, endpoint: settings.activeEndpoint)
    }

    /// Installed Ollama tags that aren't already in the picker (curated + custom), sorted for display.
    public func undiscoveredInstalledTags() -> [String] {
        ModelTagDiscovery.undiscovered(
            installedNames: setup.installedModelNames,
            knownTags: availableModels.map(\.tag)
        )
    }

    /// Whether a tag is already in the picker (curated or custom).
    public func isKnownModel(tag: String) -> Bool {
        TextModelCatalog.option(for: tag, custom: settings.customModels) != nil
    }

    public func selectInstalledModel(_ tag: String) {
        update { $0.textModel = tag }
        Task {
            await setup.refresh()
            orchestrator.prewarm()
        }
    }

    public func beginModelDownload(_ option: InferenceModelOption) {
        update { $0.textModel = option.tag }
        setup.pullRecommendedModel()
    }

    public func beginModelDownloadForCurrentSelection() {
        if let option = TextModelCatalog.option(for: settings.textModel) {
            beginModelDownload(option)
            return
        }
        beginModelDownload(
            InferenceModelOption(
                tag: settings.textModel,
                displayName: TextModelCatalog.displayName(for: settings.textModel),
                provider: "Ollama"
            )
        )
    }

    public func inferenceHealth() async -> InferenceHealth {
        await inference.health(endpoint: settings.activeEndpoint, model: settings.answerModel.tag)
    }
}

/// Filters installed Ollama tags to those not already listed in the picker.
public enum ModelTagDiscovery {
    public static func undiscovered(installedNames: [String], knownTags: [String]) -> [String] {
        let known = Set(knownTags.map { OllamaSetupClient.normalizedTag($0) })
        var seen = Set<String>()
        var result: [String] = []
        for name in installedNames {
            let key = OllamaSetupClient.normalizedTag(name)
            guard !key.isEmpty, !known.contains(key), !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(name)
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
