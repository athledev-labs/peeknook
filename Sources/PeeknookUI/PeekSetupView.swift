// SPDX-License-Identifier: Apache-2.0

import NookApp
import PeeknookCore
import SwiftUI

public struct PeekSetupView: View {
    public var setup: SetupCoordinator
    public var orchestrator: SessionOrchestrator
    public var settings: PeekSettingsController
    public var onContinue: () -> Void
    @Environment(\.nookResolvedTheme) private var theme
    @State private var pendingDownload: InferenceModelOption?
    @State private var showsModelLibrary = false

    public init(
        setup: SetupCoordinator,
        orchestrator: SessionOrchestrator,
        settings: PeekSettingsController,
        onContinue: @escaping () -> Void = {}
    ) {
        self.setup = setup
        self.orchestrator = orchestrator
        self.settings = settings
        self.onContinue = onContinue
    }

    public var body: some View {
        Group {
            if showsModelLibrary {
                PeekModelLibraryView(
                    orchestrator: orchestrator,
                    setup: setup,
                    settings: settings,
                    pendingDownload: $pendingDownload,
                    showsBackButton: true,
                    onDismiss: { showsModelLibrary = false }
                )
            } else {
                setupContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .onAppear { setup.startAutoRefresh() }
        .onDisappear { setup.stopAutoRefresh() }
        .task { await setup.refresh() }
        .peekModelDownloadConfirmation(pending: $pendingDownload) { option in
            settings.beginModelDownload(option)
        }
    }

    private var setupContent: some View {
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

    private var header: some View {
        Text("Gemma 4 runs on your Mac through Ollama. Nothing is sent to the cloud.")
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
                primaryAction: { SetupCoordinator.openOllamaApp() },
                secondaryAction: { SetupCoordinator.openOllamaDownload() },
                secondaryLabel: "Get Ollama app"
            )

            SetupStepRow(
                title: TextModelCatalog.displayName(for: setup.settings.textModel),
                detail: modelDetail,
                state: setup.modelStep,
                theme: theme,
                primaryEnabled: !setup.isPullingModel,
                primaryAction: { setup.pullRecommendedModel() },
                secondaryAction: setup.isPullingModel ? { setup.cancelPull() } : nil,
                secondaryLabel: setup.isPullingModel ? "Cancel" : nil,
                accessory: setup.isPullingModel ? nil : AnyView(modelPicker)
            )

            SetupStepRow(
                title: "Screen Recording",
                detail: "Required, Peeknook sends a screenshot to the vision model. Optional: Accessibility adds selected text.",
                state: setup.captureStep,
                theme: theme,
                primaryEnabled: true,
                primaryAction: { CapturePermissionStatus.requestScreenRecording() },
                secondaryAction: { CapturePermissionStatus.requestAccessibility() },
                secondaryLabel: "Accessibility"
            )

            SetupStepRow(
                title: "Test capture",
                detail: "Optional, run one capture to confirm permissions.",
                state: setup.smokeTestStep,
                theme: theme,
                primaryEnabled: setup.isReady,
                primaryAction: { orchestrator.beginCapture() },
                secondaryAction: nil,
                secondaryLabel: nil
            )
        }
    }

    private var ollamaDetail: String {
        let profile = SystemProfile.current()
        let model = TextModelCatalog.displayName(for: profile.suggestedTextModel)
        return "Runs vision models locally. Recommended model for \(profile.physicalMemoryGB) GB RAM: \(model)."
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
            title: TextModelCatalog.displayName(for: setup.settings.textModel, custom: settings.customModels),
            help: "Vision model"
        ) { close in
            PeekPreflightMenuContent.visionModelHomeMenu(
                currentTag: setup.settings.textModel,
                models: settings.availableModels,
                isInstalled: { setup.isModelInstalled($0) },
                onSelect: selectModel,
                onBrowseModels: { showsModelLibrary = true },
                close: close
            )
        }
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
            Button {
                Task { await setup.refresh() }
            } label: {
                if setup.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Check again")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if setup.isReady {
                Button("Continue", action: onContinue)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
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
    let primaryAction: () -> Void
    let secondaryAction: (() -> Void)?
    let secondaryLabel: String?
    var accessory: AnyView? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.primaryLabel)
                Text(rowDetail)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.tertiaryLabel)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    if showsPrimary {
                        Button(primaryLabel, action: primaryAction)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                            .disabled(!primaryEnabled)
                    }
                    if showsSecondary, let secondaryAction, let secondaryLabel {
                        Button(secondaryLabel, action: secondaryAction)
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
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
        case .failed(let msg):
            msg
        }
    }

    private var iconName: String {
        switch state {
        case .complete: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .inProgress: "arrow.down.circle"
        case .pending: "circle"
        }
    }

    private var iconColor: Color {
        switch state {
        case .complete: .green
        case .failed: .orange
        case .inProgress: .blue
        case .pending: Color.secondary.opacity(0.5)
        }
    }

    private var showsPrimary: Bool {
        switch state {
        case .complete, .inProgress:
            false
        case .pending, .failed:
            true
        }
    }

    private var showsSecondary: Bool {
        switch state {
        case .complete, .inProgress:
            false
        case .pending, .failed:
            secondaryAction != nil
        }
    }

    private var primaryLabel: String {
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
