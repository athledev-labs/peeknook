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
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var appState: AppState
    @State private var pendingDownload: InferenceModelOption?
    @State private var showsModelLibrary = false
    @State private var servedModels: [String] = []
    @State private var showsWelcome = false

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
        // Seed from the persisted flag at init (not onAppear) so the checklist never flashes before
        // the welcome on a fresh install.
        _showsWelcome = State(initialValue: !setup.welcomeSeen)
    }

    public var body: some View {
        Group {
            if showsWelcome {
                PeekWelcomeView(captureHotkey: orchestrator.settings.captureHotkey) {
                    setup.markWelcomeSeen()
                    withAnimation(.easeInOut(duration: 0.2)) { showsWelcome = false }
                }
            } else if showsModelLibrary {
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
                downloadProgress
                footerActions
            }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
    }

    private var header: some View {
        Text(peek: "Three quick steps and a test, then you're ready to capture.")
            .font(.system(size: 11))
            .foregroundStyle(theme.secondaryLabel)
    }

    /// Determinate download bar (reusing the context-meter tint ramp) once real aggregated bytes give
    /// a fraction; an indeterminate spinner for the byte-less phases (preparing / verifying / finishing)
    /// so we never fake a determinate value. The model row already speaks the phase; the caption here
    /// carries the numbers.
    @ViewBuilder
    private var downloadProgress: some View {
        if setup.isPullingModel {
            VStack(alignment: .leading, spacing: 4) {
                if let fraction = setup.pullFraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(PeekContextTint.color(for: fraction))
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                if let caption = progressCaption {
                    Text(verbatim: caption)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.tertiaryLabel)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(verbatim: progressAccessibilityLabel))
        }
    }

    private var progressCaption: String? {
        guard let fraction = setup.pullFraction else { return nil }
        let percent = Int((fraction * 100).rounded())
        if let eta = setup.pullETA { return "\(percent)% · \(eta)" }
        return "\(percent)%"
    }

    private var progressAccessibilityLabel: String {
        let phase = setup.pullStatusLine ?? "Downloading"
        guard let caption = progressCaption else { return phase }
        return "\(phase) \(caption)"
    }

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 10) {
            SetupStepRow(
                title: "Ollama (the local AI engine)",
                detail: ollamaDetail,
                state: setup.ollamaStep,
                theme: theme,
                primaryEnabled: true,
                primaryLabel: ollamaPrimaryLabel,
                primarySymbol: ollamaPrimarySymbol,
                primaryHint: ollamaPrimaryHint,
                primaryAction: ollamaPrimaryAction,
                secondaryAction: ollamaShowsGetAppSecondary ? { SetupCoordinator.openOllamaDownload() } : nil,
                secondaryLabel: ollamaShowsGetAppSecondary ? "Get Ollama app" : nil,
                secondarySymbol: ollamaShowsGetAppSecondary ? "arrow.down.circle" : nil,
                secondaryHint: ollamaShowsGetAppSecondary ? "Opens the Ollama download page" : nil,
                accessory: ollamaActionable ? AnyView(needHelpButton) : nil
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
                detail: "Required, Peeknook sends a screenshot to the answer model. If the row stays orange after you enable it, quit and reopen Peeknook.",
                state: setup.captureStep,
                theme: theme,
                primaryEnabled: true,
                primarySymbol: "checkmark.shield",
                primaryHint: "Open Privacy settings to grant Screen Recording",
                primaryAction: { CapturePermissionStatus.requestScreenRecording() },
                secondaryAction: nil,
                secondaryLabel: nil,
                accessory: AnyView(accessibilityHintLink)
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
        let base = PeekLocalized("Runs the AI privately on your Mac. Recommended for \(profile.physicalMemoryGB) GB RAM: \(model).")
        // F10: name the live 3-second auto-detect so the user knows to leave Ollama running and wait.
        return "\(base) \(PeekLocalized("Leave Ollama running and come back. Peeknook checks every few seconds."))"
    }

    /// F9: when the local Ollama app isn't installed, the correct first action is to download it — so
    /// "Get Ollama app" becomes the prominent primary and the redundant secondary drops away.
    private var ollamaAppMissing: Bool {
        !setup.settings.usesRemoteOllama && !setup.isOllamaAppInstalled
    }

    private var ollamaShowsGetAppSecondary: Bool {
        !setup.settings.usesRemoteOllama && setup.isOllamaAppInstalled
    }

    private var ollamaPrimaryLabel: String {
        if setup.settings.usesRemoteOllama { return "Check server" }
        return ollamaAppMissing ? "Get Ollama app" : "Open Ollama"
    }

    private var ollamaPrimarySymbol: String {
        if setup.settings.usesRemoteOllama { return "arrow.clockwise" }
        return ollamaAppMissing ? "arrow.down.circle" : "arrow.up.forward.app"
    }

    private var ollamaPrimaryHint: String {
        if setup.settings.usesRemoteOllama { return "Re-checks the configured server" }
        return ollamaAppMissing
            ? "Download Ollama, the free helper that runs the AI on your Mac."
            : "Launches the Ollama app"
    }

    /// F10: the install guide + reassurance only make sense while the Ollama row still needs action.
    private var ollamaActionable: Bool {
        switch setup.ollamaStep {
        case .pending, .failed, .unknown: return true
        case .complete, .inProgress, .blocked: return false
        }
    }

    private var needHelpButton: some View {
        NookToolbarButton(
            title: "Need help?",
            symbol: "questionmark.circle",
            help: "Open the install guide in your browser",
            size: .setup
        ) { openURL(PeekAppMetadata.setupHelpURL) }
    }

    /// F12a: Accessibility is OPTIONAL (it only supplements capture with selected text), so it drops
    /// from a same-weight button to a low-emphasis inline link — leaving the prominent Screen
    /// Recording button as the single unambiguous action and steering users away from granting the
    /// wrong Privacy pane.
    private var accessibilityHintLink: some View {
        Button {
            CapturePermissionStatus.requestAccessibility()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "accessibility")
                    .font(.system(size: 8))
                    .foregroundStyle(theme.accent.opacity(0.9))
                    .peekDecorative()
                Text(peek: "Optional")
                    .foregroundStyle(theme.tertiaryLabel)
                Text(peek: "Add selected text")
                    .foregroundStyle(theme.accent)
                    .underline()
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(theme.accent.opacity(0.75))
                    .peekDecorative()
            }
            .font(.system(size: 10))
        }
        .buttonStyle(.plain)
        .help(PeekLocalized("Open Privacy settings to grant Accessibility (optional)"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(PeekLocalized("Add selected text")). \(PeekLocalized("Open Privacy settings to grant Accessibility (optional)"))"))
    }

    private func ollamaPrimaryAction() {
        if setup.settings.usesRemoteOllama {
            PeekSettingsNavigation.openVisionServer(appState: appState)
        } else if ollamaAppMissing {
            SetupCoordinator.openOllamaDownload()
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
                Text(peek: title)
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
        case .unknown(let msg):
            msg
        case .failed(let msg):
            msg
        }
    }

    private var iconName: String {
        switch state {
        case .complete: "checkmark.circle.fill"
        case .blocked: "checkmark.circle"          // installed, but waiting on Ollama — hollow check, not the filled "verified" one
        case .unknown: "questionmark.circle"       // can't tell yet (Ollama down, no cached list)
        case .failed: "exclamationmark.circle.fill"
        case .inProgress: "arrow.down.circle"
        case .pending: "circle"
        }
    }

    private var iconColor: Color {
        switch state {
        case .complete: .green
        case .blocked: theme.secondaryLabel        // muted — the actionable color belongs to the Ollama row
        case .unknown: theme.secondaryLabel        // muted — non-actionable, same as blocked
        case .failed: .orange
        case .inProgress: .blue
        case .pending: Color.secondary.opacity(0.5)
        }
    }

    private var showsPrimary: Bool {
        switch state {
        case .complete, .inProgress, .blocked, .unknown:
            false
        case .pending, .failed:
            true
        }
    }

    private var showsSecondary: Bool {
        switch state {
        case .complete, .inProgress, .blocked, .unknown:
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
        case "Ollama (the local AI engine)":
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
