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

    /// The active profile's prompt template, sanitized, for `InferenceRequest`'s `profileTemplate`.
    /// Nil unless the user wrote one — requests stay byte-identical to the pre-template behavior.
    var activeProfileTemplate: String? {
        ProfileTemplate.sanitized(resolvedActiveProfile.promptTemplate)
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

    /// The model role this turn routes to. A pure text follow-up (no new capture) takes the
    /// `.textOnly` role ONLY when the user opted in (`fastTextFollowUps`) AND a text model is
    /// configured; otherwise — and for every capture / Add-image turn — the `.primaryVision` role.
    /// Keyed off the opt-in, never off whether an image payload happens to be present, so an
    /// unreadable or pruned blob can never silently route a follow-up to a blind text model.
    func turnRole(forFollowUp isFollowUp: Bool) -> ModelRole {
        (isFollowUp && settings.fastTextFollowUps && settings.hasUsableTextOnlyModel)
            ? .textOnly : .primaryVision
    }

    /// The model + endpoint for a role, resolved against the active profile — matching how
    /// ``activeAnswerModel`` / ``activeInferenceEndpoint`` resolve, so the `.primaryVision` route is
    /// byte-identical to pre-router behavior (including for camera turns, which resolve their model
    /// off the active profile today, not the camera-gating literal).
    func routing(for role: ModelRole) -> RoleResolution {
        settings.resolved(role: role, for: resolvedActiveProfile)
    }

    /// Module read-through for a gating profile (per-profile override layer + global fallback).
    func moduleEnabled(_ id: ModuleID, for profile: GroundProfile) -> Bool {
        Module.isEnabled(id, in: settings, profile: profile)
    }

    /// The command-bar layout overrides the render seam applies for a placement — the SINGLE
    /// resolution choke point all four bars route through (so call sites that hold only the
    /// orchestrator never reach into settings). v1 returns the global bucket for every placement:
    /// layout is global by construction (no profile→layout mapping exists yet). The per-profile
    /// upgrade plugs in HERE — key by `resolvedActiveProfile.id`, merge per-id over the global base —
    /// with zero call-site change, because the apply seam already takes one resolved `[CommandOverride]`.
    public func resolvedCommandOverrides(for placement: CommandPlacement) -> [CommandOverride] {
        _ = placement  // reserved: per-profile / per-placement resolution keys off this later.
        return settings.commandOverrides(forScope: PeeknookSettings.globalCommandScope)
    }

    /// The profile a turn's module gates evaluate against: camera-ground turns use the
    /// `cameraStudy` literal (the single profile-source rule — a screen profile's overrides must
    /// never leak into a camera-shutter turn), everything else the resolved active profile.
    func gatingProfile(forTurnGround ground: Ground?) -> GroundProfile {
        ground == .camera ? .cameraStudy : resolvedActiveProfile
    }

    /// The translation directive a capture turn carries, projected from the same gating profile its
    /// module gates use (so a camera turn under a translate-configured screen profile resolves through
    /// the `cameraStudy` literal and carries NONE — a screen profile's output shaping never leaks into
    /// a camera-shutter turn, exactly like its module overrides). Nil unless the profile set a target
    /// language; the projection keys on the PRESENCE of that data, never on its value (invariant 1).
    func translationDirective(forTurnGround ground: Ground?) -> TranslationDirective? {
        gatingProfile(forTurnGround: ground).outputConfig?.translationDirective
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
