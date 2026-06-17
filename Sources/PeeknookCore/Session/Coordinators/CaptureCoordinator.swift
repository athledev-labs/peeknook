// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Screen-capture pipeline: hotkey entry, the capture → (optional preview) → commit flow, and
/// failure retry. Owned by ``SessionOrchestrator``; UI binds to the facade, which delegates here.
/// The camera shutter feeds the same `commitCapture` so both grounds share one commit → runTurn
/// pipeline.
@MainActor
final class CaptureCoordinator {
    private weak var session: SessionOrchestrator?

    /// Group-oriented capture (multi-ground fan-out + screen/camera composite). It reuses this
    /// coordinator's spine (`beginCapturePhase` + `runGuardedCapture`); the single-leg paths stay here.
    private(set) lazy var composite = CompositeCaptureCoordinator(session: requireSession(), spine: self)

    init(session: SessionOrchestrator) {
        self.session = session
    }

    private func requireSession() -> SessionOrchestrator {
        guard let session else { preconditionFailure("CaptureCoordinator outlived its session") }
        return session
    }

    /// Hotkey / compact affordance entry: capture → preview → infer. Starts a fresh chat only when
    /// there is no answered thread yet; otherwise appends the screenshot to the current session.
    func beginCapture() {
        guard let session else { return }
        switch session.phase {
        case .idle, .result:
            let intent: SessionOrchestrator.CaptureIntent = session.hasConversation ? .addToChat : .fresh
            if intent == .addToChat, session.isContextBlocked {
                if case .idle = session.phase {
                    session.emitNotice(.contextFull)
                    startCapture(intent: .fresh)
                }
                return
            }
            startCapture(intent: intent)
        default:
            return
        }
    }

    /// Capture a new screenshot to **replace** the current chat (answer a different screen).
    func retake() {
        guard let session, case .result = session.phase else { return }
        startCapture(intent: .fresh)
    }

    /// Capture a new screenshot and **add** it to the current chat (continue with another image).
    func addImage() {
        guard let session, case .result = session.phase, !session.isContextBlocked else { return }
        startCapture(intent: .addToChat)
    }

    /// Retry after a failure. Re-infers on the last committed screenshot when one exists;
    /// otherwise re-runs capture (which re-checks setup readiness).
    func retryAfterFailure() {
        guard let session, case .failed = session.phase else { return }
        if let capture = pendingOrphanImageCapture() {
            retryInferenceOnCommittedCapture(capture)
            return
        }
        startCapture(intent: .fresh)
    }

    /// Last image turn with no trailing assistant — the orphan left by a post-commit inference failure.
    private func pendingOrphanImageCapture() -> CaptureResult? {
        guard let session, let last = session.conversation.last,
              case .image(let capture) = last.kind else { return nil }
        guard let base64 = session.screenshotBase64(for: capture) else { return nil }
        return CaptureResult(
            text: capture.text,
            sourceLabel: capture.sourceLabel,
            appName: capture.appName,
            windowTitle: capture.windowTitle,
            screenshotBase64: base64,
            ground: capture.ground
        )
    }

    private func retryInferenceOnCommittedCapture(_ capture: CaptureResult) {
        guard let session else { return }
        session.abortSessionWork()
        session.streamedAnswer = ""
        session.stopSpeechOutput()
        session.lifecycle.inferenceTask = Task { await session.runTurn(capturedNow: capture) }
    }

    private func startCapture(intent: SessionOrchestrator.CaptureIntent) {
        guard let session else { return }
        session.setup?.refreshCapturePermission()
        if let setup = session.setup, !setup.isReady {
            routeUnready(setup: setup)
            return
        }
        // A profile can declare MORE than one one-shot-capturable ground (e.g. screen + system audio):
        // capture each on the one hotkey and commit them as ONE multi-ground question. A single
        // capturable ground stays byte-identical to the pre-fan-out path (the common case).
        let grounds = composite.oneShotCaptureGrounds(for: session.resolvedActiveProfile)
        if grounds.count > 1 {
            composite.startMultiGroundCapture(grounds: grounds, intent: intent)
            return
        }
        guard beginCapturePhase(intent: intent) else { return }
        let registry = session.captureRegistry
        let ground = session.resolvedActiveProfile.primaryGround
        let scope = session.settings.captureScope
        let quick = session.settings.quickMode
        let quality = session.settings.captureQuality
        runCapture(intent: intent) {
            let provider = try registry.resolve(ground)
            let encoding = CaptureEncodingPolicy.resolve(scope: scope, quick: quick, quality: quality)
            return try await provider.capture(scope: scope, quick: quick, encoding: encoding)
        }
    }

    /// When capture is blocked but the ONLY gap is a single missing capture permission for the active
    /// profile (Ollama + model are installed), fail straight to the typed permission card
    /// (e.g. "Screen Recording is off" → Open settings) so the hotkey matches the smarter Home banner
    /// instead of the blanket "Finish setup first". Genuinely multi-missing states (Ollama/model not
    /// done, or 2+ permissions off) keep the blanket card. Permissions come from the active profile, so
    /// this generalizes past `screen.default` (mirrors ``CameraCoordinator.openCameraLive``).
    private func routeUnready(setup: SetupCoordinator) {
        guard let session else { return }
        if setup.ollamaStep == .complete, setup.modelStep == .complete {
            let missing = setup.missingActivePermissions
            if missing.count == 1, let permission = missing.first {
                guard case .applied = session.applyPhaseEvent(.beginCapture) else { return }
                _ = session.applyPhaseEvent(.captureFailed(.permissionRequired(permission)))
                return
            }
        }
        _ = session.applyPhaseEvent(.setupNotReady)
    }

    // MARK: - File import (event-scoped, permission-free)

