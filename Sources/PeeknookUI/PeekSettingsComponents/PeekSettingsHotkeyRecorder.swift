// SPDX-License-Identifier: Apache-2.0

import AppKit
import Carbon.HIToolbox
import NookApp
import PeeknookCore
import SwiftUI

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

struct PeekShortcutRow: View {
    let icon: String
    let title: String
    let detail: String
    let hotkey: CaptureHotkey
    let onChange: (CaptureHotkey) -> Void

    @Environment(\.nookResolvedTheme) private var theme
    @State private var isRecording = false
    @State private var isHovering = false
    @State private var eventMonitor: Any?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.headerInactiveIcon)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.primaryLabel.opacity(0.95))
                Text(isRecording ? "Press a shortcut. Esc to cancel." : detail)
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
        .accessibilityLabel("\(title), currently \(hotkey.displaySymbols.joined(separator: " "))")
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

typealias PeekCaptureShortcutRow = PeekShortcutRow

extension PeekShortcutRow {
    static func capture(hotkey: CaptureHotkey, onChange: @escaping (CaptureHotkey) -> Void) -> PeekShortcutRow {
        PeekShortcutRow(
            icon: "keyboard",
            title: "Capture shortcut",
            detail: "Tap the keys on the right to rebind.",
            hotkey: hotkey,
            onChange: onChange
        )
    }

    static func brief(hotkey: CaptureHotkey, onChange: @escaping (CaptureHotkey) -> Void) -> PeekShortcutRow {
        PeekShortcutRow(
            icon: "text.alignleft",
            title: "Brief shortcut",
            detail: "Opens the session-brief composer from anywhere.",
            hotkey: hotkey,
            onChange: onChange
        )
    }
}
