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
        /// Not armed, or the trigger is no longer `.timer` (with no live deadline to watch) — tear the
        /// loop down.
        case stop
        /// A refresh is due now: the loop calls `session.refreshLive()` (park only, never infer).
        case park
        /// The mandatory auto-disarm deadline has passed: the loop calls `stopLiveSession()` (the single
        /// disarm choke point). Only ever returned when a non-nil `deadline` was injected (cap > 0), so a
        /// capless session — `deadline == nil`, today's behavior — can never reach it.
        case expire
        /// Not due yet, or paused at critical context — sleep this long, then re-decide. Carries the
        /// *remaining* delay, floored at ``minSleep`` so a near-due tick can't busy-spin.
        case sleep(TimeInterval)
    }

    /// Decide one tick from a flat snapshot of live state. `pressure` is `session.contextPressure`;
    /// `reference` is the loop's pacing clock (seeded at arm, advanced on every park attempt, pulled
    /// forward by a manual refresh); `interval` is the per-tick cadence (already clamped by the caller).
    /// `deadline` is the mandatory auto-disarm instant (``LivePolicy/expiresAt``), or `nil` for no cap
    /// — when `nil`, this is byte-identical to the pre-cap policy (no `.expire` is ever returned). Kept
    /// PURE: `now` and `deadline` are injected (the loop owns the wall clock), so the whole decision
    /// table — `.expire` included — is deterministically testable without a real timer.
    public static func decide(
        armed: Bool,
        trigger: RefreshTrigger,
        pressure: SessionOrchestrator.ContextPressure,
        interval: TimeInterval,
        since reference: Date,
        now: Date,
        deadline: Date? = nil
    ) -> Decision {
        guard armed else { return .stop }
        // Mandatory auto-disarm: a passed deadline overrides EVERYTHING (trigger, pause-at-critical,
        // cadence) — a capped session must end on time even while paused or in manual mode. Checked
        // before the `.timer` guard so the loop, which runs whenever a cap is set (even for a manual
        // trigger, purely to watch this deadline), can `.expire` a manual-trigger session too.
        if let deadline, now >= deadline { return .expire }
        guard trigger == .timer else {
            // No refresh cadence to schedule. With a live deadline the loop must keep ticking purely to
            // watch it, so sleep until the deadline (floored) rather than tearing down. With NO deadline
            // this is the original `.stop` — a capless manual session runs no loop, byte-identical.
            if deadline != nil { return .sleep(boundedByDeadline(.infinity, deadline: deadline, now: now)) }
            return .stop
        }
        // Pause-at-critical: armed but the context window is full. Hold — do not fire, do not drop, do
        // not advance the deadline. Re-poll on a short, interval-independent cadence so the timer
        // resumes promptly once pressure falls below critical (e.g. a Retake onto a smaller screen). A
        // user-triggered path already refuses at critical; this is the automatic mirror of that rule.
        if livePaused(pressure: pressure) { return .sleep(boundedByDeadline(pausePollInterval, deadline: deadline, now: now)) }
        let elapsed = now.timeIntervalSince(reference)
        if elapsed >= interval { return .park }
        // Re-anchor the sleep to the real remaining time so the loop neither busy-spins nor over-sleeps;
        // drift cannot accumulate because every sleep is measured against the same reference. A nearer
        // deadline shortens the sleep so the auto-disarm fires on time rather than after a full interval.
        return .sleep(boundedByDeadline(interval - elapsed, deadline: deadline, now: now))
    }

    /// Floor `delay` at ``minSleep`` and, when a `deadline` is set and nearer, shorten the sleep to it so
    /// the loop wakes to `.expire` on time instead of over-sleeping a full interval/poll past the cap.
    private static func boundedByDeadline(_ delay: TimeInterval, deadline: Date?, now: Date) -> TimeInterval {
        let bounded = deadline.map { min(delay, $0.timeIntervalSince(now)) } ?? delay
        return max(minSleep, bounded)
    }

    /// Whether an armed timer holds (does not fire) this tick. Pauses ONLY at `.critical`
    /// (== `isContextBlocked`); `.high` is a UI warning, not a hard stop, and a park grows no prompt so
    /// there is nothing to overflow. Slice-7 auto-respond will consume this SAME predicate before an
    /// automatic answer, so the pause threshold lives in exactly one place.
    public static func livePaused(pressure: SessionOrchestrator.ContextPressure) -> Bool {
        pressure == .critical
    }

    /// Whether an automatic answer is permitted now under the rate cap (auto-respond, the chatty path).
    /// `last` is the issue-stamp of the previous auto-answer (`SessionOrchestrator.lastAutoResponseAt`);
    /// `nil` means none has fired this armed session, so the first qualifying timed refresh answers
    /// immediately (no warm-up delay). `cap` is the minimum seconds between auto-answer STARTS (clamped to
    /// `>= 1` at arm via ``LivePolicy``). Pure — `now`/`last` injected — so it unit-tests without a clock,
    /// like ``decide``. A user-triggered "Update & ask" never consults this; it bypasses the cap by design.
    public static func autoResponseDue(last: Date?, cap: TimeInterval, now: Date) -> Bool {
        guard let last else { return true }            // first auto-answer of the armed session: fire now
        return now.timeIntervalSince(last) >= cap      // `>=` boundary, matching decide()'s `elapsed >= interval`
    }

    /// Floor for a near-due `.sleep` so the loop can't spin on a sub-tick residual.
    static let minSleep: TimeInterval = 0.05
    /// Re-poll cadence while paused-at-critical, independent of the user's interval.
    static let pausePollInterval: TimeInterval = 1
}
