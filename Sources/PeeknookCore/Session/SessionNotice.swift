// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A transient, one-shot signal from the orchestrator to the UI, separate from the persistent
/// ``SessionPhase``. Used for feedback that has no phase of its own — for example telling the user
/// that a capture started a fresh chat because the resumable thread's context window was full.
public enum SessionNotice: Equatable, Sendable {
    /// A capture from the idle home screen started a *new* chat because the resumable thread's
    /// context window is full and can no longer be extended.
    case contextFull
    /// A History row was opened but its thread file is missing, corrupt, or refused (tamper/downgrade).
    /// The stale index entry is pruned and the user is told, instead of a silent no-op.
    case threadUnavailable
    /// A manual live-session refresh failed to capture the screen. The session stays armed (no
    /// `.failed` recovery card, which would drop the armed state) and the user is told to retry.
    case liveRefreshFailed
    /// The mandatory Live auto-disarm timeout fired: an armed session reached its maximum armed lifetime
    /// (the "Keep watching" cap the user cannot turn off) and disarmed itself. A one-shot cue so the
    /// Live chip's disappearance is explained ("Live ended — tap Go live to continue").
    case liveEnded
    /// `count` likely secrets (API keys, tokens, JWTs, PEM, labeled secrets) were stripped from the
    /// text sent to a remote or `:cloud` model on the turn just answered. Non-blocking — the answer
    /// already streamed; this only tells the user what was withheld. The archived/on-screen text keeps
    /// the original; the screenshot bitmap is not inspected.
    case secretsRedactedForRemote(count: Int)
}
