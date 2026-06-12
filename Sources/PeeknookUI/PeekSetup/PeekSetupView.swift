// SPDX-License-Identifier: Apache-2.0

import PeeknookDesign
import PeeknookCore
import SwiftUI

public struct PeekSetupView: View {
    public var setup: SetupCoordinator
    public var orchestrator: SessionOrchestrator
    public var settings: PeekSettingsController
    public var modelCatalog: ModelCatalogService
    public var onContinue: () -> Void
    @Environment(\.nookResolvedTheme) private var theme
    @Environment(\.nookContentInsets) private var contentInsets
    @EnvironmentObject private var appState: AppState
    @State private var pendingDownload: InferenceModelOption?
    @State private var showsModelLibrary = false
    @State private var servedModels: [String] = []

    public init(
        setup: SetupCoordinator,
        orchestrator: SessionOrchestrator,
        settings: PeekSettingsController,
        modelCatalog: ModelCatalogService,
        onContinue: @escaping () -> Void = {}
    ) {
        self.setup = setup
        self.orchestrator = orchestrator
        self.settings = settings
        self.modelCatalog = modelCatalog
        self.onContinue = onContinue
    }

    public var body: some View {
        Group {
            if showsModelLibrary {
                PeekModelLibraryView(
                    orchestrator: orchestrator,
                    setup: setup,
                    settings: settings,
                    modelCatalog: modelCatalog,
                    pendingDownload: $pendingDownload,
                    showsBackButton: true,
                    onDismiss: { showsModelLibrary = false }
                )
            } else {
                setupContent
            }
        }
        .padding(.top, 14)
        .padding(.bottom, contentInsets.bottom)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(maxHeight: PeekPanelLayout.setupMaxHeight)
        .onAppear { setup.startAutoRefresh() }
        .onDisappear { setup.stopAutoRefresh() }
        .task { await setup.refresh() }
        .task(id: servedModelsKey) {
            guard orchestrator.settings.answerBackend == .openAICompatible,
                  !orchestrator.settings.openAICompatibleBaseURL.isEmpty else {
                servedModels = []
                return
            }
            servedModels = await settings.openAICompatibleServedModels()
        }
        .peekModelDownloadConfirmation(pending: $pendingDownload) { option in
            settings.beginModelDownload(option)
        }
    }

    private var setupContent: some View {
        PeekScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                stepList
                if let pull = setup.pullStatusLine {
                    Text(pull)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.tertiaryLabel)
                        .lineLimit(2)
                }
                footerActions
            }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
    }

    private var header: some View {
        Text("Gemma 4 runs on your Mac through Ollama. Screenshots stay local unless you turn on web lookup or point at a remote Ollama server in Settings.")
            .font(.system(size: 11))
            .foregroundStyle(theme.secondaryLabel)
    }

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 10) {
            SetupStepRow(
                title: "Ollama server",
                detail: ollamaDetail,
                state: setup.ollamaStep,
                theme: theme,
                primaryEnabled: true,
                primaryLabel: setup.settings.usesRemoteOllama ? "Check server" : "Open Ollama",
                primarySymbol: setup.settings.usesRemoteOllama ? "arrow.clockwise" : "arrow.up.forward.app",
                primaryHint: setup.settings.usesRemoteOllama ? "Re-checks the configured server" : "Launches the Ollama app",
                primaryAction: ollamaPrimaryAction,
                secondaryAction: setup.settings.usesRemoteOllama ? nil : { SetupCoordinator.openOllamaDownload() },
                secondaryLabel: setup.settings.usesRemoteOllama ? nil : "Get Ollama app",
                secondarySymbol: setup.settings.usesRemoteOllama ? nil : "arrow.down.circle",
                secondaryHint: setup.settings.usesRemoteOllama ? nil : "Opens the Ollama download page"
            )

            SetupStepRow(
                title: TextModelCatalog.displayName(for: setup.settings.textModel),
                detail: modelDetail,
                state: setup.modelStep,
                theme: theme,
                primaryEnabled: !setup.isPullingModel,
                primarySymbol: "arrow.down.circle",
                primaryHint: "Downloads the model via Ollama",
                primaryAction: { setup.pullRecommendedModel() },
                secondaryAction: setup.isPullingModel ? { setup.cancelPull() } : nil,
                secondaryLabel: setup.isPullingModel ? "Cancel" : nil,
                secondarySymbol: setup.isPullingModel ? "xmark" : nil,
                secondaryHint: setup.isPullingModel ? "Stops the download" : nil,
                accessory: setup.isPullingModel ? nil : AnyView(modelPicker)
            )

            SetupStepRow(
                title: "Screen Recording",
                detail: "Required, Peeknook sends a screenshot to the answer model. Optional: Accessibility adds selected text.",
                state: setup.captureStep,
                theme: theme,
                primaryEnabled: true,
                primarySymbol: "checkmark.shield",
                primaryHint: "Open Privacy settings to grant Screen Recording",
                primaryAction: { CapturePermissionStatus.requestScreenRecording() },
                secondaryAction: { CapturePermissionStatus.requestAccessibility() },
                secondaryLabel: "Accessibility",
                secondarySymbol: "accessibility",
                secondaryHint: "Open Privacy settings to grant Accessibility"
            )

            SetupStepRow(
                title: "Test capture",
                detail: "Optional, run one capture to confirm permissions.",
                state: setup.smokeTestStep,
                theme: theme,
                primaryEnabled: setup.isReady,
                primarySymbol: "play.circle",
                primaryHint: "Runs one capture to confirm permissions",
                primaryAction: { orchestrator.beginCapture() },
                secondaryAction: nil,
                secondaryLabel: nil
            )
        }
    }

    private var ollamaDetail: String {
        if setup.settings.usesRemoteOllama {
            return "Peeknook sends screenshots to your configured Ollama server. Check the address in Settings → Answer model → Advanced."
        }
        let profile = SystemProfile.current()
        let model = TextModelCatalog.displayName(for: profile.suggestedTextModel)
        return "Runs vision models locally. Recommended model for \(profile.physicalMemoryGB) GB RAM: \(model)."
    }

    private func ollamaPrimaryAction() {
        if setup.settings.usesRemoteOllama {
            PeekSettingsNavigation.openVisionServer(appState: appState)
        } else {
            SetupCoordinator.openOllamaApp()
        }
    }

    private var modelDetail: String {
        if let option = TextModelCatalog.option(for: setup.settings.textModel) {
            return "\(option.downloadRowSubtitle)."
        }
        return "\(setup.suggestedModelDiskHint) · once via Ollama."
    }

    /// Same picker as Home/Settings, choose a tag, then Download pulls the selection.
    private var modelPicker: some View {
        ValueDropdownPill(
            symbol: "cpu",
            title: settings.activeModelDisplayName,
            help: "Answer model"
        ) { close in
            PeekPreflightMenuContent.visionModelHomeMenu(
                models: settings.pickerModels(servedOpenAIModels: servedModels),
                isInstalled: { settings.isPickerOptionInstalled($0) },
                isSelected: { settings.isPickerOptionSelected($0, modelCatalog: modelCatalog) },
                onSelect: selectModel,
                onBrowseModels: settings.showsModelLibraryBrowse ? { showsModelLibrary = true } : nil,
                close: close
            )
        }
    }

    private var servedModelsKey: String {
        "\(orchestrator.settings.answerBackend.rawValue)|\(orchestrator.settings.openAICompatibleBaseURL)|\(orchestrator.settings.acceptInsecureRemoteOpenAICompatible)"
    }

    private func selectModel(_ option: InferenceModelOption) {
        switch settings.pickModel(option) {
        case .selected:
            break
        case .needsDownload(let pending):
            pendingDownload = pending
        }
    }

    @ViewBuilder
    private var footerActions: some View {
        HStack(spacing: 10) {
            if setup.isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                NookToolbarButton(
                    title: "Check again",
                    symbol: "arrow.clockwise",
                    help: "Re-check Ollama, model, and permissions",
                    size: .setup
                ) { Task { await setup.refresh() } }
            }

            if setup.isReady {
                NookToolbarButton(
                    title: "Continue",
                    symbol: "arrow.right.circle",
                    prominent: true,
                    size: .setup,
                    action: onContinue
                )
            }
        }
    }
}

