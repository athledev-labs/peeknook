// SPDX-License-Identifier: Apache-2.0

import PeeknookDesign
import PeeknookCore
import SwiftUI

struct PeekHomeAnswerCard: View {
    @Environment(\.nookResolvedTheme) private var theme
    let text: String
    var renderMarkdown: Bool = true
    var spokenRange: NSRange?
    var isReadingAloud: Bool = false
    let showCopy: Bool
    let onCopy: () -> Void
    @State private var isHovered = false
    @State private var didCopy = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HStack(alignment: .top, spacing: 6) {
                if isReadingAloud {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.accent)
                        .symbolEffect(.variableColor.iterative, isActive: isReadingAloud)
                        .peekDecorative()
                }
                AnswerMarkdownText(
                    text: text,
                    renderMarkdown: renderMarkdown,
                    spokenRange: spokenRange
                )
            }
            .padding(.trailing, showCopy ? 22 : 0)

            if showCopy {
                Button {
                    onCopy()
                    didCopy = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { didCopy = false }
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(didCopy ? Color.green : theme.secondaryLabel)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help(didCopy ? "Copied" : "Copy answer")
                .peekAction(label: didCopy ? "Copied" : "Copy answer")
                .opacity(isHovered || didCopy ? 1 : 0.45)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}
