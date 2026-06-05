// SPDX-License-Identifier: Apache-2.0

import NookApp
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
                    .foregroundStyle(isHovering || isExpanded ? theme.accent : theme.headerInactiveIcon)
                    .frame(width: PeekSettingsRowMetrics.iconWidth)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isHovering || isExpanded ? theme.accent : theme.primaryLabel.opacity(0.95))
                    Text(subtitle)
                        .font(.system(size: 9, weight: .regular))
                        .foregroundStyle(theme.tertiaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                HStack(spacing: 4) {
                    Text(isExpanded ? "Hide" : "Show")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(isHovering || isExpanded ? theme.accent : theme.secondaryLabel)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(isHovering || isExpanded ? theme.accent : theme.secondaryLabel)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(theme.subtleFill.opacity(isHovering || isExpanded ? 0.72 : 0.5), in: Capsule(style: .continuous))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(
                            isHovering || isExpanded
                                ? theme.accent.opacity(0.55)
                                : theme.subtleStroke.opacity(0.4),
                            lineWidth: 1
                        )
                )
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                theme.subtleFill.opacity(isHovering || isExpanded ? 0.35 : 0.2),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        isHovering || isExpanded
                            ? theme.accent.opacity(0.35)
                            : theme.subtleStroke.opacity(0.35),
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// Menu-based choice row for persisted capture defaults (depth, scope, etc.).
struct PeekSettingsMenuRow<MenuContent: View>: View {
    let icon: String
    let title: String
    let detail: String
    let value: String
    @ViewBuilder let menu: () -> MenuContent

    @Environment(\.nookResolvedTheme) private var theme
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .center, spacing: PeekSettingsRowMetrics.rowSpacing) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isHovering ? theme.accent : theme.headerInactiveIcon)
                .frame(width: PeekSettingsRowMetrics.iconWidth)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.primaryLabel.opacity(0.95))
                Text(detail)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(theme.tertiaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Menu {
                menu()
            } label: {
                HStack(spacing: 4) {
                    Text(value)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(isHovering ? theme.accent : theme.primaryLabel.opacity(0.92))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(theme.quaternaryLabel)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(theme.subtleFill.opacity(isHovering ? 0.72 : 0.5), in: Capsule(style: .continuous))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(
                            isHovering ? theme.accent.opacity(0.55) : theme.subtleStroke.opacity(0.4),
                            lineWidth: 1
                        )
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, PeekSettingsRowMetrics.rowVerticalPadding)
        .onHover { isHovering = $0 }
    }
}
