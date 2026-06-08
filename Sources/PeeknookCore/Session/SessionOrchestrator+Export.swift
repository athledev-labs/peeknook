// SPDX-License-Identifier: Apache-2.0

#if canImport(AppKit)
import AppKit
#endif
import Foundation

@MainActor
extension SessionOrchestrator {
    public func copyAnswerToPasteboard() {
        let text = lastAssistantText ?? streamedAnswer
        copyToPasteboard(text)
    }

    /// The whole thread rendered as Markdown, screenshots become a captioned heading, questions
    /// and answers become labeled blocks. For copy/export of a practice session.
    public func conversationMarkdown() -> String {
        var blocks: [String] = []
        for turn in conversation {
            switch turn.kind {
            case .image(let capture):
                blocks.append("### Screenshot · \(capture.targetLabel)")
            case .user(let text):
                blocks.append("**You:** \(text)")
            case .assistant(let text):
                blocks.append("**Peeknook:**\n\n\(text)")
            }
        }
        return blocks.joined(separator: "\n\n")
    }

    public func copyConversationMarkdown() {
        copyToPasteboard(conversationMarkdown())
    }

    public func copyToPasteboard(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(trimmed, forType: .string)
        #endif
    }
}
