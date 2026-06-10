// SPDX-License-Identifier: Apache-2.0

import Foundation

// The `.cameraLive` flow. Privacy invariant: the camera session must be torn down on EVERY exit
// from `.cameraLive` — shutter, cancel, failure, Done/New chat/open-thread (via `abortSessionWork`),
// and nook-collapse / module switch-away (the host fires `cancelCameraLive()`). All teardown funnels
// through `stopCameraPreview()`, and both that method and `CameraSessionControlling.stopPreview()`
// are idempotent, so the FSM exit path and the host's collapse hook may both fire for one exit.
@MainActor
extension SessionOrchestrator {
    /// ⌘⇧C / the camera command: open the live camera preview. Legal from idle/result/failed.
    /// No-op when no camera provider is registered. Readiness keys on the `camera.study` profile
    /// literal — never the active profile (the single profile-source rule): opening the camera
    /// requires Ollama + a model + Camera TCC, and must NOT demand Screen Recording.
    public func openCameraLive() {
        guard let session = captureRegistry.sessionController(for: .camera) else { return }
        if let setup, !setup.readiness(for: .cameraStudy) {
            if setup.ollamaStep == .complete, setup.modelStep == .complete {
                // Ollama + model are fine, so the missing piece is camera.study's one
                // permission. Enter and immediately fail the live phase so the user gets the
                // typed Camera recovery (Privacy → Camera deep link), not generic setup copy.
                guard case .applied = applyPhaseEvent(.openCameraLive) else { return }
                _ = applyPhaseEvent(.cameraLiveFailed(.permissionRequired(.camera)))
            } else {
                _ = applyPhaseEvent(.setupNotReady)
            }
            return
        }
        guard case .applied = applyPhaseEvent(.openCameraLive) else { return }
        abortSessionWork()
        stopSpeechOutput()
        streamedAnswer = ""
        activeCameraSession = session
        let generation = lifecycle.snapshotCapture()
        lifecycle.cameraTask = Task {
            do {
                try await session.startPreview()
            } catch is CancellationError {
                return
            } catch let error as CaptureError {
                guard lifecycle.isCurrentCapture(generation) else { return }
                stopCameraPreview()
                _ = applyPhaseEvent(.cameraLiveFailed(.from(captureError: error)))
            } catch {
                guard lifecycle.isCurrentCapture(generation) else { return }
                stopCameraPreview()
                _ = applyPhaseEvent(.cameraLiveFailed(.generic(message: error.localizedDescription)))
            }
        }
    }

    /// The Shutter command: grab a still from the live session and feed it into the **unchanged**
    /// commit → runTurn → result pipeline. Tears the preview down *before* leaving the phase.
    public func shutter() {
        guard case .cameraLive = phase, let session = activeCameraSession else { return }
        let intent: CaptureIntent = hasConversation ? .addToChat : .fresh
        lifecycle.pendingIntent = intent
        let generation = lifecycle.snapshotCapture()
        lifecycle.cameraTask = Task {
            do {
                let encoding = CaptureEncodingPolicy.resolve(
                    scope: settings.captureScope,
                    quick: settings.quickMode,
                    quality: settings.captureQuality
                )
                let still = try await session.captureStill(encoding: encoding)
                guard lifecycle.isCurrentCapture(generation), !Task.isCancelled else { return }
                // Teardown before the phase transition; no awaits follow, so cancelling our own
                // task here is harmless and the commit below runs unconditionally.
                stopCameraPreview()
                guard case .applied = applyPhaseEvent(.shutter) else { return }
                commitCapture(still, intent: intent)
            } catch is CancellationError {
                return
            } catch let error as CaptureError {
                guard lifecycle.isCurrentCapture(generation) else { return }
                stopCameraPreview()
                _ = applyPhaseEvent(.cameraLiveFailed(.from(captureError: error)))
            } catch {
                guard lifecycle.isCurrentCapture(generation) else { return }
                stopCameraPreview()
                _ = applyPhaseEvent(.cameraLiveFailed(.generic(message: error.localizedDescription)))
            }
        }
    }

    /// Cancel / Escape from the live preview, and the host's unconditional collapse teardown.
    /// Outside `.cameraLive` the phase event is a no-op and the teardown finds nothing to stop.
    public func cancelCameraLive() {
        stopCameraPreview()
        _ = applyPhaseEvent(.cancelCameraLive)
    }

    /// THE single teardown choke point. Idempotent: a second call finds a cancelled task and a nil
    /// session. Cancels the in-flight camera work first so a late `captureStill` completion can't
    /// commit after the user moved on.
    func stopCameraPreview() {
        lifecycle.cameraTask?.cancel()
        lifecycle.cameraTask = nil
        activeCameraSession?.stopPreview()
        activeCameraSession = nil
    }
}
