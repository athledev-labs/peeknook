// SPDX-License-Identifier: Apache-2.0

import NookApp
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
                    Text(setup.isReady ? "Ready to capture" : "Setup incomplete")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.primaryLabel.opacity(0.95))
                    Text(summaryDetail)
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
                PeekSettingsSetupChip(
                    title: "Recording",
                    status: PeekSettingsSetupChipSupport.statusLabel(for: setup.captureStep),
                    tone: PeekSettingsSetupChipSupport.tone(for: setup.captureStep),
                    action: onOpenSetup
                )
            }

            PeekSettingsCommandRow(
                icon: "arrow.right.circle",
                title: "Get ready",
                subtitle: "Install, permissions, and a test capture",
                action: onOpenSetup
            )
        }
    }

    private var summaryDetail: String {
        if setup.isReady {
            return "Ollama, model, and Screen Recording are set."
        }
        var missing: [String] = []
        if setup.ollamaStep != .complete { missing.append("Ollama") }
        if setup.modelStep != .complete { missing.append("model") }
        if setup.captureStep != .complete { missing.append("Screen Recording") }
        guard !missing.isEmpty else { return "Finish setup before capturing." }
        return "Still needed: \(missing.joined(separator: ", "))."
    }
}
