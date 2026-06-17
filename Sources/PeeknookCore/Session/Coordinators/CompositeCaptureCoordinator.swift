// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Group-oriented capture: the multi-ground fan-out (one hotkey captures several one-shot grounds)
/// and the screen + camera composite, both committed as ONE multi-leg question. Owned by
/// ``SessionOrchestrator`` and held by ``CaptureCoordinator``, which keeps the single-leg spine and
/// hands group decisions here. Reuses the spine's `beginCapturePhase` and the single
/// `runGuardedCapture` failure ladder rather than carrying its own copy.
@MainActor
final class CompositeCaptureCoordinator {
    private weak var session: SessionOrchestrator?
    /// The single-leg coordinator that supplies the shared `beginCapturePhase` and the one
    /// generation-guarded failure ladder (`runGuardedCapture`).
    private weak var spine: CaptureCoordinator?

    init(session: SessionOrchestrator, spine: CaptureCoordinator) {
        self.session = session
        self.spine = spine
    }

    /// The active profile's grounds that can be captured one-shot on the ⌘⇧P hotkey, in commit order
    /// (primary first). One-shot-capturable means the registry has a plain ``CaptureProviding`` that is
    /// NOT an interactive surface: camera (live preview) and file (open panel) are deliberately
    /// excluded — fanning them in would hijack their own flows. `.selectedText` has no standalone
    /// provider (it is folded into the screen capture), so it never appears here. The result always
    /// leads with `primaryGround` when it is itself one-shot-capturable, so the prompt names the legs
    /// in a stable order (screen first), mirroring the composite convention.
    ///
    /// THE systemAudio opt-in gate: `.systemAudio` is excluded UNLESS `settings.systemAudioEnabled`
    /// is on. This is the real precondition for reaching the (unit-untestable) live ScreenCaptureKit
    /// audio tap — a profile can list `.systemAudio`, but the leg is only captured once the user turns
    /// the opt-in on. With the opt-in off, behavior is exactly as today: `.systemAudio` is never
    /// captured, so a screen+audio profile falls back to its single screen leg.
    func oneShotCaptureGrounds(for profile: GroundProfile) -> [Ground] {
        guard let session else { return [] }
        let registry = session.captureRegistry
        let systemAudioEnabled = session.settings.systemAudioEnabled
        let accessibilityTreeEnabled = session.settings.accessibilityTreeEnabled
        func isOneShot(_ ground: Ground) -> Bool {
            // The live system-audio tap stays unreachable until the user enables the opt-in.
            if ground == .systemAudio, !systemAudioEnabled { return false }
            // The live accessibility walk stays unreachable until the user enables its opt-in, so a
            // profile listing `.accessibilityTree` keeps capturing only its other legs until then.
            if ground == .accessibilityTree, !accessibilityTreeEnabled { return false }
            guard let provider = registry.provider(for: ground) else { return false }
            // Interactive providers are NOT one-shot — they drive their own arm/shutter or panel flow.
            return !(provider is any CameraSessionControlling) && !(provider is any FileImporting)
        }
        let primary = profile.primaryGround
        // Stable order: primary first (when capturable), then the rest of the active grounds by their
        // explicit `captureLegOrder` rank so the leg order is intentional and deterministic across
        // launches — reordering the `Ground` enum's cases must not silently reorder capture or prompt.
        let rest = Ground.allCases
            .filter { $0 != primary && profile.activeGrounds.contains($0) && isOneShot($0) }
            .sorted { $0.captureLegOrder < $1.captureLegOrder }
        let leading = isOneShot(primary) ? [primary] : []
        return leading + rest
    }

    /// Capture every one-shot ground of a multi-ground profile and commit them as ONE group.
    /// Like the composite path, this commits directly (no per-leg preview): previewing a single image
    /// would misrepresent a turn that also folds in, say, an audio transcript, and the legs are not
    /// individually confirmable. A partial failure (any leg throws) fails the whole turn — a
    /// multi-ground question that silently drops a leg would answer from less than the user asked.
    func startMultiGroundCapture(grounds: [Ground], intent: SessionOrchestrator.CaptureIntent) {
        guard let session, let spine, spine.beginCapturePhase(intent: intent) else { return }
        let groupID = UUID()
        let registry = session.captureRegistry
        let scope = session.settings.captureScope
        let quick = session.settings.quickMode
        let quality = session.settings.captureQuality
        let generation = session.lifecycle.snapshotCapture()
        session.lifecycle.inferenceTask = Task {
            await spine.runGuardedCapture(generation: generation) {
                let encoding = CaptureEncodingPolicy.resolve(scope: scope, quick: quick, quality: quality)
                var legs: [CaptureResult] = []
                for ground in grounds {
                    let provider = try registry.resolve(ground)
                    let leg = try await provider.capture(scope: scope, quick: quick, encoding: encoding)
                    guard session.lifecycle.isCurrentCapture(generation), !Task.isCancelled else { return }
                    legs.append(leg)
                }
                guard !legs.isEmpty else {
                    _ = session.applyPhaseEvent(.captureFailed(.generic(message: "Nothing was captured.")))
                    return
                }
                self.commitGroup(legs, groupID: groupID, intent: intent)
            }
        }
    }

