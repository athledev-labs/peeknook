// SPDX-License-Identifier: Apache-2.0

import NookApp
import SwiftUI

/// Bottom command row shared by home, stats, and other drilled-in surfaces, same HStack layout
/// and spacing as ``PeekIdleCommandBar`` (fixed below scrollable content, not inside it).
struct PeekSurfaceCommandBar<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
    }
}

/// Horizontal pill cluster for surface command bars (date filters, preflight menus, etc.).
struct PeekSurfaceCommandPills<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                content()
            }
            .padding(.trailing, 2)
        }
    }
}

/// Toggleable surface section, chevron gutter, optional icon, vertical guardrail on content.
/// Matches ``PeekSettingsDisclosureSection`` so drilled-in stats read like Settings.
struct PeekCollapsibleSection<Content: View>: View {
    @Environment(\.nookResolvedTheme) private var theme
    let title: String
    var symbol: String?
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content

    private let iconGutter: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(theme.quaternaryLabel)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: iconGutter)
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.tertiaryLabel)
                            .frame(width: PeekSettingsRowMetrics.iconWidth)
                            .peekDecorative()
                    }
                    Text(LocalizedStringKey(title), bundle: .module)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.primaryLabel)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .peekAction(
                label: title,
                hint: isExpanded ? "Collapse section" : "Expand section"
            )

            if isExpanded {
                HStack(alignment: .top, spacing: 12) {
                    RoundedRectangle(cornerRadius: 0.5, style: .continuous)
                        .fill(theme.subtleStroke.opacity(0.5))
                        .frame(width: 1)

                    content()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, (iconGutter - 1) / 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.18), value: isExpanded)
    }
}

/// Glass command pill for ``PeekSurfaceCommandPills``, matches ``NookToolbarButton`` /
/// ``ValueDropdownPill`` (peekGlass, 9pt label, selected = prominent).
struct PeekSurfaceFilterPill: View {
    @Environment(\.nookResolvedTheme) private var theme
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(LocalizedStringKey(title), bundle: .module)
                .font(.system(size: 9, weight: .regular))
                .lineLimit(1)
                .foregroundStyle(isSelected ? Color.accentColor : theme.secondaryLabel)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .peekGlass(
                    cornerRadius: 7,
                    isHovered: isHovered || isSelected,
                    prominent: isSelected
                )
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .onHover { isHovered = $0 }
        .peekAction(label: title, hint: "Filter stats by date range")
    }
}
