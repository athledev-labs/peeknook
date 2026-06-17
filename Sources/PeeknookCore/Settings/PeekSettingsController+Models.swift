// SPDX-License-Identifier: Apache-2.0

import Foundation

// Model catalog: picking, custom (bring-your-own) tags, vision support, and download triggers.
@MainActor
extension PeekSettingsController {
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
}
