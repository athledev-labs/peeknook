// SPDX-License-Identifier: Apache-2.0

import PeeknookDesign
import SwiftUI

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
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
