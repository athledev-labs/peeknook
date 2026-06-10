// SPDX-License-Identifier: Apache-2.0

import Foundation

@MainActor
extension SessionOrchestrator {
    private var isContextBlocked: Bool { contextPressure == .critical }

    /// Hotkey / compact affordance entry: capture → preview → infer. Starts a fresh chat only when
    /// there is no answered thread yet; otherwise appends the screenshot to the current session.
    public func beginCapture() {
        switch phase {
        case .idle, .result:
            let intent: CaptureIntent = hasConversation ? .addToChat : .fresh
            if intent == .addToChat, isContextBlocked {
                if case .idle = phase {
                    emitNotice(.contextFull)
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
    public func retake() {
        guard case .result = phase else { return }
        startCapture(intent: .fresh)
    }

    /// Capture a new screenshot and **add** it to the current chat (continue with another image).
    public func addImage() {
        guard case .result = phase, !isContextBlocked else { return }
        startCapture(intent: .addToChat)
    }

    /// Leave the result view for the calm home screen while keeping the thread for resume.
    public func finishChat() {
        guard case .applied = applyPhaseEvent(.finishChat) else { return }
        lifecycle.suggestionTask?.cancel()
        streamedAnswer = ""
        lifecycle.clearPendingCapture()
        suggestedFollowUps = []
        isFetchingSuggestions = false
    }

    /// Return to the last answer when a finished chat is still in memory.
    public func resumeChat() {
        _ = applyPhaseEvent(.resumeChat(answer: lastAssistantText ?? ""))
    }

    /// Discard the current thread and return to idle.
    public func startNewChat() {
        sessionBrief = ""
        dismissResult()
    }

    /// Clear the chat and return to idle, ready for a fresh capture.
    public func restart() {
        startNewChat()
    }

    /// Retry after a failure, re-runs a fresh capture (which re-checks setup readiness).
    public func retryAfterFailure() {
        guard case .failed = phase else { return }
        startCapture(intent: .fresh)
    }

    private func startCapture(intent: CaptureIntent) {
        setup?.refreshCapturePermission()
        if let setup, !setup.isReady {
            _ = applyPhaseEvent(.setupNotReady)
            return
        }
        abortSessionWork()
        lifecycle.pendingIntent = intent
        streamedAnswer = ""
        stopSpeechOutput()
        guard case .applied = applyPhaseEvent(.beginCapture) else { return }
        let generation = lifecycle.snapshotCapture()

        lifecycle.inferenceTask = Task {
            do {
                let provider = try captureRegistry.resolve(resolvedActiveProfile.primaryGround)
                let result = try await provider.capture(scope: settings.captureScope, quick: settings.quickMode)
                guard lifecycle.isCurrentCapture(generation), !Task.isCancelled else { return }
                lifecycle.pendingCapture = result
                lifecycle.pendingPreview = CapturePreview(capture: result)
                if settings.previewBeforeInfer, let preview = lifecycle.pendingPreview {
                    _ = applyPhaseEvent(.capturePreviewing(preview))
                } else {
                    commitCapture(result, intent: intent)
                }
            } catch is CancellationError {
                return
            } catch let error as CaptureError {
                guard lifecycle.isCurrentCapture(generation) else { return }
                _ = applyPhaseEvent(.captureFailed(.from(captureError: error)))
            } catch {
                guard lifecycle.isCurrentCapture(generation) else { return }
                _ = applyPhaseEvent(.captureFailed(.generic(message: error.localizedDescription)))
            }
        }
    }

    public func confirmPreview() {
        guard case .previewing = phase, let capture = lifecycle.pendingCapture else { return }
        commitCapture(capture, intent: lifecycle.pendingIntent)
    }

    /// Appends the confirmed screenshot as an image turn (resetting first for a fresh chat) and
    /// runs the answer.
    func commitCapture(_ capture: CaptureResult, intent: CaptureIntent) {
        if intent == .fresh { resetConversation() }
        turnCounter += 1
        let stored = storedCapture(capture)
        conversation.append(ChatTurn(id: turnCounter, kind: .image(stored)))
        lifecycle.inferenceTask = Task { await runTurn(capturedNow: capture) }
    }

    /// Ask a follow-up about the chat so far, reuses the screenshots already in the model's
    /// context. Only valid once an answer is on screen.
    public func sendFollowUp(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, case .result = phase, !conversation.isEmpty, !isContextBlocked else { return }
        lifecycle.cancelInferenceAndSuggestions()
        suggestedFollowUps = []
        isFetchingSuggestions = false
        turnCounter += 1
        conversation.append(ChatTurn(id: turnCounter, kind: .user(text)))
        lifecycle.inferenceTask = Task { await runTurn(capturedNow: nil) }
    }

    /// Pre-load the model when the notch opens so the user's first capture is warm, not cold.
    /// Idempotent and cheap; no-op when already warm or in flight.
    public func prewarm() {
        guard !modelLikelyWarm, !isPrewarming else { return }
        if let setup, !setup.isReady { return }
        isPrewarming = true
        Task {
            // Endpoint-typed so a backend switch warms the server the next turn actually hits,
            // never a stale Ollama URL.
            let loaded = await inference.warmUp(
                model: activeAnswerModel.tag,
                endpoint: activeInferenceEndpoint
            )
            if loaded { lastInferenceAt = Date() }
            isPrewarming = false
        }
    }

    public func cancel() {
        abortSessionWork()
        streamedAnswer = ""
        stopVoiceInput()
        stopSpeechOutput()
        if hasConversation {
            if let last = conversation.last, !last.isAssistant { conversation.removeLast() }
            suggestedFollowUps = []
            _ = applyPhaseEvent(.cancelPreservingResult(answer: lastAssistantText ?? ""))
            return
        }
        lifecycle.clearPendingCapture()
        resetConversation()
        _ = applyPhaseEvent(.cancelToIdle)
    }

    public func dismissResult() {
        abortSessionWork()
        streamedAnswer = ""
        lifecycle.clearPendingCapture()
        sessionBrief = ""
        discardActiveThread()
        resetConversation()
        _ = applyPhaseEvent(.dismissToIdle)
    }

    /// Cancel any in-flight capture, inference, web-lookup, or suggestion work and bump the session
    /// generations so a late async completion can't mutate state after the user moved on. Also the
    /// teardown backstop for the live camera: every exit that aborts session work (cancel, dismiss,
    /// open-thread, delete-thread, new capture) stops the preview too.
    func abortSessionWork() {
        lifecycle.invalidateAllWork()
        stopCameraPreview()
        isFetchingSuggestions = false
        isFetchingWebLookup = false
    }

    /// Surface a transient, one-shot signal to the UI (see ``SessionNotice``).
    func emitNotice(_ notice: SessionNotice) {
        lastNotice = notice
        noticeToken += 1
    }

    /// Clear the last notice once the UI has presented it.
    public func clearNotice() {
        lastNotice = nil
    }

    /// Clears the in-memory chat and forgets its archive identity (without deleting the archived
    /// thread) so the next answered chat is filed as a new entry.
    func resetConversation() {
        purgeSessionBlobs()
        conversation = []
        suggestedFollowUps = []
        isFetchingSuggestions = false
        webLookupSnapshot = nil
        isFetchingWebLookup = false
        turnCounter = 0
        lastPromptTokens = nil
        activeThreadID = nil
        activeThreadCreatedAt = nil
        stopVoiceInput()
        stopSpeechOutput()
    }
}
