// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Trims conversation turns sent to inference when the model context window is nearly full.
public enum ContextBudgetPolicy: Sendable {
    /// At critical pressure, keep only the most recent turns that still ground the latest answer.
    public static func trimmedConversation(
        _ conversation: [ChatTurn],
        pressure: SessionOrchestrator.ContextPressure
    ) -> [ChatTurn] {
        guard pressure == .critical, conversation.count > 4 else { return conversation }
        guard let lastAssistant = conversation.lastIndex(where: \.isAssistant) else {
            return Array(conversation.suffix(4))
        }
        var kept: [ChatTurn] = []
        if let lastImage = conversation[..<lastAssistant].lastIndex(where: \.isImage) {
            kept.append(conversation[lastImage])
        }
        kept.append(contentsOf: conversation[lastAssistant...])
        return kept.isEmpty ? Array(conversation.suffix(4)) : kept
    }
}
