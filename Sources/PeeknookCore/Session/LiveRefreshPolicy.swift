// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Pure scheduler for an armed live session's automatic refresh. Has no clock of its own — `now`, the
/// interval, and the reference time it measures against are all passed in — so it is fully
/// unit-testable like ``ContextBudgetPolicy``. Inert until the timer loop consumes it: with no caller,
/// adding it is byte-identical (Live off, armed-manual, and armed-timer all behave exactly as before).
///
/// The loop that drives this owns the `reference` clock and advances it on every park ATTEMPT (so a
/// failed grab, a no-op grab while inferring, or an in-flight grab can never make the policy fire on
/// every wake). This policy deliberately does NOT key off `SessionOrchestrator.lastLiveRefreshAt`,
/// because that stamp is written only on a *successful* capture — keying cadence off it would let a
/// persistently failing capture (e.g. a revoked Screen Recording permission) busy-spin the main actor.
/// The loop pulls `reference` forward to `lastLiveRefreshAt` when it is later, which is what makes a
/// manual Refresh reset the countdown — but the policy itself sees only a single, monotonic reference.
public enum LiveRefreshPolicy: Sendable {
    /// What the timer loop should do at this instant.
    public enum Decision: Sendable, Equatable {
        /// Not armed, or the trigger is no longer `.timer` — tear the loop down.
        case stop
        /// A refresh is due now: the loop calls `session.refreshLive()` (park only, never infer).
        case park
        /// Not due yet, or paused at critical context — sleep this long, then re-decide. Carries the
        /// *remaining* delay, floored at ``minSleep`` so a near-due tick can't busy-spin.
        case sleep(TimeInterval)
    }

    /// Decide one tick from a flat snapshot of live state. `pressure` is `session.contextPressure`;
    /// `reference` is the loop's pacing clock (seeded at arm, advanced on every park attempt, pulled
    /// forward by a manual refresh); `interval` is the per-tick cadence (already clamped by the caller).
    public static func decide(
        armed: Bool,
        trigger: RefreshTrigger,
        pressure: SessionOrchestrator.ContextPressure,
        interval: TimeInterval,
        since reference: Date,
        now: Date
    ) -> Decision {
        guard armed, trigger == .timer else { return .stop }
        // Pause-at-critical: armed but the context window is full. Hold — do not fire, do not drop, do
        // not advance the deadline. Re-poll on a short, interval-independent cadence so the timer
        // resumes promptly once pressure falls below critical (e.g. a Retake onto a smaller screen). A
        // user-triggered path already refuses at critical; this is the automatic mirror of that rule.
        if livePaused(pressure: pressure) { return .sleep(pausePollInterval) }
        let elapsed = now.timeIntervalSince(reference)
        if elapsed >= interval { return .park }
        // Re-anchor the sleep to the real remaining time so the loop neither busy-spins nor over-sleeps;
        // drift cannot accumulate because every sleep is measured against the same reference.
        return .sleep(max(minSleep, interval - elapsed))
    }

    /// Whether an armed timer holds (does not fire) this tick. Pauses ONLY at `.critical`
    /// (== `isContextBlocked`); `.high` is a UI warning, not a hard stop, and a park grows no prompt so
    /// there is nothing to overflow. Slice-7 auto-respond will consume this SAME predicate before an
    /// automatic answer, so the pause threshold lives in exactly one place.
    public static func livePaused(pressure: SessionOrchestrator.ContextPressure) -> Bool {
        pressure == .critical
    }

    /// Floor for a near-due `.sleep` so the loop can't spin on a sub-tick residual.
    static let minSleep: TimeInterval = 0.05
    /// Re-poll cadence while paused-at-critical, independent of the user's interval.
    static let pausePollInterval: TimeInterval = 1
}
