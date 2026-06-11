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
        if let lastImageIndex = conversation[..<lastAssistant].lastIndex(where: \.isImage) {
            let lastImage = conversation[lastImageIndex]
            if let group = lastImage.compositeGroupID {
                // Keep the WHOLE composite group atomically: a composite question's prompt asserts two
                // images, so dropping one leg would lie to the model about what it received.
                kept.append(contentsOf: conversation[..<lastAssistant].filter { $0.compositeGroupID == group })
            } else {
                kept.append(lastImage)
            }
        }
        kept.append(contentsOf: conversation[lastAssistant...])
        return kept.isEmpty ? Array(conversation.suffix(4)) : kept
    }
}
