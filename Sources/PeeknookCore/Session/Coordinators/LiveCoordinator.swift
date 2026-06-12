// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The armed live-session flow: a thread that keeps context and can refresh what it sees on a rule the
/// user chose. Owned by ``SessionOrchestrator``; the armed state itself lives on the facade as
/// `livePolicy` (the master control) so the UI can render from it.
///
/// `arm()` seeds the policy from the user's saved preferences and `stop()` funnels through the
/// orchestrator's single disarm choke point. The in-flight work (`refreshTask`, `promoteTask`,
/// `timerTask`) is PRIVATE here and deliberately NOT in `lifecycle.invalidateAllWork()` — so a Retake's
/// `abortSessionWork` (which bumps generations and cancels inference/camera tasks) must not cancel it.
/// Only ``SessionOrchestrator/stopLiveSession()`` may, via ``cancelLiveWork()``.
@MainActor
final class LiveCoordinator {
    private weak var session: SessionOrchestrator?

    /// The in-flight manual-refresh capture. Owned HERE — never by `SessionLifecycleCoordinator` — so
    /// `abortSessionWork` (a Retake / Add image) does NOT cancel it; only ``stopLiveSession()`` via
    /// ``cancelLiveWork()`` does. The recurring `timerTask` sits beside it under the same rule.
    private var refreshTask: Task<Void, Never>?

    /// The in-flight "Update & ask" capture leg (capture-then-promote), kept SEPARATE from
    /// `refreshTask` so a parked-frame refresh and a one-press refresh+answer never clobber each other's
    /// capture. Same ownership rule: survives `abortSessionWork`, cancelled only by ``cancelLiveWork()``.
    /// The promoted turn's INFERENCE runs on `lifecycle.inferenceTask` (abortable), so a Retake mid-answer
    /// cancels the answer while Live stays armed.
    private var promoteTask: Task<Void, Never>?

    /// The repeating auto-refresh loop for a `.timer`-trigger armed session. Owned HERE under the SAME
    /// rule as `refreshTask`/`promoteTask`: it survives `abortSessionWork` (a Retake / Add image keeps
    /// the timer running) and is cancelled ONLY by ``stopLiveSession()`` -> ``cancelLiveWork()``. Each
    /// tick PARKS a frame via the audited manual-refresh path (`session.refreshLive()`) and NEVER infers
    /// — auto-respond (the automatic infer-after-refresh path) is a separate, still-off control.
    private var timerTask: Task<Void, Never>?

    init(session: SessionOrchestrator) {
        self.session = session
    }

    /// Arm a live session from an answered thread. Legal only from `.result` and only when not already
    /// armed. Seeds the transient ``LivePolicy`` from the user's saved preferences; its mere presence
    /// (a non-nil `livePolicy`) is the master "Live" control. No capture or inference happens here.
    func arm() {
        guard let session, case .result = session.phase, !session.isLiveArmed else { return }
        session.livePolicy = LivePolicy(
            refresh: session.settings.liveRefreshTrigger,
            autoRespond: session.settings.liveAutoRespond,
            rateCap: max(1, session.settings.liveRateCapSeconds),
            timerInterval: max(1, session.settings.liveTimerIntervalSeconds)   // snapshot + clamp at arm, like rateCap
        )
        startTimerLoopIfNeeded()   // no-op unless the snapshot's trigger is .timer
    }

    /// Disarm via the orchestrator's single teardown choke point (idempotent, no-op when not armed).
    func stop() {
        session?.stopLiveSession()
    }

