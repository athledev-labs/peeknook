// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation

/// Canonical read/write API for ``PeeknookSettings`` — keeps orchestrator, setup, and
/// UserDefaults in sync so Home and Settings cannot drift.
@MainActor
@Observable
public final class PeekSettingsController {
    private let orchestrator: SessionOrchestrator
    private let setup: SetupCoordinator
    private let defaults: UserDefaults
    private let inference: any InferenceEngine

    public var settings: PeeknookSettings { orchestrator.settings }

    public init(
        orchestrator: SessionOrchestrator,
        setup: SetupCoordinator,
        defaults: UserDefaults,
        inference: any InferenceEngine
    ) {
        self.orchestrator = orchestrator
        self.setup = setup
        self.defaults = defaults
        self.inference = inference
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

    public func setOllamaBaseURL(_ url: String) {
        guard settings.ollamaBaseURL != url else { return }
        update { $0.ollamaBaseURL = url }
    }

    public func setCaptureHotkey(_ hotkey: CaptureHotkey) {
        guard settings.captureHotkey != hotkey else { return }
        update { $0.captureHotkey = hotkey }
    }

    public enum ModelPickResult: Equatable {
        case selected
        case needsDownload(InferenceModelOption)
    }

    /// Installed models apply immediately; missing models return `.needsDownload` for UI confirmation.
    public func pickModel(_ option: InferenceModelOption) -> ModelPickResult {
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

    public var customModels: [CustomModelEntry] {
        settings.customModels
    }

    /// Register any Ollama tag the user typed so it joins the picker. Returns the option to act on
    /// (select if already installed, otherwise prompt to download) or nil if the tag was blank.
    @discardableResult
    public func addCustomModel(tag rawTag: String, displayName: String? = nil) -> InferenceModelOption? {
        let entry = CustomModelEntry(tag: rawTag, displayName: displayName)
        guard !entry.tag.isEmpty else { return nil }

        // Don't duplicate a curated tag or one already added — just surface the existing option.
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
    /// installed yet, or an older Ollama that omits capabilities) so the UI stays quiet.
    public func currentModelSupportsVision() async -> Bool? {
        await supportsVision(for: settings.textModel)
    }

    /// Vision support for any tag — used by the model library when scanning installed models or
    /// validating a custom tag before add.
    public func supportsVision(for tag: String) async -> Bool? {
        await inference.supportsVision(model: tag, baseURL: settings.ollamaBaseURL)
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
        await inference.health(baseURL: settings.ollamaBaseURL, model: settings.textModel)
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
