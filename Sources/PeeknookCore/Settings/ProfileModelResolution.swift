// SPDX-License-Identifier: Apache-2.0

import Foundation

// MARK: - Per-profile model resolution (extends the Phase-3 global shim — no parallel path)

public extension PeeknookSettings {
    /// The answer model for a profile: its binding when usable, else the global ``answerModel``.
    /// Built-ins carry no binding, so they resolve global — byte-identical to pre-profiles.
    func answerModel(for profile: GroundProfile) -> ModelReference {
        guard let binding = profile.modelBinding, binding.hasUsableTag else { return answerModel }
        return binding.modelReference
    }

    /// The endpoint for a profile, derived from the BINDING's backend (never the global
    /// `answerBackend`) so a bound model can't be sent to the wrong server. v1 lean: an
    /// `.openAICompatible` binding reuses the global server fields + the primary key ref —
    /// per-profile server/credential is the reserved seam (`CredentialRef.openAICompatible(profileID:)`).
    func endpoint(for profile: GroundProfile) -> InferenceEndpoint {
        guard let binding = profile.modelBinding, binding.hasUsableTag else { return activeEndpoint }
        switch binding.backend {
        case .ollama:
            return .ollama(
                baseURL: ollamaBaseURL,
                acceptInsecureRemote: acceptInsecureRemoteOllama
            )
        case .openAICompatible:
            return .openAICompatible(
                baseURL: openAICompatibleBaseURL,
                apiKeyRef: .openAICompatiblePrimary,
                acceptInsecureRemote: acceptInsecureRemoteOpenAICompatible
            )
        }
    }
}
