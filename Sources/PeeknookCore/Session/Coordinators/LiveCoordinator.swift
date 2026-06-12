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

    // Slice 6 lands `private var liveTimerTask: Task<Void, Never>?` here. It is deliberately owned by
    // this coordinator — never by `SessionLifecycleCoordinator` — so it survives `abortSessionWork`.

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
}
