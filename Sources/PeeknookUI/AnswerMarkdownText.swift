// SPDX-License-Identifier: Apache-2.0

import NookApp
import SwiftUI

/// Renders model answers with lightweight Markdown (bold, lists, code) for the notch HUD.
struct AnswerMarkdownText: View {
    @Environment(\.nookResolvedTheme) private var theme
    let text: String

    var body: some View {
        Group {
            if let attributed = Self.attributedMarkdown(from: text) {
                Text(attributed)
            } else {
                Text(text)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(theme.primaryLabel)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func attributedMarkdown(from text: String) -> AttributedString? {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        return try? AttributedString(markdown: text, options: options)
    }
}
