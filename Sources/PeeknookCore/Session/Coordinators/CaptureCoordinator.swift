// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Screen-capture pipeline: hotkey entry, the capture → (optional preview) → commit flow, and
/// failure retry. Owned by ``SessionOrchestrator``; UI binds to the facade, which delegates here.
/// The camera shutter feeds the same `commitCapture` so both grounds share one commit → runTurn
/// pipeline.
@MainActor
final class CaptureCoordinator {
    private weak var session: SessionOrchestrator?

    init(session: SessionOrchestrator) {
        self.session = session
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
            _ = session.applyPhaseEvent(.setupNotReady)
            return
        }
        session.abortSessionWork()
        session.lifecycle.pendingIntent = intent
        session.streamedAnswer = ""
        session.stopSpeechOutput()
        guard case .applied = session.applyPhaseEvent(.beginCapture) else { return }
        let generation = session.lifecycle.snapshotCapture()

        session.lifecycle.inferenceTask = Task {
            do {
                let provider = try session.captureRegistry.resolve(session.resolvedActiveProfile.primaryGround)
                let encoding = CaptureEncodingPolicy.resolve(
                    scope: session.settings.captureScope,
                    quick: session.settings.quickMode,
                    quality: session.settings.captureQuality
                )
                let result = try await provider.capture(
                    scope: session.settings.captureScope,
                    quick: session.settings.quickMode,
                    encoding: encoding
                )
                guard session.lifecycle.isCurrentCapture(generation), !Task.isCancelled else { return }
                session.lifecycle.pendingCapture = result
                session.lifecycle.pendingPreview = CapturePreview(capture: result)
                if session.settings.previewBeforeInfer, let preview = session.lifecycle.pendingPreview {
                    _ = session.applyPhaseEvent(.capturePreviewing(preview))
                } else {
                    self.commitCapture(result, intent: intent)
                }
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
    }

    func confirmPreview() {
        guard let session, case .previewing = session.phase,
              let capture = session.lifecycle.pendingCapture else { return }
        commitCapture(capture, intent: session.lifecycle.pendingIntent)
    }

    /// Appends the confirmed screenshot as an image turn (resetting first for a fresh chat) and
    /// runs the answer. Shared by the screen pipeline and the camera shutter.
    func commitCapture(_ capture: CaptureResult, intent: SessionOrchestrator.CaptureIntent) {
        guard let session else { return }
        if intent == .fresh { session.resetConversation() }
        session.turnCounter += 1
        let stored = session.storedCapture(capture)
        session.conversation.append(ChatTurn(id: session.turnCounter, kind: .image(stored)))
        session.lifecycle.inferenceTask = Task { await session.runTurn(capturedNow: capture) }
    }
}