    /// Open-panel entry: a user-picked PDF/image becomes a vision turn through the same
    /// commit → runTurn pipeline as screen and camera. The UI shows the panel and passes the chosen
    /// URL here (cancelling the panel never reaches this, so the phase stays idle). Adds to the current
    /// chat when one exists, else starts fresh — mirroring ``beginCapture()``.
    func beginFileImport(url: URL) {
        guard let session else { return }
        switch session.phase {
        case .idle, .result:
            let intent: SessionOrchestrator.CaptureIntent = session.hasConversation ? .addToChat : .fresh
            if intent == .addToChat, session.isContextBlocked {
                if case .idle = session.phase {
                    session.emitNotice(.contextFull)
                    startFileImport(url: url, intent: .fresh)
                }
                return
            }
            startFileImport(url: url, intent: intent)
        default:
            return
        }
    }

    private func startFileImport(url: URL, intent: SessionOrchestrator.CaptureIntent) {
        guard let session else { return }
        // File import grants its own access via the open panel — no Screen Recording / Camera TCC
        // gate — so it deliberately skips the active-profile readiness check the screen path runs.
        guard let importer = session.captureRegistry.fileImporter(for: .file) else {
            _ = session.applyPhaseEvent(.captureFailed(.generic(message: "File import is unavailable.")))
            return
        }
        guard beginCapturePhase(intent: intent) else { return }
        let scope = session.settings.captureScope
        let quick = session.settings.quickMode
        let quality = session.settings.captureQuality
        runCapture(intent: intent) {
            let encoding = CaptureEncodingPolicy.resolve(scope: scope, quick: quick, quality: quality)
            return try await importer.captureResult(fromFileAt: url, encoding: encoding)
        }
    }

    // MARK: - Shared capture spine

    /// Common pre-capture state reset + phase transition for every ground. Returns false when the
    /// phase machine rejects the transition (the caller must not start the capture task).
    /// Internal so the composite coordinator reuses the same spine instead of duplicating it.
    func beginCapturePhase(intent: SessionOrchestrator.CaptureIntent) -> Bool {
        guard let session else { return false }
        session.abortSessionWork()
        session.lifecycle.pendingIntent = intent
        session.streamedAnswer = ""
        session.stopSpeechOutput()
        guard case .applied = session.applyPhaseEvent(.beginCapture) else { return false }
        return true
    }

    /// THE single capture-failure ladder. Runs `body` and routes its outcome: a cancellation is a
    /// silent no-op; a `CaptureError` fails to the typed recovery; any other error fails generic — but
    /// only while `generation` is still the current capture (a stale leg of an aborted/superseded turn
    /// never touches the phase). The single-leg, multi-ground, and composite paths all share this so
    /// the guarded catch ladder lives in exactly one place. Internal so the composite coordinator
    /// inherits it rather than carrying a copy.
    func runGuardedCapture(generation: Int, _ body: @escaping () async throws -> Void) async {
        guard let session else { return }
        do {
            try await body()
        } catch is CancellationError {
            return
        } catch let error as CaptureError {
            guard session.lifecycle.isCurrentCapture(generation) else { return }
            _ = session.applyPhaseEvent(.captureFailed(.from(captureError: error)))
        } catch {
            guard session.lifecycle.isCurrentCapture(generation) else { return }
            _ = session.applyPhaseEvent(.captureFailed(.generic(message: error.localizedDescription)))
        }
    }

    /// Runs `produce` (the ground-specific "get a `CaptureResult`" step) on the inference task, then
    /// routes the result into the shared preview-or-commit flow with generation-guarded failure paths.
    /// Screen passes a `provider.capture(...)` body; file import passes an `importer.captureResult(...)`
    /// body — everything after the result is identical.
    private func runCapture(
        intent: SessionOrchestrator.CaptureIntent,
        produce: @escaping () async throws -> CaptureResult
    ) {
        guard let session else { return }
        let generation = session.lifecycle.snapshotCapture()
        session.lifecycle.inferenceTask = Task {
            await self.runGuardedCapture(generation: generation) {
                let result = try await produce()
                guard session.lifecycle.isCurrentCapture(generation), !Task.isCancelled else { return }
                session.lifecycle.pendingCapture = result
                session.lifecycle.pendingPreview = CapturePreview(capture: result)
                if session.settings.previewBeforeInfer, let preview = session.lifecycle.pendingPreview {
                    _ = session.applyPhaseEvent(.capturePreviewing(preview))
                } else {
                    self.commitCapture(result, intent: intent)
                }
            }
        }
    }

    func confirmPreview() {
        guard let session, case .previewing = session.phase,
              let capture = session.lifecycle.pendingCapture else { return }
        commitCapture(capture, intent: session.lifecycle.pendingIntent)
    }

    /// Appends the confirmed screenshot as an image turn (resetting first for a fresh chat) and
    /// runs the answer. Shared by the screen pipeline and the camera shutter. `question` is non-nil
    /// only on the live-promotion path (Answer now / Update & ask / a follow-up that consumed a pending
    /// frame): it folds the user's note into the image turn so both ride one grounded message. Every
    /// other caller passes `nil` (default), keeping the committed turn byte-identical.
    func commitCapture(_ capture: CaptureResult, intent: SessionOrchestrator.CaptureIntent, question: String? = nil) {
        guard let session else { return }
        if intent == .fresh { session.resetConversation() }
        session.turnCounter += 1
        let stored = session.storedCapture(capture)
        session.conversation.append(ChatTurn(id: session.turnCounter, kind: .image(stored), question: question?.nilIfEmpty))
        session.lifecycle.inferenceTask = Task { await session.runTurn(capturedNow: capture) }
    }
}