    /// Manual "Refresh" (also the timer's per-tick park): grab the latest primary-vision frame into the
    /// armed chat's PENDING context. It does NOT append a turn, run inference, or change phase — the frame
    /// waits in `lifecycle.pendingLiveCapture` for "Update & ask" / auto-respond to promote it. A new
    /// refresh supersedes any in-flight one. A capture failure keeps the session armed and surfaces a
    /// transient notice rather than the `.failed` recovery card (which would leave armed).
    ///
    /// **Generation-guarded** like ``updateAndAsk(note:)``: a Retake / Add-image bumps the session
    /// generation (via `abortSessionWork`) and a `.fresh` Retake REPLACES the thread, so a grab whose
    /// `await` straddled it must be DROPPED rather than parked — otherwise a stale pre-Retake frame would
    /// graft onto the replaced thread via "Answer now" / a follow-up. The timer makes this race routine
    /// (one in-flight grab per interval), so the guard is load-bearing, not defensive.
    func refresh() {
        guard let session, case .result = session.phase, session.isLiveArmed else { return }
        session.setup?.refreshCapturePermission()
        if let setup = session.setup, !setup.isReady { return }   // disabled button already guards; defensive
        let ground = session.resolvedActiveProfile.primaryGround
        guard let provider = session.captureRegistry.provider(for: ground) else { return }
        let scope = session.settings.captureScope
        let quick = session.settings.quickMode
        let quality = session.settings.captureQuality
        let generation = session.lifecycle.snapshotSession()
        refreshTask?.cancel()
        refreshTask = Task {
            do {
                let encoding = CaptureEncodingPolicy.resolve(scope: scope, quick: quick, quality: quality)
                let capture = try await provider.capture(scope: scope, quick: quick, encoding: encoding)
                // Disarm cancels this task and clears the slot; a Retake/Add-image during the grab bumps
                // the generation — drop a stale/late frame rather than park it onto a replaced thread.
                guard !Task.isCancelled, session.isLiveArmed,
                      session.lifecycle.isCurrentSession(generation) else { return }
                session.parkPendingLiveFrame(capture)   // slot + observable mirror, in lockstep
                session.lastLiveRefreshAt = Date()
            } catch is CancellationError {
                return
            } catch {
                // Same generation guard on failure: a grab that straddled a Retake must not raise a
                // confusing "refresh failed" notice on the freshly replaced thread.
                guard !Task.isCancelled, session.isLiveArmed,
                      session.lifecycle.isCurrentSession(generation) else { return }
                session.emitNotice(.liveRefreshFailed)
            }
        }
    }

    /// "Answer now": promote the already-parked frame into an answered turn (no new capture). Optional
    /// `note` (the follow-up composer text) folds into the frame's grounding message. The critical
    /// context-pressure guard runs BEFORE the take, so a full-context bail leaves the frame PARKED to
    /// retry — never consumed-then-dropped. A double press is safe: the atomic take returns nil the
    /// second time.
    func answerFromPending(note: String?) {
        guard let session, case .result = session.phase, session.isLiveArmed else { return }
        guard !session.isContextBlocked else { session.emitNotice(.contextFull); return }
        guard let capture = session.takePendingLiveFrame() else { return }
        promote(capture, note: note)
    }

    /// "Update & ask": grab the latest frame AND answer in one press (skips the preview gate, like
    /// Refresh; never parks the frame). The capture leg is generation-guarded so a Retake/abort during
    /// the grab drops the frame instead of grafting a turn onto a replaced thread.
    func updateAndAsk(note: String?) {
        guard let session, case .result = session.phase, session.isLiveArmed else { return }
        guard !session.isContextBlocked else { session.emitNotice(.contextFull); return }
        session.setup?.refreshCapturePermission()
        if let setup = session.setup, !setup.isReady { return }   // disabled button already guards; defensive
        let ground = session.resolvedActiveProfile.primaryGround
        guard let provider = session.captureRegistry.provider(for: ground) else { return }
        let scope = session.settings.captureScope
        let quick = session.settings.quickMode
        let quality = session.settings.captureQuality
        let generation = session.lifecycle.snapshotSession()
        refreshTask?.cancel()   // supersede an in-flight Refresh so it can't re-park a frame after we answer
        promoteTask?.cancel()
        promoteTask = Task {
            do {
                let encoding = CaptureEncodingPolicy.resolve(scope: scope, quick: quick, quality: quality)
                let capture = try await provider.capture(scope: scope, quick: quick, encoding: encoding)
                // A Retake/abort during the grab bumps the session generation; drop the frame so a stale
                // capture can't graft a turn onto the replaced thread. Disarm fails the armed re-check.
                guard !Task.isCancelled, session.isLiveArmed,
                      session.lifecycle.isCurrentSession(generation) else { return }
                session.lastLiveRefreshAt = Date()
                _ = session.takePendingLiveFrame()   // this fresher grab supersedes any parked refresh — don't leave a stale "Answer now"
                self.promote(capture, note: note)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, session.isLiveArmed else { return }
                session.emitNotice(.liveRefreshFailed)
            }
        }
    }

