// SPDX-License-Identifier: Apache-2.0

import PeeknookDesign
import SwiftUI

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
                Text(peek: title)
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

struct PeekSettingsValueRow: View {
    let label: String
    let value: String
    var valueColor: Color?

    @Environment(\.nookResolvedTheme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PeekSettingsRowMetrics.rowSpacing) {
            Text(peek: label)
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

struct PeekSettingsNote: View {
    let text: String

    @Environment(\.nookResolvedTheme) private var theme

    var body: some View {
        Text(peek: text)
            .font(.system(size: 10, weight: .regular))
            .foregroundStyle(theme.tertiaryLabel)
            .fixedSize(horizontal: false, vertical: true)
    }
}
