// SPDX-License-Identifier: Apache-2.0

import Foundation

// MARK: - Per-profile behavior resolution

@MainActor
extension SessionOrchestrator {
    /// The active profile's standing instruction, sanitized, for `InferenceRequest`'s
    /// `agentSystemAppendix`. Nil for built-ins (no instruction) — requests are byte-identical to
    /// the pre-profiles behavior unless the user wrote one.
    var activeAgentAppendix: String? {
        ProfileInstruction.sanitized(resolvedActiveProfile.instruction)
    }

    /// The model the next turn answers with: the active profile's binding, else global.
    var activeAnswerModel: ModelReference {
        settings.answerModel(for: resolvedActiveProfile)
    }

    /// The endpoint the next turn hits, derived from the binding's backend (see
    /// `PeeknookSettings.endpoint(for:)`).
    var activeInferenceEndpoint: InferenceEndpoint {
        settings.endpoint(for: resolvedActiveProfile)
    }
}
