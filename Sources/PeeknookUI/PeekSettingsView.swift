// SPDX-License-Identifier: Apache-2.0

import AppKit
import NookApp
import PeeknookCore
import SwiftUI

public struct PeekSettingsView: View {
    public var orchestrator: SessionOrchestrator
    public var setup: SetupCoordinator
    public var usage: UsageStore
    public var moduleDefaults: UserDefaults
    public var onCaptureHotkeyChange: ((CaptureHotkey) -> Void)?

    @Environment(\.nookResolvedTheme) private var theme
    @Environment(\.nookContentInsets) private var contentInsets
    @EnvironmentObject private var appState: AppState
    @State private var ollamaStatus: String = "Checking Ollama…"
    @State private var expandedSections: Set<String> = ["Practice"]

    public init(
        orchestrator: SessionOrchestrator,
        setup: SetupCoordinator,
        usage: UsageStore,
        moduleDefaults: UserDefaults,
        onCaptureHotkeyChange: ((CaptureHotkey) -> Void)? = nil
    ) {
        self.orchestrator = orchestrator
        self.setup = setup
        self.usage = usage
        self.moduleDefaults = moduleDefaults
        self.onCaptureHotkeyChange = onCaptureHotkeyChange
    }

    public var body: some View {
        let profile = SystemProfile.current()
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                section("Setup") {
                    setupSection
                }

                section("Practice") {
                    practiceSection
                }

                section("Inference") {
                    inferenceSection
                }

                section("Usage") {
                    usageSection(stats: usage.stats)
                }

                section("About") {
                    aboutSection(profile: profile)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, contentInsets.leading)
            .padding(.trailing, contentInsets.trailing)
            .padding(.bottom, 14)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .frame(maxWidth: .infinity, maxHeight: PeekPanelLayout.settingsMaxHeight, alignment: .topLeading)
        .task(id: inferenceCheckKey) {
            await refreshOllamaStatus()
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: setup.isReady ? "checkmark.seal.fill" : "exclamationmark.triangle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(setup.isReady ? Color.green : Color.orange)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(setup.isReady ? "Ready to capture" : "Setup incomplete")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.primaryLabel.opacity(0.95))
                    Text(setup.isReady ? "Ollama, model, and permissions are set." : "Finish Ollama, model, and permissions.")
                        .font(.system(size: 9, weight: .regular))
                        .foregroundStyle(theme.tertiaryLabel)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)

            SettingActionLine(
                icon: "arrow.right.circle",
                title: "Open Get ready",
                detail: "Permissions, model download, and smoke test",
                accent: theme.accent,
                action: openSetup
            )
        }
    }

    @ViewBuilder
    private var practiceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            PeekCaptureShortcutRow(hotkey: orchestrator.settings.captureHotkey) { newHotkey in
                orchestrator.settings.captureHotkey = newHotkey
                orchestrator.persistSettings(to: moduleDefaults)
                onCaptureHotkeyChange?(newHotkey)
            }

            if PracticeMode.shipped.count > 1 {
                // Reserved for a future distinct practice mode — not exposed while only General ships.
            }

            SettingActionLine(
                icon: orchestrator.settings.previewBeforeInfer ? "eye.fill" : "eye",
                title: "Confirm before analyzing",
                detail: orchestrator.settings.previewBeforeInfer
                    ? "On — preview capture target before sending"
                    : "Off — capture goes straight to the model",
                accent: theme.accent,
                action: togglePreviewBeforeInfer
            )

            SettingActionLine(
                icon: orchestrator.settings.suggestFollowUps ? "text.bubble.fill" : "text.bubble",
                title: "Suggest follow-ups",
                detail: orchestrator.settings.suggestFollowUps
                    ? "On — propose next questions after each answer"
                    : "Off — answers only",
                accent: theme.accent,
                action: toggleSuggestFollowUps
            )
        }
    }

    @ViewBuilder
    private var inferenceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            PeekSettingsValueRow(label: "Status", value: ollamaStatus)

            PeekSettingsTextField(
                label: "Model",
                text: textModelBinding,
                monospaced: true
            )

            PeekSettingsTextField(
                label: "Ollama base URL",
                text: ollamaURLBinding,
                monospaced: true
            )

            SettingActionLine(
                icon: "arrow.down.circle",
                title: "Download model",
                detail: setup.isPullingModel ? "Pull in progress…" : "Fetch the configured tag via Ollama",
                accent: theme.accent,
                action: { setup.pullRecommendedModel() }
            )
            .disabled(setup.isPullingModel)
            .opacity(setup.isPullingModel ? 0.55 : 1)
        }
    }

    @ViewBuilder
    private func usageSection(stats: UsageStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            PeekSettingsValueRow(label: "Captures", value: "\(stats.captures)")
            PeekSettingsValueRow(label: "Screen data", value: String(format: "%.1f MB", stats.imageMegabytes))
            PeekSettingsValueRow(
                label: "Tokens",
                value: "\(stats.promptTokens.formatted()) in · \(stats.responseTokens.formatted()) out"
            )
            PeekSettingsValueRow(
                label: "Avg speed",
                value: stats.averageTokensPerSecond > 0
                    ? String(format: "%.0f tok/s", stats.averageTokensPerSecond)
                    : "—"
            )

            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.green)
                    .frame(width: 18)
                Text("100% local — nothing leaves this Mac")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.secondaryLabel)
            }
            .padding(.vertical, 2)

            SettingActionLine(
                icon: "arrow.counterclockwise",
                title: "Reset stats",
                detail: "Clear capture and token counters on this Mac",
                accent: theme.accent,
                action: { usage.reset() }
            )
        }
    }

    @ViewBuilder
    private func aboutSection(profile: SystemProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            PeekSettingsValueRow(label: "Memory", value: "\(profile.physicalMemoryGB) GB")
            PeekSettingsValueRow(label: "Suggested model", value: profile.suggestedTextModel)
            PeekSettingsNote(
                text: "Capture sends a screenshot — the window under your cursor or the whole screen — to the local vision model, plus selected text when Accessibility is granted."
            )
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        PeekSettingsDisclosureSection(
            title: title,
            isExpanded: Binding(
                get: { expandedSections.contains(title) },
                set: { open in
                    if open { expandedSections.insert(title) } else { expandedSections.remove(title) }
                }
            ),
            content: content
        )
    }

    private var inferenceCheckKey: String {
        "\(orchestrator.settings.ollamaBaseURL)|\(orchestrator.settings.textModel)"
    }

    private var textModelBinding: Binding<String> {
        Binding(
            get: { orchestrator.settings.textModel },
            set: { newValue in
                orchestrator.settings.textModel = newValue
                setup.settings.textModel = newValue
                orchestrator.persistSettings(to: moduleDefaults)
                setup.persistSettings()
            }
        )
    }

    private var ollamaURLBinding: Binding<String> {
        Binding(
            get: { orchestrator.settings.ollamaBaseURL },
            set: { newValue in
                orchestrator.settings.ollamaBaseURL = newValue
                setup.settings.ollamaBaseURL = newValue
                orchestrator.persistSettings(to: moduleDefaults)
                setup.persistSettings()
            }
        )
    }

    private func openSetup() {
        appState.showHome()
        appState.moduleBreadcrumb = PeekRootView.setupBreadcrumb
    }

    private func togglePreviewBeforeInfer() {
        orchestrator.settings.previewBeforeInfer.toggle()
        orchestrator.persistSettings(to: moduleDefaults)
    }

    private func toggleSuggestFollowUps() {
        orchestrator.settings.suggestFollowUps.toggle()
        orchestrator.persistSettings(to: moduleDefaults)
    }

    private func refreshOllamaStatus() async {
        ollamaStatus = "Checking…"
        let engine = OllamaInferenceEngine()
        let health = await engine.health(
            baseURL: orchestrator.settings.ollamaBaseURL,
            model: orchestrator.settings.textModel
        )
        switch health {
        case .ready:
            ollamaStatus = "Ready — \(orchestrator.settings.textModel)"
        case .unavailable(let reason):
            ollamaStatus = reason
        }
        await setup.refresh()
    }
}
