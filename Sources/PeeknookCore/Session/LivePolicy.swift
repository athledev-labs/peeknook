// SPDX-License-Identifier: Apache-2.0

import Foundation

/// How an armed live session grabs a fresh frame. Raw-String backed so a persisted preference degrades
/// to `.manual` on an unknown future value (never throws → never trips the full settings reset). The
/// timer's interval is a separate `Double` setting, so no enum-with-associated-value ever reaches disk.
public enum RefreshTrigger: String, Codable, Sendable, CaseIterable {
    /// Refresh only when the user asks (the default — zero false triggers).
    case manual
    /// Refresh on a fixed interval while armed.
    case timer
    // case onChange / domainHeuristic — deferred; a raw-String degrade keeps these channels open
    // without shipping inert cases.
}

/// The armed state of a live session: a thread that keeps context and can optionally refresh what it
/// sees on a rule the user chose. **Transient** — a session is armed only by an explicit user toggle
/// and is never persisted (only the *preferences* in ``PeeknookSettings`` survive a restart). Its mere
/// presence (a non-nil `livePolicy` on the orchestrator) is the master "Live" control; `refresh` and
/// `autoRespond` are the two independent sub-controls. Live OFF (nil) is byte-identical to pre-Live.
public struct LivePolicy: Sendable, Equatable {
    public var refresh: RefreshTrigger
    /// Answer automatically after a qualifying refresh (rate-capped). Default off — the user opts into
    /// the chatty path; a refresh otherwise only updates pending context.
    public var autoRespond: Bool
    /// Minimum seconds between auto-responses, **issue-stamped** (measured from the START of the previous
    /// auto-answer, not its completion). This ordering is load-bearing: `runTurn` awaits the model-residency
    /// check before flipping the phase to `.inferring`, so for a brief window an auto-promote has been
    /// issued while the phase is still `.result`; stamping at issue (before `promote`) — together with the
    /// `>= 1` clamp — is what stops a fast timer tick landing in that window from double-issuing. A
    /// user-triggered "Update & ask" bypasses the cap entirely. See `LiveCoordinator.refresh`.
    public var rateCap: TimeInterval
    /// Seconds between automatic `.timer` refreshes. Snapshotted from settings at arm (clamped to >= 1,
    /// like `rateCap`); the timer loop obeys this snapshot, never live settings, so a mid-session
    /// Settings edit can't perturb an in-flight sleep (it takes effect on the next arm). Ignored unless
    /// `refresh == .timer`.
    public var timerInterval: TimeInterval
    /// The mandatory auto-disarm deadline: the wall-clock instant after which the armed session must
    /// disarm even with no user interaction. Snapshotted at arm from `liveMaxArmedSeconds` (like
    /// `timerInterval`) and **pushed forward** on every user interaction (`refresh`/`answerFromPending`/
    /// `updateAndAsk`). `nil` = no cap — exactly today's behavior, so the whole feature is byte-identical
    /// when `liveMaxArmedSeconds == 0`. Read by the pure ``LiveRefreshPolicy/decide(...)`` via an injected
    /// `now`/`deadline`; on expiry the timer loop disarms through the single ``SessionOrchestrator/stopLiveSession()``
    /// choke point. Transient like the rest of the policy (never persisted).
    public var expiresAt: Date?

    public init(
        refresh: RefreshTrigger = .manual,
        autoRespond: Bool = false,
        rateCap: TimeInterval = 5,
        timerInterval: TimeInterval = 5,
        expiresAt: Date? = nil
    ) {
        self.refresh = refresh
        self.autoRespond = autoRespond
        self.rateCap = rateCap
        self.timerInterval = timerInterval
        self.expiresAt = expiresAt
    }
}

public extension PeeknookSettings {
    /// The persisted refresh-trigger preference, projected through ``RefreshTrigger`` (an unknown
    /// stored value reads as `.manual`).
    var liveRefreshTrigger: RefreshTrigger {
        RefreshTrigger(rawValue: liveRefreshTriggerRaw) ?? .manual
    }

    /// The mandatory auto-disarm cap, clamped to ≥ 0 at read time (never at decode, so a hand-edited
    /// negative can't reset settings). `0` = no cap (today's behavior — no deadline snapshot at arm).
    var liveMaxArmedClamped: TimeInterval {
        max(0, liveMaxArmedSeconds)
    }
}
