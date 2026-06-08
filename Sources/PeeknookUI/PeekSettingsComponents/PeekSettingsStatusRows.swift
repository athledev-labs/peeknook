// SPDX-License-Identifier: Apache-2.0

import PeeknookDesign
import SwiftUI

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

                Text(peek: title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.primaryLabel.opacity(0.95))
                    .lineLimit(1)

                Spacer(minLength: 0)

                PeekSettingsStatusBadge(text: status, tone: tone)
                    .frame(width: PeekSettingsRowMetrics.trailingColumnWidth, alignment: .trailing)
            }

            if let detail, !detail.isEmpty {
                Text(peek: detail)
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
        Text(peek: text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(tone.badgeForeground(theme: theme))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tone.badgeBackground(theme: theme), in: Capsule(style: .continuous))
    }
}
