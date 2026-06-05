// SPDX-License-Identifier: Apache-2.0

import NookApp
import PeeknookCore
import SwiftUI

// MARK: - Actions

struct NookToolbarButton: View {
    @Environment(\.nookResolvedTheme) private var theme
    let title: String
    let symbol: String
    var hotkey: CaptureHotkey?
    var help: String?
    var prominent = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .regular))
                Text(title)
                    .font(.system(size: 9, weight: .regular))
                    .lineLimit(1)
                if let hotkey {
                    InlineHotkeyKeycaps(symbols: hotkey.displaySymbols, theme: theme)
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .peekGlass(cornerRadius: 7, isHovered: isHovered, prominent: prominent)
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .onHover { isHovered = $0 }
        .help(help ?? defaultHelp(hotkey: hotkey))
    }

    private func defaultHelp(hotkey: CaptureHotkey?) -> String {
        if let hotkey { return "\(title) (\(hotkey.spokenLabel))" }
        return title
    }

    private var foreground: Color {
        prominent ? Color.accentColor : theme.secondaryLabel
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

// MARK: - Preflight dropdowns (icon · value · chevron — each its own glass pill)

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
                    .foregroundStyle(theme.tertiaryLabel)
                Text(title)
                    .font(.system(size: 9, weight: .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(theme.secondaryLabel)
                Image(systemName: "chevron.down")
                    .font(.system(size: 6, weight: .bold))
                    .foregroundStyle(theme.tertiaryLabel)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .peekGlass(cornerRadius: 7, isHovered: isHovered || isOpen)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { isHovered = $0 }
        .help(help ?? title)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                menu { isOpen = false }
            }
            .padding(6)
            .fixedSize(horizontal: true, vertical: false)
        }
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