    // MARK: - Composite (screen + camera in one question)

    /// Begin a composite turn: capture the SCREEN leg first (in `.capturing`), then open the live
    /// camera for the CAMERA leg. The two legs are committed ATOMICALLY at the shutter
    /// (``commitGroupAtShutter``) — nothing reaches the conversation until both are in hand, so an
    /// abort mid-flight leaves no partial turn. Gated on the composite opt-in + both grounds' readiness.
    func beginComposite() {
        guard let session, let spine else { return }
        switch session.phase {
        case .idle, .result: break
        default: return
        }
        guard session.moduleEnabled(.parallelScreen, for: session.resolvedActiveProfile),
              session.captureRegistry.sessionController(for: .camera) != nil else { return }

        session.setup?.refreshCapturePermission()
        if let setup = session.setup, !setup.isReady {
            _ = session.applyPhaseEvent(.setupNotReady) // screen side (Ollama / model / Screen Recording)
            return
        }
        if let setup = session.setup, !setup.readiness(for: .cameraStudy) {
            // Screen readiness passed, so Ollama + model are fine: the gap is Camera TCC. Enter and
            // immediately fail the live phase for the typed Camera recovery (mirrors openCameraLive).
            guard case .applied = session.applyPhaseEvent(.openCameraLive) else { return }
            _ = session.applyPhaseEvent(.cameraLiveFailed(.permissionRequired(.camera)))
            return
        }

        var intent: SessionOrchestrator.CaptureIntent = session.hasConversation ? .addToChat : .fresh
        if intent == .addToChat, session.isContextBlocked {
            guard case .idle = session.phase else { return } // from a full result thread: bail like beginCapture
            session.emitNotice(.contextFull)
            intent = .fresh
        }

        guard spine.beginCapturePhase(intent: intent) else { return } // idle/result → capturing (screen leg)
        let groupID = UUID()
        let registry = session.captureRegistry
        let ground = session.resolvedActiveProfile.primaryGround
        let scope = session.settings.captureScope
        let quick = session.settings.quickMode
        let quality = session.settings.captureQuality
        let generation = session.lifecycle.snapshotCapture()
        session.lifecycle.inferenceTask = Task {
            await spine.runGuardedCapture(generation: generation) {
                let provider = try registry.resolve(ground)
                let encoding = CaptureEncodingPolicy.resolve(scope: scope, quick: quick, quality: quality)
                let screen = try await provider.capture(scope: scope, quick: quick, encoding: encoding)
                guard session.lifecycle.isCurrentCapture(generation), !Task.isCancelled else { return }
                // Open the camera (this aborts/teardowns first — which clears pending composite), THEN
                // stash the screen leg so the shutter can find it.
                session.openCameraLive()
                session.lifecycle.pendingCompositeScreen = screen
                session.lifecycle.pendingCompositeGroupID = groupID
                session.lifecycle.pendingCompositeIntent = intent
            }
        }
    }

    /// Commit a composite's screen + camera legs as one question (screen first, camera second — the
    /// order downstream folding relies on). A thin wrapper over the general N-leg ``commitGroup``.
    func commitGroupAtShutter(
        screen: CaptureResult,
        camera: CaptureResult,
        groupID: UUID,
        intent: SessionOrchestrator.CaptureIntent
    ) {
        commitGroup([screen, camera], groupID: groupID, intent: intent)
    }

    /// Commit an ordered group of capture legs as ONE multi-ground question and run a single turn.
    /// Each leg becomes its own `.image` turn sharing `groupID` (ascending `id` preserves the order
    /// the prompt fold names them in); each leg's archive write gates on its OWN ground inside
    /// `storedCapture`, preserving the per-ground rule. The turn runs on the last VISION-bearing leg
    /// (so the role router resolves to the vision model and the vision gate engages on a screen/camera
    /// leg even when a non-image leg — an audio transcript — was captured last); a group with no image
    /// runs on its last leg. The screen+camera shutter and the screen+audio fan-out both commit here.
    func commitGroup(
        _ legs: [CaptureResult],
        groupID: UUID,
        intent: SessionOrchestrator.CaptureIntent
    ) {
        guard let session, !legs.isEmpty else { return }
        // Prefer the last image leg so the vision gate/model routing key on a real screenshot/photo
        // (a screen+audio group's audio leg has no image); fall back to the last leg for an all-text
        // group. For composite (screen + camera, both images) this is the camera leg, as before.
        let primary = legs.last(where: \.hasVision) ?? legs[legs.count - 1]
        if intent == .fresh { session.resetConversation() }
        for leg in legs {
            session.turnCounter += 1
            session.conversation.append(ChatTurn(
                id: session.turnCounter, kind: .image(session.storedCapture(leg)), compositeGroupID: groupID
            ))
        }
        session.lifecycle.inferenceTask = Task { await session.runTurn(capturedNow: primary) }
    }
}
