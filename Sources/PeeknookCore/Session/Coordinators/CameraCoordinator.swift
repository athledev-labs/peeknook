// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The `.cameraLive` flow. Privacy invariant: the camera session must be torn down on EVERY exit
/// from `.cameraLive` — shutter, cancel, failure, Done/New chat/open-thread (via `abortSessionWork`),
/// and nook-collapse / module switch-away (the host fires `cancelCameraLive()`). All teardown funnels
/// through `stopCameraPreview()`, and both that method and `CameraSessionControlling.stopPreview()`
/// are idempotent, so the FSM exit path and the host's collapse hook may both fire for one exit.
/// Owned by ``SessionOrchestrator``; the live session handle (`activeCameraSession`) stays on the
/// facade because the camera view renders from it.
@MainActor
final class CameraCoordinator {
    private weak var session: SessionOrchestrator?

    init(session: SessionOrchestrator) {
        self.session = session
    }

    /// ⌘⇧C / the camera command: open the live camera preview. Legal from idle/result/failed.
    /// No-op when no camera provider is registered. Readiness keys on the `camera.study` profile
    /// literal — never the active profile (the single profile-source rule): opening the camera
    /// requires Ollama + a model + Camera TCC, and must NOT demand Screen Recording.
    func openCameraLive() {
        guard let session else { return }
        guard let cameraSession = session.captureRegistry.sessionController(for: .camera) else { return }
        if let setup = session.setup, !setup.readiness(for: .cameraStudy) {
            if setup.ollamaStep == .complete, setup.modelStep == .complete {
                // Ollama + model are fine, so the missing piece is camera.study's one
                // permission. Enter and immediately fail the live phase so the user gets the
                // typed Camera recovery (Privacy → Camera deep link), not generic setup copy.
                guard case .applied = session.applyPhaseEvent(.openCameraLive) else { return }
                _ = session.applyPhaseEvent(.cameraLiveFailed(.permissionRequired(.camera)))
            } else {
                _ = session.applyPhaseEvent(.setupNotReady)
            }
            return
        }
        guard case .applied = session.applyPhaseEvent(.openCameraLive) else { return }
        session.abortSessionWork()
        session.stopSpeechOutput()
        session.streamedAnswer = ""
        session.activeCameraSession = cameraSession
        let generation = session.lifecycle.snapshotCapture()
        session.lifecycle.cameraTask = Task {
            do {
                try await cameraSession.startPreview()
            } catch is CancellationError {
                return
            } catch let error as CaptureError {
                guard session.lifecycle.isCurrentCapture(generation) else { return }
                self.stopCameraPreview()
                _ = session.applyPhaseEvent(.cameraLiveFailed(.from(captureError: error)))
            } catch {
                guard session.lifecycle.isCurrentCapture(generation) else { return }
                self.stopCameraPreview()
                _ = session.applyPhaseEvent(.cameraLiveFailed(.generic(message: error.localizedDescription)))
            }
        }
    }

    /// The Shutter command: grab a still from the live session and feed it into the **unchanged**
    /// commit → runTurn → result pipeline. Tears the preview down *before* leaving the phase.
    func shutter() {
        guard let session, case .cameraLive = session.phase,
              let cameraSession = session.activeCameraSession else { return }
        let intent: SessionOrchestrator.CaptureIntent = session.hasConversation ? .addToChat : .fresh
        session.lifecycle.pendingIntent = intent
        let generation = session.lifecycle.snapshotCapture()
        session.lifecycle.cameraTask = Task {
            do {
                let encoding = CaptureEncodingPolicy.resolve(
                    scope: session.settings.captureScope,
                    quick: session.settings.quickMode,
                    quality: session.settings.captureQuality
                )
                let still = try await cameraSession.captureStill(encoding: encoding)
                guard session.lifecycle.isCurrentCapture(generation), !Task.isCancelled else { return }
                // Teardown before the phase transition; no awaits follow, so cancelling our own
                // task here is harmless and the commit below runs unconditionally.
                self.stopCameraPreview()
                guard case .applied = session.applyPhaseEvent(.shutter) else { return }
                session.commitCapture(still, intent: intent)
            } catch is CancellationError {
                return
            } catch let error as CaptureError {
                guard session.lifecycle.isCurrentCapture(generation) else { return }
                self.stopCameraPreview()
                _ = session.applyPhaseEvent(.cameraLiveFailed(.from(captureError: error)))
            } catch {
                guard session.lifecycle.isCurrentCapture(generation) else { return }
                self.stopCameraPreview()
                _ = session.applyPhaseEvent(.cameraLiveFailed(.generic(message: error.localizedDescription)))
            }
        }
    }

    /// Cancel / Escape from the live preview, and the host's unconditional collapse teardown.
    /// Outside `.cameraLive` the phase event is a no-op and the teardown finds nothing to stop.
    func cancelCameraLive() {
        stopCameraPreview()
        _ = session?.applyPhaseEvent(.cancelCameraLive)
    }

    /// THE single teardown choke point. Idempotent: a second call finds a cancelled task and a nil
    /// session. Cancels the in-flight camera work first so a late `captureStill` completion can't
    /// commit after the user moved on.
    func stopCameraPreview() {
        guard let session else { return }
        session.lifecycle.cameraTask?.cancel()
        session.lifecycle.cameraTask = nil
        session.activeCameraSession?.stopPreview()
        session.activeCameraSession = nil
    }
}
