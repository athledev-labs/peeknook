// SPDX-License-Identifier: Apache-2.0

import AppKit
import Carbon.HIToolbox
import NookApp
import PeeknookCore
import SwiftUI

// MARK: - Disclosure sections (mirrors OpenNook SettingsView)

struct PeekSettingsDisclosureSection<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    @Environment(\.nookResolvedTheme) private var theme

    private let iconGutter: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(theme.quaternaryLabel)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: iconGutter)
                    SettingsSectionLabel(title)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

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
    }
}

// MARK: - Rows

enum PeekSettingsRowMetrics {
    static let iconWidth: CGFloat = 18
    static let rowSpacing: CGFloat = 10
    static let rowVerticalPadding: CGFloat = 4
    static let trailingColumnWidth: CGFloat = 84
}

enum PeekSettingsCommandStyle {
    case standard
    case destructive
}

enum PeekSettingsCommandTrailing {
    case chevron
    case button(String)
}

enum PeekSettingsStatusTone {
    case loading
    case ready
    case warning
    case error

    var icon: String {
        switch self {
        case .loading: "arrow.triangle.2.circlepath"
        case .ready: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.circle.fill"
        }
    }

    func tint(theme: NookResolvedTheme) -> Color {
        switch self {
        case .loading: theme.headerInactiveIcon
        case .ready: Color.green
        case .warning: Color.orange
        case .error: Color.red.opacity(0.92)
        }
    }

    func badgeForeground(theme: NookResolvedTheme) -> Color {
        switch self {
        case .loading: theme.primaryLabel.opacity(0.9)
        case .ready: Color.green.opacity(0.95)
        case .warning: Color.orange.opacity(0.95)
        case .error: Color.red.opacity(0.95)
        }
    }

    func badgeBackground(theme: NookResolvedTheme) -> Color {
        switch self {
        case .loading: theme.subtleFill.opacity(0.55)
        case .ready: Color.green.opacity(0.14)
        case .warning: Color.orange.opacity(0.14)
        case .error: Color.red.opacity(0.14)
        }
    }
}

/// Read-only status row with a trailing badge. Detail appears below only when needed.
struct PeekSettingsStatusRow: View {
    let icon: String
    let title: String
    let detail: String?
    let status: String
    let tone: PeekSettingsStatusTone

    @Environment(\.nookResolvedTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: PeekSettingsRowMetrics.rowSpacing) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tone.tint(theme: theme))
                    .frame(width: PeekSettingsRowMetrics.iconWidth)

                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.primaryLabel.opacity(0.95))
                    .lineLimit(1)

                Spacer(minLength: 0)

                PeekSettingsStatusBadge(text: status, tone: tone)
                    .frame(width: PeekSettingsRowMetrics.trailingColumnWidth, alignment: .trailing)
            }

            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(tone == .error ? Color.red.opacity(0.9) : theme.tertiaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, PeekSettingsRowMetrics.iconWidth + PeekSettingsRowMetrics.rowSpacing)
            }
        }
        .padding(.vertical, PeekSettingsRowMetrics.rowVerticalPadding)
    }
}

struct PeekSettingsStatusBadge: View {
    let text: String
    let tone: PeekSettingsStatusTone

    @Environment(\.nookResolvedTheme) private var theme

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(tone.badgeForeground(theme: theme))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tone.badgeBackground(theme: theme), in: Capsule(style: .continuous))
    }
}

/// Stacked form field for narrow notch panels: label row, then full-width input.
struct PeekSettingsFormField: View {
    let icon: String
    let title: String
    @Binding var text: String
    var placeholder: String?
    var monospaced = false

    @Environment(\.nookResolvedTheme) private var theme
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isFocused ? theme.accent : theme.headerInactiveIcon)
                    .frame(width: PeekSettingsRowMetrics.iconWidth)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.tertiaryLabel)
            }

            TextField(placeholder ?? title, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .regular, design: monospaced ? .monospaced : .default))
                .foregroundStyle(theme.primaryLabel.opacity(0.95))
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.subtleFill.opacity(isFocused ? 0.65 : 0.45), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(theme.subtleStroke.opacity(isFocused ? 0.55 : 0.3), lineWidth: 1)
                )
                .focused($isFocused)
        }
    }
}

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

/// Boolean setting with a visible trailing toggle pill.
struct PeekSettingsToggleRow: View {
    let icon: String
    let title: String
    let detail: String
    @Binding var isOn: Bool

    @Environment(\.nookResolvedTheme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isOn ? theme.accent : theme.headerInactiveIcon)
                .frame(width: 18)

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

            PeekSettingsTogglePill(isOn: $isOn)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityHint(detail)
    }
}

struct PeekSettingsTogglePill: View {
    @Binding var isOn: Bool

    @Environment(\.nookResolvedTheme) private var theme
    @State private var isHovering = false

    private let trackWidth: CGFloat = 38
    private let trackHeight: CGFloat = 22
    private let knobSize: CGFloat = 16

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
                isOn.toggle()
            }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule(style: .continuous)
                    .fill(isOn ? theme.accent.opacity(0.88) : theme.subtleFill.opacity(0.65))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(
                                isOn
                                    ? theme.accent.opacity(isHovering ? 0.95 : 0.75)
                                    : theme.subtleStroke.opacity(isHovering ? 0.55 : 0.35),
                                lineWidth: 1
                            )
                    )
                    .frame(width: trackWidth, height: trackHeight)

                Circle()
                    .fill(Color.white.opacity(0.96))
                    .shadow(color: .black.opacity(0.12), radius: 0.5, y: 0.5)
                    .frame(width: knobSize, height: knobSize)
                    .padding(3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(isOn ? "On" : "Off")
        .accessibilityHint("Double tap to toggle")
    }
}

