// SPDX-License-Identifier: Apache-2.0

import NookApp
import SwiftUI

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
