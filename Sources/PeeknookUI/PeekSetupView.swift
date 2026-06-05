// SPDX-License-Identifier: Apache-2.0

import NookApp
import PeeknookCore
import SwiftUI

public struct PeekSetupView: View {
    public var setup: SetupCoordinator
    public var orchestrator: SessionOrchestrator
    public var onContinue: () -> Void
    @Environment(\.nookResolvedTheme) private var theme

    public init(
        setup: SetupCoordinator,
        orchestrator: SessionOrchestrator,
        onContinue: @escaping () -> Void = {}
    ) {
        self.setup = setup
        self.orchestrator = orchestrator
        self.onContinue = onContinue
    }

    public var body: some View {
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .onAppear { setup.startAutoRefresh() }
        .onDisappear { setup.stopAutoRefresh() }
        .task { await setup.refresh() }
    }

    private var header: some View {
        Text("Local Gemma 4 via Ollama. Nothing leaves your Mac unless you change that later.")
            .font(.system(size: 11))
            .foregroundStyle(theme.secondaryLabel)
    }

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 10) {
            SetupStepRow(
                title: "Ollama running",
                detail: ollamaDetail,
                state: setup.ollamaStep,
                theme: theme,
                primaryEnabled: true,
                primaryAction: { SetupCoordinator.openOllamaApp() },
                secondaryAction: { SetupCoordinator.openOllamaDownload() },
                secondaryLabel: "Download"
            )

            SetupStepRow(
                title: TextModelCatalog.displayName(for: setup.settings.textModel),
                detail: "\(setup.suggestedModelDiskHint). Downloads once.",
                state: setup.modelStep,
                theme: theme,
                primaryEnabled: !setup.isPullingModel,
                primaryAction: { setup.pullRecommendedModel() },
                secondaryAction: setup.isPullingModel ? { setup.cancelPull() } : nil,
                secondaryLabel: setup.isPullingModel ? "Cancel" : nil
            )

            SetupStepRow(
                title: "Screen Recording",
                detail: "Required — Peeknook sends a screenshot to the vision model. Optional: Accessibility adds selected text.",
                state: setup.captureStep,
                theme: theme,
                primaryEnabled: true,
                primaryAction: { CapturePermissionStatus.requestScreenRecording() },
                secondaryAction: { CapturePermissionStatus.requestAccessibility() },
                secondaryLabel: "Accessibility"
            )

            SetupStepRow(
                title: "Test capture",
                detail: "Optional — run one capture to confirm permissions.",
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
        "Recommended: \(TextModelCatalog.displayName(for: SystemProfile.current().suggestedTextModel)) on this Mac."
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
        case "Ollama running":
            return "Open Ollama"
        default:
            return detail.contains("Downloads once.") ? "Download model" : "Fix"
        }
    }
}