struct PeekShortcutKeySquircle: View {
    let symbol: String

    @Environment(\.nookResolvedTheme) private var theme

    var body: some View {
        Text(symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(theme.primaryLabel.opacity(0.92))
            .frame(minWidth: 24, minHeight: 22)
            .background(theme.subtleFill.opacity(0.55), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(theme.subtleStroke.opacity(0.35), lineWidth: 1)
            )
    }
}

struct PeekSettingsValueRow: View {
    let label: String
    let value: String
    var valueColor: Color?

    @Environment(\.nookResolvedTheme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PeekSettingsRowMetrics.rowSpacing) {
            Text(label)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(theme.secondaryLabel)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(valueColor ?? theme.primaryLabel.opacity(0.95))
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }
}

struct PeekCaptureShortcutRow: View {
    let hotkey: CaptureHotkey
    let onChange: (CaptureHotkey) -> Void

    @Environment(\.nookResolvedTheme) private var theme
    @State private var isRecording = false
    @State private var isHovering = false
    @State private var eventMonitor: Any?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "keyboard")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.headerInactiveIcon)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text("Capture shortcut")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.primaryLabel.opacity(0.95))
                Text(isRecording ? "Press a shortcut. Esc to cancel." : "Tap the keys on the right to rebind.")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(theme.tertiaryLabel)
            }

            Spacer(minLength: 8)

            Button(action: toggleRecording) {
                shortcutControl
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Capture shortcut, currently \(hotkey.displaySymbols.joined(separator: " "))")
        .accessibilityHint("Activates to record a new shortcut")
        .onDisappear { stopRecording() }
    }

    @ViewBuilder
    private var shortcutControl: some View {
        if isRecording {
            Text("Listening…")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.primaryLabel.opacity(0.9))
                .padding(.horizontal, 10)
                .frame(minHeight: 26)
                .background(theme.subtleFill.opacity(0.7), in: Capsule())
                .overlay(Capsule().stroke(theme.accent.opacity(0.6), lineWidth: 1))
        } else {
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    ForEach(Array(hotkey.displaySymbols.enumerated()), id: \.offset) { _, symbol in
                        PeekShortcutKeySquircle(symbol: symbol)
                    }
                }

                Text("Change")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isHovering ? theme.accent : theme.secondaryLabel)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(theme.subtleFill.opacity(isHovering ? 0.72 : 0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        isHovering ? theme.accent.opacity(0.55) : theme.subtleStroke.opacity(0.4),
                        lineWidth: 1
                    )
            )
        }
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
                return nil
            }
            if let nook = NookHotkey(event: event) {
                let captured = CaptureHotkey(
                    keyCode: nook.keyCode,
                    carbonModifiers: nook.carbonModifiers,
                    keySymbol: nook.keySymbol
                )
                onChange(captured)
                stopRecording()
            }
            return nil
        }
    }

    private func stopRecording() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
        isRecording = false
    }
}

struct PeekSettingsNote: View {
    let text: String

    @Environment(\.nookResolvedTheme) private var theme

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .regular))
            .foregroundStyle(theme.tertiaryLabel)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Curated vision model picker — friendly names instead of raw Ollama tags.
struct PeekSettingsModelPickerRow: View {
    let currentTag: String
    let recommendedTag: String
    let isInstalled: (String) -> Bool
    let onSelect: (InferenceModelOption) -> Void

    @Environment(\.nookResolvedTheme) private var theme
    @State private var isHovering = false

    private var displayName: String {
        TextModelCatalog.displayName(for: currentTag)
    }

    private var detail: String {
        let memory = SystemProfile.current().physicalMemoryGB
        if isInstalled(currentTag) {
            if currentTag == recommendedTag {
                return "Recommended for your Mac (\(memory) GB RAM)"
            }
            return "Installed on this Mac"
        }
        if currentTag == recommendedTag {
            return "Recommended for your Mac (\(memory) GB RAM) · not downloaded yet"
        }
        return "Not downloaded yet"
    }

    var body: some View {
        HStack(alignment: .center, spacing: PeekSettingsRowMetrics.rowSpacing) {
            Image(systemName: "cpu")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isHovering ? theme.accent : theme.headerInactiveIcon)
                .frame(width: PeekSettingsRowMetrics.iconWidth)

            VStack(alignment: .leading, spacing: 2) {
                Text("Vision model")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.primaryLabel.opacity(0.95))
                Text(detail)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(theme.tertiaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            modelMenu
        }
        .padding(.vertical, PeekSettingsRowMetrics.rowVerticalPadding)
        .onHover { isHovering = $0 }
    }

    private var modelMenu: some View {
        Menu {
            ForEach(TextModelCatalog.offered) { option in
                Button {
                    onSelect(option)
                } label: {
                    HStack(spacing: 6) {
                        Text(option.displayName)
                        if isSelected(option) {
                            Image(systemName: "checkmark")
                        } else if !isInstalled(option.tag) {
                            Image(systemName: "arrow.down.circle")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(displayName)
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

    private func isSelected(_ option: InferenceModelOption) -> Bool {
        OllamaSetupClient.matchesModel(installedNames: [currentTag], wanted: option.tag)
    }
}

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

/// Compact setup checklist chip — tap opens Get ready when something still needs attention.
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
                Text(title)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(theme.secondaryLabel)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: tone.icon)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(tone.tint(theme: theme))
                    Text(status)
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
