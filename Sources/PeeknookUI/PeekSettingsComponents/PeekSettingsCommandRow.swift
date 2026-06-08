// SPDX-License-Identifier: Apache-2.0

import PeeknookDesign
import SwiftUI

/// Navigation or action row: icon, title + subtitle, trailing chevron or button.
struct PeekSettingsCommandRow: View {
    let icon: String
    let title: String
    let subtitle: String
    var style: PeekSettingsCommandStyle = .standard
    var trailing: PeekSettingsCommandTrailing = .chevron
    let action: () -> Void

    @Environment(\.nookResolvedTheme) private var theme
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: PeekSettingsRowMetrics.rowSpacing) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(iconTint)
                    .frame(width: PeekSettingsRowMetrics.iconWidth)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(titleTint)
                        .multilineTextAlignment(.leading)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 9, weight: .regular))
                        .foregroundStyle(theme.tertiaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)

                trailingControl
                    .frame(width: PeekSettingsRowMetrics.trailingColumnWidth, alignment: .trailing)
            }
            .padding(.vertical, PeekSettingsRowMetrics.rowVerticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var trailingControl: some View {
        switch trailing {
        case .chevron:
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(isHovering ? iconTint : theme.quaternaryLabel)
        case .button(let label):
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(buttonForeground)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(buttonBackground, in: Capsule(style: .continuous))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(buttonStroke, lineWidth: 1)
                )
        }
    }

    private var buttonForeground: Color {
        switch style {
        case .standard:
            isHovering ? theme.accent : theme.primaryLabel.opacity(0.92)
        case .destructive:
            Color.red.opacity(isHovering ? 1 : 0.95)
        }
    }

    private var buttonBackground: Color {
        switch style {
        case .standard:
            theme.subtleFill.opacity(isHovering ? 0.72 : 0.5)
        case .destructive:
            Color.red.opacity(isHovering ? 0.18 : 0.12)
        }
    }

    private var buttonStroke: Color {
        switch style {
        case .standard:
            isHovering ? theme.accent.opacity(0.55) : theme.subtleStroke.opacity(0.4)
        case .destructive:
            Color.red.opacity(isHovering ? 0.55 : 0.35)
        }
    }

    private var iconTint: Color {
        switch style {
        case .standard:
            isHovering ? theme.accent : theme.headerInactiveIcon
        case .destructive:
            Color.red.opacity(0.92)
        }
    }

    private var titleTint: Color {
        switch style {
        case .standard:
            isHovering ? theme.accent : theme.primaryLabel.opacity(0.95)
        case .destructive:
            Color.red.opacity(0.95)
        }
    }
}
