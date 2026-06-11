// SPDX-License-Identifier: Apache-2.0

import Foundation

// Cross-domain session control: the conversation-lifecycle choke points every domain funnels
// through (finish/resume, cancel, dismiss, reset, abort, notices) and the follow-up turn driver.
// This is facade-level orchestration — it spans capture, inference, speech, camera, and archive —
// so it lives on the orchestrator itself, not in any single coordinator.
@MainActor
extension SessionOrchestrator {
    var isContextBlocked: Bool { contextPressure == .critical }

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
        lifecycle.clearPendingComposite()
        conversation = []
        suggestedFollowUps = []
        isFetchingSuggestions = false
        webLookupSnapshot = nil
        isFetchingWebLookup = false
        turnCounter = 0
        lastPromptTokens = nil
        archiveCoordinator.clearActiveThreadIdentity()
        stopVoiceInput()
        stopSpeechOutput()
    }
}
