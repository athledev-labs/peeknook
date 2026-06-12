// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The armed live-session flow: a thread that keeps context and (in later slices) can refresh what it
/// sees on a rule the user chose. Owned by ``SessionOrchestrator``; the armed state itself lives on the
/// facade as `livePolicy` (the master control) so the UI can render from it.
///
/// Slice 2 is the skeleton: `arm()` seeds the policy from the user's saved preferences, `stop()` funnels
/// through the orchestrator's single disarm choke point. The future Live refresh timer (slice 6) will be
/// a PRIVATE property here, NOT in `lifecycle.invalidateAllWork()` — so a Retake's `abortSessionWork`
/// (which bumps generations and cancels inference/camera tasks) must not cancel it. Only
/// ``SessionOrchestrator/stopLiveSession()`` may.
@MainActor
final class LiveCoordinator {
    private weak var session: SessionOrchestrator?

    /// The in-flight manual-refresh capture. Owned HERE — never by `SessionLifecycleCoordinator` — so
    /// `abortSessionWork` (a Retake / Add image) does NOT cancel it; only ``stopLiveSession()`` via
    /// ``cancelLiveWork()`` does. Slice 6 adds the recurring timer task beside it under the same rule.
    private var refreshTask: Task<Void, Never>?

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
            rateCap: max(1, session.settings.liveRateCapSeconds)
        )
    }

    /// Disarm via the orchestrator's single teardown choke point (idempotent, no-op when not armed).
    func stop() {
        session?.stopLiveSession()
    }

    /// Manual "Refresh": grab the latest primary-vision frame into the armed chat's PENDING context.
    /// It does NOT append a turn, run inference, or change phase — the frame waits in
    /// `lifecycle.pendingLiveCapture` for "Update & ask" / auto-respond (later slices) to promote it.
    /// A new refresh supersedes any in-flight one. A capture failure keeps the session armed and
    /// surfaces a transient notice rather than the `.failed` recovery card (which would leave armed).
    func refresh() {
        guard let session, case .result = session.phase, session.isLiveArmed else { return }
        session.setup?.refreshCapturePermission()
        if let setup = session.setup, !setup.isReady { return }   // disabled button already guards; defensive
        let ground = session.resolvedActiveProfile.primaryGround
        guard let provider = session.captureRegistry.provider(for: ground) else { return }
        let scope = session.settings.captureScope
        let quick = session.settings.quickMode
        let quality = session.settings.captureQuality
        refreshTask?.cancel()
        refreshTask = Task {
            do {
                let encoding = CaptureEncodingPolicy.resolve(scope: scope, quick: quick, quality: quality)
                let capture = try await provider.capture(scope: scope, quick: quick, encoding: encoding)
                // Disarm cancels this task and clears the slot — drop a late frame rather than restash it.
                guard !Task.isCancelled, session.isLiveArmed else { return }
                session.lifecycle.pendingLiveCapture = capture
                session.lifecycle.pendingLiveCaptureAt = Date()
                session.lastLiveRefreshAt = Date()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, session.isLiveArmed else { return }
                session.emitNotice(.liveRefreshFailed)
            }
        }
    }

    /// Cancel the live-session's own in-flight work. Called ONLY from ``stopLiveSession()`` (the disarm
    /// choke point) — never from `abortSessionWork`, so in-thread work (Retake / Add image) leaves Live
    /// running. Idempotent. Slice 6 also cancels the timer task here.
    func cancelLiveWork() {
        refreshTask?.cancel()
        refreshTask = nil
    }
}
