// SPDX-License-Identifier: Apache-2.0

import NookApp
import SwiftUI

/// Renders model answers with lightweight Markdown (bold, lists, code) for the notch HUD.
struct AnswerMarkdownText: View {
    @Environment(\.nookResolvedTheme) private var theme
    let text: String
    var renderMarkdown: Bool = true

    var body: some View {
        let displayText = Self.sanitizedForDisplay(text)
        Group {
            if renderMarkdown, let attributed = Self.attributedMarkdown(from: displayText) {
                Text(attributed)
            } else {
                Text(displayText)
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

    /// Models sometimes emit LaTeX even when asked not to; strip common delimiters before render.
    static func sanitizedForDisplay(_ text: String) -> String {
        var output = text
        let patterns: [(String, String)] = [
            (#"\$\s*\\text\{([^}]*)\}\s*\$"#, "$1"),
            (#"\$\s*([^$]+?)\s*\$"#, "$1"),
            (#"\\text\{([^}]*)\}"#, "$1"),
        ]
        for (pattern, template) in patterns {
            output = output.replacingOccurrences(
                of: pattern,
                with: template,
                options: .regularExpression
            )
        }
        return output
    }
}
