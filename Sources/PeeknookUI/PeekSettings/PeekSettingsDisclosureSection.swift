// SPDX-License-Identifier: Apache-2.0

import PeeknookDesign
import SwiftUI

struct PeekSettingsDisclosureSection<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    @Environment(\.nookResolvedTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: PeekSectionChromeMetrics.headerSpacing) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(theme.quaternaryLabel)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: PeekSectionChromeMetrics.chevronWidth)
                    Text(peek: title)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.quaternaryLabel)
                        .tracking(0.42)
                        .textCase(.uppercase)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, PeekSectionChromeMetrics.contentLeading)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
