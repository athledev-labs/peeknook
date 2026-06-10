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
}
