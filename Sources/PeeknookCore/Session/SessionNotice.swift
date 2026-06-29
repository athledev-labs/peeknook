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
    /// The ephemeral caption surface ended on its own: the mandatory caption auto-disarm cap fired, or
    /// the audio went silent past the timeout. A one-shot cue so the caption chip's disappearance is
    /// explained (mirrors ``liveEnded`` for the caption surface).
    case captionEnded
    /// Captions were asked to translate over a remote / `:cloud` route, but the active profile has not
    /// opted into remote caption egress (``ProfileOutputConfig/captionAllowRemote``). Captions are
    /// local-only by default — the tap never starts; the user is told to choose a local model or opt in.
    case captionRemoteBlocked
    /// A caption session was requested without a target language. Captions are translated subtitles, so a
    /// target is required; the user is told to set one on the profile.
    case captionNeedsTargetLanguage
    /// `count` likely secrets (API keys, tokens, JWTs, PEM, labeled secrets) were stripped from the
    /// text sent to a remote or `:cloud` model on the turn just answered. Non-blocking — the answer
    /// already streamed; this only tells the user what was withheld. The archived/on-screen text keeps
    /// the original; the screenshot bitmap is not inspected.
    case secretsRedactedForRemote(count: Int)
    /// The selected local model's resident footprint is large relative to the RAM free right now, so
    /// loading it may be slow. A pre-flight heads-up shown before capture; Peeknook also skips
    /// proactively warming such a model. `needGB` is the model's footprint, `totalGB` is the Mac's total
    /// RAM (the copy explains most of it is in use), and `lighterModel` is the display name of a smaller
    /// curated tier the user could switch to, or nil when they're already on the lightest model.
    case modelMayNotFitMemory(needGB: Int, totalGB: Int, lighterModel: String?)
    /// The system hit critical memory pressure while idle, so Peeknook released the resident local model
    /// (`keep_alive: 0`) to give memory back. The next capture pays a one-time cold start. A one-shot cue
    /// so the brief extra latency is explained rather than surprising.
    case modelUnloadedUnderMemoryPressure
}
