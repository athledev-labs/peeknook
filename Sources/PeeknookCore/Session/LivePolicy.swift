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
    /// Minimum seconds between auto-responses (completion-stamped). A user-triggered "Update & ask"
    /// bypasses it.
    public var rateCap: TimeInterval
    /// Seconds between automatic `.timer` refreshes. Snapshotted from settings at arm (clamped to >= 1,
    /// like `rateCap`); the timer loop obeys this snapshot, never live settings, so a mid-session
    /// Settings edit can't perturb an in-flight sleep (it takes effect on the next arm). Ignored unless
    /// `refresh == .timer`.
    public var timerInterval: TimeInterval

    public init(
        refresh: RefreshTrigger = .manual,
        autoRespond: Bool = false,
        rateCap: TimeInterval = 5,
        timerInterval: TimeInterval = 5
    ) {
        self.refresh = refresh
        self.autoRespond = autoRespond
        self.rateCap = rateCap
        self.timerInterval = timerInterval
    }
}

public extension PeeknookSettings {
    /// The persisted refresh-trigger preference, projected through ``RefreshTrigger`` (an unknown
    /// stored value reads as `.manual`).
    var liveRefreshTrigger: RefreshTrigger {
        RefreshTrigger(rawValue: liveRefreshTriggerRaw) ?? .manual
    }
}
