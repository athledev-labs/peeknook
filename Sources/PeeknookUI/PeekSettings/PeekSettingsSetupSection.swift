// SPDX-License-Identifier: Apache-2.0

import PeeknookDesign
import PeeknookCore
import SwiftUI

struct PeekSettingsSetupSection: View {
    var setup: SetupCoordinator
    var onOpenSetup: () -> Void

    @Environment(\.nookResolvedTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: setup.isReady ? "checkmark.seal.fill" : "exclamationmark.triangle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(setup.isReady ? Color.green : Color.orange)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(peek: setup.isReady ? "Ready to capture" : "Setup incomplete")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.primaryLabel.opacity(0.95))
                    Text(peek: summaryDetail)
                        .font(.system(size: 9, weight: .regular))
                        .foregroundStyle(theme.tertiaryLabel)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)

            HStack(spacing: 6) {
                PeekSettingsSetupChip(
                    title: "Ollama",
                    status: PeekSettingsSetupChipSupport.statusLabel(for: setup.ollamaStep),
                    tone: PeekSettingsSetupChipSupport.tone(for: setup.ollamaStep),
                    action: onOpenSetup
                )
                PeekSettingsSetupChip(
                    title: "Model",
                    status: PeekSettingsSetupChipSupport.statusLabel(for: setup.modelStep),
                    tone: PeekSettingsSetupChipSupport.tone(for: setup.modelStep),
                    action: onOpenSetup
                )
                // Permission chips render from the active profile's required permissions, so a
                // camera-only profile shows Camera instead of Screen Recording. For screen.default
                // this is a single Recording chip driven by captureStep — visually unchanged.
                ForEach(setup.permissionChecklist) { requirement in
                    let state = chipState(for: requirement)
                    PeekSettingsSetupChip(
                        title: requirement.permission.setupChipTitle,
                        status: PeekSettingsSetupChipSupport.statusLabel(for: state),
                        tone: PeekSettingsSetupChipSupport.tone(for: state),
                        action: onOpenSetup
                    )
                }
            }

            PeekSettingsCommandRow(
                icon: "arrow.right.circle",
                title: "Get ready",
                subtitle: "Install, permissions, and a test capture",
                action: onOpenSetup
            )
        }
    }

    /// Screen Recording keeps its richer step state (pending / in-progress) for parity with today;
    /// other permissions are simply granted-or-not.
    private func chipState(for requirement: PermissionRequirement) -> SetupStepState {
        if requirement.permission == .screenRecording { return setup.captureStep }
        return requirement.isGranted
            ? .complete
            : .failed("\(requirement.permission.displayName) is required for this profile.")
    }

    private var summaryDetail: String {
        if setup.isReady {
            return "Ollama, model, and Screen Recording are set."
        }
        var missing: [String] = []
        if setup.ollamaStep != .complete { missing.append("Ollama") }
        // A blocked model isn't "still needed" — it's installed and just waiting on Ollama, which is
        // already listed. Don't double-point at the model when the server is the only real culprit.
        if setup.modelStep != .complete, !isBlocked(setup.modelStep) { missing.append("model") }
        if setup.captureStep != .complete { missing.append("Screen Recording") }
        guard !missing.isEmpty else { return "Finish setup before capturing." }
        return "Still needed: \(missing.joined(separator: ", "))."
    }

    private func isBlocked(_ state: SetupStepState) -> Bool {
        if case .blocked = state { return true }
        return false
    }
}