    /// Start (or restart) the repeating auto-refresh loop for a `.timer`-trigger armed session.
    /// Idempotent: a running loop is replaced. Called from ``arm()`` (the only start site) — NOT from a
    /// settings change, so a mid-session trigger/interval edit is inert until the next arm (the snapshot
    /// model, like `rateCap`). Internal, not private, so a test can drive the real loop with a fast
    /// interval by assigning `session.livePolicy` directly (bypassing arm's >= 1 clamp) and calling this.
    func startTimerLoopIfNeeded() {
        guard let session, session.isLiveArmed, session.livePolicy?.refresh == .timer else { return }
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            // The loop OWNS its pacing clock. `reference` is seeded at arm so the first auto-park lands
            // one interval later (not the instant the user taps Go live), and is advanced on EVERY park
            // ATTEMPT — so a failed grab, a no-op grab while inferring, or an in-flight grab can never
            // make the policy fire on every wake (the busy-spin a `lastLiveRefreshAt`-only clock invites,
            // because that stamp lands only on a *successful* capture). A manual Refresh pulls `reference`
            // forward, which is what resets the countdown. Do NOT "simplify" this to key off
            // `lastLiveRefreshAt` alone — a persistently failing capture would then hot-retry every wake.
            var reference = Date()
            while !Task.isCancelled {
                guard let self, let session = self.session,
                      session.isLiveArmed, let policy = session.livePolicy else { return }
                if let lastRefresh = session.lastLiveRefreshAt, lastRefresh > reference {
                    reference = lastRefresh   // a manual/Update grab resets the countdown for free
                }
                switch LiveRefreshPolicy.decide(
                    armed: session.isLiveArmed,
                    trigger: policy.refresh,
                    pressure: session.contextPressure,
                    interval: policy.timerInterval,
                    since: reference,
                    now: Date()
                ) {
                case .stop:
                    return
                case .sleep(let delay):
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                case .park:
                    // Re-check after the await boundary and BEFORE mutating, matching refresh()/updateAndAsk().
                    guard !Task.isCancelled, session.isLiveArmed else { return }
                    reference = Date()        // advance first → the next decide() returns .sleep(interval), no spin
                    session.refreshLive()     // PARK only via the audited manual-refresh path — never infers
                }
            }
        }
    }

    /// THE single promotion choke point: commit a frame (+ optional note) as an `.addToChat` turn and
    /// answer it, reusing the audited `commitCapture → runTurn` spine (blob-write-once via `storedCapture`,
    /// usage credited via `record(capture:)`). `.addToChat` keeps the armed thread's context — never
    /// `.fresh` (which would reset the conversation). Cancels any in-flight turn first so a press landing
    /// on top of a still-streaming promote can't double-commit or double-count. Slice 7 (auto-respond)
    /// calls this verbatim with `note: nil`.
    private func promote(_ capture: CaptureResult, note: String?) {
        guard let session, case .result = session.phase, session.isLiveArmed, !session.isContextBlocked else { return }
        session.lifecycle.cancelInferenceAndSuggestions()   // serialize: stop a prior in-flight turn before committing
        session.commitCapture(capture, intent: .addToChat, question: note)
    }

    /// Cancel the live-session's own in-flight work — the manual refresh, the promote leg, AND the
    /// recurring auto-refresh timer. Called ONLY from ``stopLiveSession()`` (the disarm choke point) —
    /// never from `abortSessionWork`, so in-thread work (Retake / Add image) leaves Live running. Idempotent.
    func cancelLiveWork() {
        refreshTask?.cancel()
        refreshTask = nil
        promoteTask?.cancel()
        promoteTask = nil
        timerTask?.cancel()
        timerTask = nil
    }
}
