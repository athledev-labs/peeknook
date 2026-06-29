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
        // Done returns to idle. By default Live disarms here. With `livePersistAcrossDone` on, an armed
        // session is KEPT — we only QUIESCE it: cancel the timer AND any in-flight refresh/promote capture
        // leg, but leave `livePolicy`/the rate clocks/the parked frame intact, so Resume re-enters the same
        // armed chat. Cancelling the in-flight legs (not just the timer) is load-bearing: a refresh capture
        // suspended mid-`await` at the instant of Done would otherwise resume at idle and PARK a post-Done
        // screenshot of the home screen — a capture-while-idle. `cancelLiveWork()` cancels all three live
        // tasks but, unlike `stopLiveSession()`, tears down nothing else. Every OTHER exit (New chat,
        // switch/delete thread, purge, collapse/hide) still routes through the full `stopLiveSession()`.
        if settings.livePersistAcrossDone && isLiveArmed {
            liveCoordinator.cancelLiveWork()
            // `cancelLiveWork()` cancelled the timer loop, which for a CAPPED session is ALSO the
            // mandatory auto-disarm watcher. Restart it (deadline-gated) so a session left parked at the
            // idle home still disarms on its own deadline — without this, the watcher stays dead until
            // Resume or the next capture turn, so a walk-away with the nook open would keep the Live chip
            // past the cap. Uncapped sessions stay byte-identical: with `expiresAt == nil` we don't
            // restart, so a quiesced `.manual`/`.timer` session has no loop at idle, exactly as before.
            // For a capped `.timer` session the restarted loop only WATCHES the deadline at idle —
            // `refresh()`'s `.result` guard parks nothing while at the home screen.
            if livePolicy?.expiresAt != nil {
                liveCoordinator.ensureTimerLoopRunning()
            }
        } else {
            stopLiveSession()
        }
        lifecycle.suggestionTask?.cancel()
        streamedAnswer = ""
        lifecycle.clearPendingCapture()
        suggestedFollowUps = []
        isFetchingSuggestions = false
    }

    /// Return to the last answer when a finished chat is still in memory.
    public func resumeChat() {
        // Re-enter the result view. If a persisted Live session was quiesced on Done, restart its timer
        // loop now that we're back in `.result` (the loop/refresh `.result` guards require it). Restart only
        // AFTER the phase flip succeeds. `startTimerLoopIfNeeded()` no-ops for a disarmed or manual-trigger
        // session and re-seeds the pacing clock, so the first post-resume park lands one full interval later.
        if case .applied = applyPhaseEvent(.resumeChat(answer: lastAssistantText ?? "")) {
            liveCoordinator.startTimerLoopIfNeeded()
        }
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
        // A follow-up while a live frame is parked CONSUMES it: the question grounds on the latest
        // screen (one folded image+question turn), not text-only over prior screenshots. Off the live
        // path (not armed, or nothing parked) this branch is skipped and the body below is unchanged.
        if isLiveArmed, lifecycle.pendingLiveCapture != nil {
            suggestedFollowUps = []
            isFetchingSuggestions = false
            liveCoordinator.answerFromPending(note: text)
            return
        }
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
        stopLiveSession()   // New chat / discard returns to idle — disarm (also covers startNewChat).
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

    /// THE single live-session teardown choke point — idempotent and a no-op when not armed. Disarms
    /// the session, cancels the live coordinator's in-flight work (manual refresh, promote, and the
    /// recurring auto-refresh timer), and clears the pending frame. DELIBERATELY NOT folded into
    /// ``abortSessionWork()``: a Retake / Add-image
    /// aborts in-flight work but must NOT disarm Live, so disarm has its own choke point that only the
    /// explicit exits (Stop live, Done, New chat, switch thread, nook-collapse) call.
    public func stopLiveSession() {
        guard isLiveArmed || lifecycle.pendingLiveCapture != nil else { return }
        livePolicy = nil
        lastLiveRefreshAt = nil
        lastAutoResponseAt = nil           // a fresh arm starts with a clean rate clock (first answer immediate)
        liveCoordinator.cancelLiveWork()   // cancel any in-flight refresh / promote / auto-refresh timer
        lifecycle.clearPendingLive()
        hasPendingLiveFrame = false        // lower the observable mirror with the slot it shadows
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
        // A `.fresh` reset REPLACES the thread (Retake, fresh capture). A live frame parked for the old
        // thread must not survive to graft onto the new one via "Answer now" — drop it (and its mirror)
        // WITHOUT disarming (livePolicy is untouched here, so Live stays armed across a Retake, the
        // anti-graft rule). No-op when Live is off (slot already nil, mirror already false), so this stays
        // byte-identical. Distinct from `abortSessionWork`, which must NOT drop the frame (slice 3).
        lifecycle.clearPendingLive()
        hasPendingLiveFrame = false
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
