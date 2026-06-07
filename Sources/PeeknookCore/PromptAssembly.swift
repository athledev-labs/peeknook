// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Per-turn inputs for prompt assembly. Keeps General mode domain-agnostic while leaving a hook
/// for future user-defined agents (`agentSystemAppendix`).
public struct PromptAssembly: Sendable, Equatable {
    public var answerDepth: AnswerDepth
    public var sessionBrief: String?
    public var continuingSession: Bool
    /// Reserved for custom agent / mode packs: appended to the system prompt when non-empty.
    public var agentSystemAppendix: String?

    public init(
        answerDepth: AnswerDepth,
        sessionBrief: String? = nil,
        continuingSession: Bool = false,
        agentSystemAppendix: String? = nil
    ) {
        self.answerDepth = answerDepth
        self.sessionBrief = sessionBrief?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.continuingSession = continuingSession
        self.agentSystemAppendix = agentSystemAppendix?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    public var trimmedBrief: String? { sessionBrief }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
