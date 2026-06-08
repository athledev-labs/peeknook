// SPDX-License-Identifier: Apache-2.0

import PeeknookDesign
import SwiftUI

/// Lightweight expand/collapse trigger for nested settings (e.g. Advanced).
struct PeekSettingsExpandableRow: View {
    let icon: String
    let title: String
    let subtitle: String
    @Binding var isExpanded: Bool

    @Environment(\.nookResolvedTheme) private var theme
    @State private var isHovering = false

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(alignment: .center, spacing: PeekSettingsRowMetrics.rowSpacing) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isHovering ? theme.accent : theme.headerInactiveIcon)
                    .frame(width: PeekSettingsRowMetrics.iconWidth)

                VStack(alignment: .leading, spacing: 2) {
                    Text(peek: title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isHovering ? theme.accent : theme.primaryLabel.opacity(0.95))
                    Text(peek: subtitle)
                        .font(.system(size: 9, weight: .regular))
                        .foregroundStyle(theme.tertiaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(isHovering ? theme.accent : theme.quaternaryLabel)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: PeekSettingsRowMetrics.trailingColumnWidth, alignment: .trailing)
            }
            .padding(.vertical, PeekSettingsRowMetrics.rowVerticalPadding)
            .contentShape(Rectangle())
            .peekHoverRowHighlight(isHovering)
        }
        .buttonStyle(.borderless)
        .environment(\.peekHoverMotion, .link)
        .peekHoverFeedback($isHovering, motion: .link)
    }
}

/// Choice row for persisted capture defaults (depth, scope, etc.).
struct PeekSettingsMenuRow<MenuContent: View>: View {
    let icon: String
    let title: String
    let detail: String
    let value: String
    @ViewBuilder let menu: (_ close: @escaping () -> Void) -> MenuContent

    @Environment(\.nookResolvedTheme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: PeekSettingsRowMetrics.rowSpacing) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.headerInactiveIcon)
                .frame(width: PeekSettingsRowMetrics.iconWidth)

            VStack(alignment: .leading, spacing: 2) {
                Text(peek: title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.primaryLabel.opacity(0.95))
                Text(peek: detail)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(theme.tertiaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            ValueDropdownPill(symbol: icon, title: value, help: title) { close in
                menu(close)
            }
        }
        .padding(.vertical, PeekSettingsRowMetrics.rowVerticalPadding)
    }
}