private struct SetupStepRow: View {
    let title: String
    let detail: String
    let state: SetupStepState
    let theme: NookResolvedTheme
    var primaryEnabled: Bool = true
    var primaryLabel: String? = nil
    var primarySymbol: String? = nil
    var primaryHint: String? = nil
    let primaryAction: () -> Void
    let secondaryAction: (() -> Void)?
    let secondaryLabel: String?
    var secondarySymbol: String? = nil
    var secondaryHint: String? = nil
    var accessory: AnyView? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 18)
                .peekDecorative()

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.primaryLabel)
                Text(peek: rowDetail)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.tertiaryLabel)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    if showsPrimary {
                        NookToolbarButton(
                            title: resolvedPrimaryLabel,
                            symbol: primarySymbol,
                            help: primaryHint,
                            prominent: true,
                            size: .setup,
                            action: primaryAction
                        )
                        .disabled(!primaryEnabled)
                    }
                    if showsSecondary, let secondaryAction, let secondaryLabel {
                        NookToolbarButton(
                            title: secondaryLabel,
                            symbol: secondarySymbol,
                            help: secondaryHint,
                            size: .setup,
                            action: secondaryAction
                        )
                    }
                    if let accessory {
                        accessory
                    }
                }
            }
        }
    }

    private var rowDetail: String {
        switch state {
        case .pending:
            detail
        case .inProgress(let msg):
            msg
        case .complete:
            "Done."
        case .blocked(let msg):
            msg
        case .failed(let msg):
            msg
        }
    }

    private var iconName: String {
        switch state {
        case .complete: "checkmark.circle.fill"
        case .blocked: "checkmark.circle"          // installed, but waiting on Ollama — hollow check, not the filled "verified" one
        case .failed: "exclamationmark.circle.fill"
        case .inProgress: "arrow.down.circle"
        case .pending: "circle"
        }
    }

    private var iconColor: Color {
        switch state {
        case .complete: .green
        case .blocked: theme.secondaryLabel        // muted — the actionable color belongs to the Ollama row
        case .failed: .orange
        case .inProgress: .blue
        case .pending: Color.secondary.opacity(0.5)
        }
    }

    private var showsPrimary: Bool {
        switch state {
        case .complete, .inProgress, .blocked:
            false
        case .pending, .failed:
            true
        }
    }

    private var showsSecondary: Bool {
        switch state {
        case .complete, .inProgress, .blocked:
            false
        case .pending, .failed:
            secondaryAction != nil
        }
    }

    private var resolvedPrimaryLabel: String {
        if let primaryLabel { return primaryLabel }
        return defaultPrimaryLabel
    }

    private var defaultPrimaryLabel: String {
        switch title {
        case "Test capture":
            return "Try now"
        case "Ollama server":
            return "Open Ollama"
        default:
            return isModelStep ? "Download model" : "Fix"
        }
    }

    private var isModelStep: Bool {
        TextModelCatalog.offered.contains { $0.displayName == title }
            || detail.contains("model file")
    }
}
