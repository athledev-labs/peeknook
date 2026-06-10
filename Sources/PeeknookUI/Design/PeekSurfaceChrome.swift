// SPDX-License-Identifier: Apache-2.0

import PeeknookDesign
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
        .padding(.top, 4)
    }
}

/// Scrollable middle + pinned bottom command row. Keeps footer chrome fixed while content scrolls
/// (with edge fades) once it hits the notch-safe cap from ``PeekPanelLayout``.
struct PeekSurfaceScrollColumn<Content: View, Footer: View>: View {
    let maxScrollHeight: CGFloat
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PeekFadedScrollView(maxHeight: maxScrollHeight) {
                content()
            }
            footer()
                .layoutPriority(1)
        }
    }
}

/// Horizontal pill cluster for surface command bars (date filters, preflight menus, etc.).
struct PeekSurfaceCommandPills<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        PeekScrollView(.horizontal) {
            HStack(spacing: 6) {
                content()
            }
            .padding(.trailing, 2)
        }
    }
}

/// Toggleable surface section with a chevron gutter. Matches ``PeekSettingsDisclosureSection``
/// so drilled-in stats read like Settings: title text and body share the same leading edge.
struct PeekCollapsibleSection<Content: View>: View {
    @Environment(\.nookResolvedTheme) private var theme
    let title: String
    var symbol: String?
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content

    private var contentLeading: CGFloat {
        symbol == nil
            ? PeekSectionChromeMetrics.contentLeading
            : PeekSectionChromeMetrics.contentLeadingWithHeaderIcon
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: PeekSectionChromeMetrics.headerSpacing) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(theme.quaternaryLabel)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: PeekSectionChromeMetrics.chevronWidth)
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
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, contentLeading)
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
    var hint = "Filter stats by date range"
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(LocalizedStringKey(title), bundle: .module)
                .font(.system(size: 9, weight: .regular))
                .lineLimit(1)
                .foregroundStyle(
                    PeekHoverForeground.glassLabel(
                        isHovered: isHovered || isSelected,
                        prominent: isSelected,
                        theme: theme
                    )
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .peekGlass(
                    cornerRadius: 7,
                    isHovered: isHovered || isSelected,
                    prominent: isSelected
                )
        }
        .buttonStyle(.borderless)
        .fixedSize(horizontal: true, vertical: false)
        .peekHoverFeedback($isHovered, motion: isSelected ? .link : nil)
        .peekAction(label: title, hint: hint)
    }
}
