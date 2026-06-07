// SPDX-License-Identifier: Apache-2.0

import NookApp
import PeeknookCore
import SwiftUI

/// Renders model answers with lightweight Markdown (bold, lists, code) for the notch HUD.
struct AnswerMarkdownText: View {
    @Environment(\.nookResolvedTheme) private var theme
    let text: String
    var renderMarkdown: Bool = true
    var spokenRange: NSRange?

    var body: some View {
        let displayText = AnswerDisplayText.sanitizedForDisplay(text)
        Group {
            if let spokenRange, let highlighted = Self.readAlongAttributedString(
                from: displayText,
                spokenRange: spokenRange,
                accent: theme.accent,
                primary: theme.primaryLabel
            ) {
                Text(highlighted)
            } else if renderMarkdown, let attributed = Self.attributedMarkdown(from: displayText) {
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

    static func readAlongAttributedString(
        from text: String,
        spokenRange: NSRange,
        accent: Color,
        primary: Color
    ) -> AttributedString? {
        guard spokenRange.location != NSNotFound,
              spokenRange.length > 0,
              let spokenSwiftRange = Range(spokenRange, in: text)
        else { return nil }

        var result = AttributedString()
        if spokenSwiftRange.lowerBound > text.startIndex {
            var before = AttributedString(String(text[..<spokenSwiftRange.lowerBound]))
            before.foregroundColor = primary.opacity(0.45)
            result.append(before)
        }
        var spoken = AttributedString(String(text[spokenSwiftRange]))
        spoken.foregroundColor = accent
        spoken.backgroundColor = accent.opacity(0.16)
        result.append(spoken)
        if spokenSwiftRange.upperBound < text.endIndex {
            var after = AttributedString(String(text[spokenSwiftRange.upperBound...]))
            after.foregroundColor = primary.opacity(0.45)
            result.append(after)
        }
        return result
    }
}
