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

    /// Module read-through for a gating profile (per-profile override layer + global fallback).
    func moduleEnabled(_ id: ModuleID, for profile: GroundProfile) -> Bool {
        Module.isEnabled(id, in: settings, profile: profile)
    }

    /// The profile a turn's module gates evaluate against: camera-ground turns use the
    /// `cameraStudy` literal (the single profile-source rule — a screen profile's overrides must
    /// never leak into a camera-shutter turn), everything else the resolved active profile.
    func gatingProfile(forTurnGround ground: Ground?) -> GroundProfile {
        ground == .camera ? .cameraStudy : resolvedActiveProfile
    }

    /// Thread-level archive writes gate on the thread's latest capture ground (camera threads
    /// gate on the literal), so the blob write and the thread save share one verdict and can
    /// never disagree and orphan a blob.
    var archiveWritesEnabled: Bool {
        let lastImageGround = conversation.lazy.reversed().compactMap { turn -> Ground? in
            if case .image(let capture) = turn.kind { return capture.ground }
            return nil
        }.first
        return moduleEnabled(.saveConversation, for: gatingProfile(forTurnGround: lastImageGround))
    }
}
