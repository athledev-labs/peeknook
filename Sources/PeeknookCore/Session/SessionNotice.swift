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
}
