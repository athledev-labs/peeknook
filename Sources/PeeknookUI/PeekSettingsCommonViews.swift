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
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(theme.secondaryLabel)
                .frame(width: 88, alignment: .leading)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(valueColor ?? theme.primaryLabel.opacity(0.95))
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 2)
    }
}

struct PeekSettingsTextField: View {
    let label: String
    @Binding var text: String
    var monospaced = false

    @Environment(\.nookResolvedTheme) private var theme
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.tertiaryLabel)
            TextField(label, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .regular, design: monospaced ? .monospaced : .default))
                .foregroundStyle(theme.primaryLabel.opacity(0.95))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(theme.subtleFill.opacity(isFocused ? 0.65 : 0.45), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(theme.subtleStroke.opacity(isFocused ? 0.55 : 0.3), lineWidth: 1)
                )
                .focused($isFocused)
        }
    }
}

struct PeekCaptureShortcutRow: View {
    let hotkey: CaptureHotkey
    let onChange: (CaptureHotkey) -> Void

    @Environment(\.nookResolvedTheme) private var theme
    @State private var isRecording = false
    @State private var eventMonitor: Any?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "keyboard")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.headerInactiveIcon)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text("Capture shortcut")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.primaryLabel.opacity(0.95))
                Text(isRecording ? "Press a shortcut — Esc to cancel" : "Global shortcut — click to change")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(theme.tertiaryLabel)
            }

            Spacer(minLength: 8)

            Button(action: toggleRecording) {
                if isRecording {
                    Text("Listening…")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.primaryLabel.opacity(0.9))
                        .padding(.horizontal, 10)
                        .frame(minHeight: 22)
                        .background(theme.subtleFill.opacity(0.7), in: Capsule())
                        .overlay(Capsule().stroke(theme.accent.opacity(0.6), lineWidth: 1))
                } else {
                    HStack(spacing: 4) {
                        ForEach(Array(hotkey.displaySymbols.enumerated()), id: \.offset) { _, symbol in
                            PeekShortcutKeySquircle(symbol: symbol)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .onDisappear { stopRecording() }
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
