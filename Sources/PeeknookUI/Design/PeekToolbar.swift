// SPDX-License-Identifier: Apache-2.0

import PeeknookDesign
import PeeknookCore
import SwiftUI

// MARK: - Actions

struct NookToolbarButton: View {
    @Environment(\.nookResolvedTheme) private var theme
    let title: String
    var symbol: String? = nil
    var hotkey: CaptureHotkey?
    var help: String?
    var testIdentifier: String?
    var onHoverChange: ((Bool) -> Void)?
    var prominent = false
    var size: Size = .toolbar
    let action: () -> Void
    @State private var isHovered = false

    /// Glass-pill scale. `.toolbar` is the dense top-bar size (default — every existing caller is
    /// byte-identical); `.setup` is the larger first-run CTA size used by the Get-ready checklist.
    enum Size {
        case toolbar
        case setup
        var font: CGFloat { self == .toolbar ? 9 : 11 }
        var hPad: CGFloat { self == .toolbar ? 8 : 10 }
        var vPad: CGFloat { self == .toolbar ? 5 : 6 }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: size.font, weight: .regular))
                }
                Text(LocalizedStringKey(title), bundle: .module)
                    .font(.system(size: size.font, weight: .regular))
                    .lineLimit(1)
                if let hotkey {
                    InlineHotkeyKeycaps(symbols: hotkey.displaySymbols, theme: theme)
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, size.hPad)
            .padding(.vertical, size.vPad)
            .peekGlass(cornerRadius: 7, isHovered: isHovered, prominent: prominent)
        }
        .buttonStyle(.borderless)
        .fixedSize(horizontal: true, vertical: false)
        .peekHoverFeedback($isHovered)
        .onChange(of: isHovered) { _, hovering in onHoverChange?(hovering) }
        .help(help ?? defaultHelp(hotkey: hotkey))
        .peekAction(label: accessibilityLabel, hint: help)
        .peekTestIdentifier(testIdentifier ?? title)
    }

    private func defaultHelp(hotkey: CaptureHotkey?) -> String {
        if let hotkey { return "\(title) (\(hotkey.spokenLabel))" }
        return title
    }

    private var accessibilityLabel: String {
        if let hotkey { return "\(title), \(hotkey.spokenLabel)" }
        return title
    }

    private var foreground: Color {
        PeekHoverForeground.glassLabel(isHovered: isHovered, prominent: prominent, theme: theme)
    }
}

struct InlineHotkeyKeycaps: View {
    let symbols: [String]
    let theme: NookResolvedTheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(symbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.system(size: 7, weight: .regular, design: .rounded))
                    .foregroundStyle(theme.tertiaryLabel)
                    .frame(minWidth: 12, minHeight: 12)
                    .background(
                        Color.white.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 3, style: .continuous)
                    )
            }
        }
    }
}

// MARK: - Preflight dropdowns (icon · value · chevron: each its own glass pill)

struct ValueDropdownPill<MenuContent: View>: View {
    @Environment(\.nookResolvedTheme) private var theme
    let symbol: String
    let title: String
    var help: String?
    @ViewBuilder let menu: (_ close: @escaping () -> Void) -> MenuContent
    @State private var isOpen = false
    @State private var isHovered = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 8, weight: .regular))
                    .foregroundStyle(PeekHoverForeground.dropdownIcon(isHovered: isHovered || isOpen, theme: theme))
                Text(title)
                    .font(.system(size: 9, weight: .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(PeekHoverForeground.dropdownLabel(isHovered: isHovered || isOpen, theme: theme))
                Image(systemName: "chevron.down")
                    .font(.system(size: 6, weight: .bold))
                    .foregroundStyle(PeekHoverForeground.dropdownIcon(isHovered: isHovered || isOpen, theme: theme))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .peekGlass(cornerRadius: 7, isHovered: isHovered || isOpen)
        }
        .buttonStyle(.borderless)
        .fixedSize()
        .peekHoverFeedback($isHovered)
        .help(help ?? title)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text(LocalizedStringKey(help ?? title), bundle: .module))
        .accessibilityValue(Text(verbatim: title))
        .accessibilityHint(Text(peek: "Shows options"))
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                menu { isOpen = false }
            }
            .padding(6)
            .fixedSize(horizontal: true, vertical: false)
        }
        .nookKeepsExpanded(while: $isOpen)
    }
}

struct ValueMenuRow: View {
    let title: String
    var subtitle: String?
    let selected: Bool
    var needsDownload = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
            } else if needsDownload {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 2)
        .contentShape(Rectangle())
    }
}
