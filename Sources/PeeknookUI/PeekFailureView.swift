// SPDX-License-Identifier: Apache-2.0

import NookApp
import PeeknookCore
import SwiftUI

/// Reusable failure/recovery surface — glass card with a human title, explanation, and one or
/// two ``RecoveryAction`` buttons. Consumes structured ``SessionFailure`` data; never parses
/// error strings. Actions reuse `NookToolbarButton` so recovery matches the command bar.
struct PeekFailureView: View {
    let failure: SessionFailure
    /// True when a "Try again" capture can run (setup ready). Disables retry-style actions otherwise.
    var canRetry: Bool = true
    let onRecover: (RecoveryAction) -> Void

    @Environment(\.nookResolvedTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(iconTint)
                    .frame(width: 18)
                    .peekDecorative()
                VStack(alignment: .leading, spacing: 3) {
                    Text(failure.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.primaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(failure.message)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = failure.technicalDetail {
                        Text(detail)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(theme.tertiaryLabel)
                            .lineLimit(2)
                            .textSelection(.enabled)
                            .padding(.top, 1)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel(Text("\(failure.title). \(failure.message)"))

            HStack(spacing: 4) {
                action(failure.primaryRecovery, prominent: true)
                if let secondary = failure.secondaryRecovery {
                    action(secondary, prominent: false)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 26)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            theme.subtleFill.opacity(0.28),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(iconTint.opacity(0.28), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func action(_ recovery: RecoveryAction, prominent: Bool) -> some View {
        let isRetry = recovery == .tryAgain
        NookToolbarButton(
            title: recovery.label,
            symbol: recovery.symbol,
            prominent: prominent,
            action: { onRecover(recovery) }
        )
        .disabled(isRetry && !canRetry)
    }

    private var iconName: String {
        switch failure.kind {
        case .setupIncomplete: "wrench.and.screwdriver"
        case .ollamaUnreachable: "bolt.horizontal.circle"
        case .modelMissing: "arrow.down.circle"
        case .captureFailed: "camera.badge.ellipsis"
        case .permissionRequired: "lock.shield"
        case .emptyAnswer: "text.badge.xmark"
        case .generic: "exclamationmark.triangle"
        }
    }

    private var iconTint: Color {
        switch failure.kind {
        case .ollamaUnreachable, .generic, .captureFailed:
            return .orange
        case .modelMissing, .setupIncomplete, .permissionRequired:
            return theme.accent
        case .emptyAnswer:
            return .yellow
        }
    }
}

private extension RecoveryAction {
    var label: String {
        switch self {
        case .tryAgain: "Try again"
        case .openSetup: "Open setup"
        case .checkOllama: "Open Ollama"
        case .downloadModel: "Download model"
        case .switchModel: "Switch model"
        case .openScreenRecordingSettings: "Open settings"
        case .openAccessibilitySettings: "Open settings"
        }
    }

    var symbol: String {
        switch self {
        case .tryAgain: "arrow.clockwise"
        case .openSetup: "arrow.right.circle"
        case .checkOllama: "bolt.horizontal"
        case .downloadModel: "arrow.down.circle"
        case .switchModel: "cpu"
        case .openScreenRecordingSettings, .openAccessibilitySettings: "gearshape"
        }
    }
}
