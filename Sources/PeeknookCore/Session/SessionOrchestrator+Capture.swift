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
                // The thread's context window is full, so we can't extend it. From the result view
                // the on-screen banner already explains why add/follow-up are disabled — leave it to
                // the user. From the idle home screen there's no such banner, so a no-op would be a
                // dead key: start a fresh chat instead and tell the UI why via a notice.
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
        guard case .result = phase else { return }
        suggestionTask?.cancel()
        streamedAnswer = ""
        pendingPreview = nil
        pendingCapture = nil
        suggestedFollowUps = []
        isFetchingSuggestions = false
        phase = .idle
    }

    /// Return to the last answer when a finished chat is still in memory.
    public func resumeChat() {
        guard case .idle = phase, hasConversation else { return }
        phase = .result(lastAssistantText ?? "")
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
            phase = .failed(.setupIncomplete)
            return
        }
        // Invalidates any prior capture/inference/suggestion work and bumps both generations, so a
        // pending launch restore or a late stream can't commit over this fresh capture.
        abortSessionWork()
        pendingIntent = intent
        streamedAnswer = ""
        stopSpeechOutput()
        phase = .capturing
        let generation = captureGeneration

        inferenceTask = Task {
            do {
                let result = try await capture.capture(scope: settings.captureScope, quick: settings.quickMode)
                guard generation == captureGeneration, !Task.isCancelled else { return }
                pendingCapture = result
                pendingPreview = CapturePreview(capture: result)
                if settings.previewBeforeInfer, let preview = pendingPreview {
                    phase = .previewing(preview)
                } else {
                    commitCapture(result, intent: intent)
                }
            } catch is CancellationError {
                return
            } catch let error as CaptureError {
                guard generation == captureGeneration else { return }
                phase = .failed(.from(captureError: error))
            } catch {
                guard generation == captureGeneration else { return }
                phase = .failed(.generic(message: error.localizedDescription))
            }
        }
    }

    public func confirmPreview() {
        guard case .previewing = phase, let capture = pendingCapture else { return }
        commitCapture(capture, intent: pendingIntent)
    }

    /// Appends the confirmed screenshot as an image turn (resetting first for a fresh chat) and
    /// runs the answer.
    func commitCapture(_ capture: CaptureResult, intent: CaptureIntent) {
        if intent == .fresh { resetConversation() }
        turnCounter += 1
        conversation.append(ChatTurn(id: turnCounter, kind: .image(capture)))
        inferenceTask = Task { await runTurn(capturedNow: capture) }
    }

    /// Ask a follow-up about the chat so far, reuses the screenshots already in the model's
    /// context. Only valid once an answer is on screen.
    public func sendFollowUp(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, case .result = phase, !conversation.isEmpty, !isContextBlocked else { return }
        inferenceTask?.cancel()
        suggestionTask?.cancel()
        suggestedFollowUps = []
        isFetchingSuggestions = false
        turnCounter += 1
        conversation.append(ChatTurn(id: turnCounter, kind: .user(text)))
        inferenceTask = Task { await runTurn(capturedNow: nil) }
    }

    /// Pre-load the model when the notch opens so the user's first capture is warm, not cold.
    /// Idempotent and cheap; no-op when already warm or in flight.
    public func prewarm() {
        guard !modelLikelyWarm, !isPrewarming else { return }
        if let setup, !setup.isReady { return }
        isPrewarming = true
        Task {
            let loaded = await inference.warmUp(
                model: settings.textModel,
                baseURL: settings.ollamaBaseURL,
                acceptInsecureRemote: settings.acceptInsecureRemoteOllama
            )
            // Only treat the model as warm if the warm-up actually loaded it. A failed warm-up
            // (Ollama down, model missing) must not fake warmth and make the loading copy lie.
            if loaded { lastInferenceAt = Date() }
            isPrewarming = false
        }
    }

    public func cancel() {
        abortSessionWork()
        streamedAnswer = ""
        stopVoiceInput()
        stopSpeechOutput()
        // Stopping mid-extension (a follow-up or an added image) keeps the answered thread -
        // drop only the unanswered tail and return to the last answer.
        if hasConversation {
            if let last = conversation.last, !last.isAssistant { conversation.removeLast() }
            suggestedFollowUps = []
            phase = .result(lastAssistantText ?? "")
            return
        }
        pendingPreview = nil
        pendingCapture = nil
        resetConversation()
        phase = .idle
    }

    public func dismissResult() {
        abortSessionWork()
        streamedAnswer = ""
        pendingPreview = nil
        pendingCapture = nil
        sessionBrief = ""
        discardActiveThread()
        resetConversation()
        phase = .idle
    }

    /// Cancel any in-flight capture, inference, web-lookup, or suggestion work and bump the session
    /// generations so a late async completion (a streaming token, a launch restore, a follow-up)
    /// can't mutate state after the user moved on. Callers own the phase/conversation reset that
    /// follows; this only invalidates work in progress.
    func abortSessionWork() {
        sessionGeneration += 1
        captureGeneration += 1
        inferenceTask?.cancel()
        inferenceTask = nil
        suggestionTask?.cancel()
        suggestionTask = nil
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
