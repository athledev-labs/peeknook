// SPDX-License-Identifier: Apache-2.0

import AppKit
import PeeknookDesign
import PeeknookCore
import SwiftUI

/// Compact setup checklist chip, tap opens Get ready when something still needs attention.
struct PeekSettingsSetupChip: View {
    let title: String
    let status: String
    let tone: PeekSettingsStatusTone
    let action: () -> Void

    @Environment(\.nookResolvedTheme) private var theme
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(peek: title)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(theme.secondaryLabel)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: tone.icon)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(tone.tint(theme: theme))
                    Text(peek: status)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(tone.badgeForeground(theme: theme))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                tone.badgeBackground(theme: theme).opacity(isHovering ? 1.1 : 1),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        isHovering ? tone.tint(theme: theme).opacity(0.45) : theme.subtleStroke.opacity(0.35),
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

enum PeekSettingsSetupChipSupport {
    static func tone(for state: SetupStepState) -> PeekSettingsStatusTone {
        switch state {
        case .complete: .ready
        case .pending: .warning
        case .inProgress: .loading
        case .failed: .error
        }
    }

    static func statusLabel(for state: SetupStepState) -> String {
        switch state {
        case .complete: "Done"
        case .pending: "Needed"
        case .inProgress: "Working"
        case .failed: "Fix"
        }
    }
}
