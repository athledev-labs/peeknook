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
        // Start saving the current thread immediately, or wipe the file when opting out.
        if enabled {
            orchestrator.persistConversationNow()
        } else {
            orchestrator.purgePersistedConversation()
        }
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
