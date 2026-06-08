// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A transient, one-shot signal from the orchestrator to the UI, separate from the persistent
/// ``SessionPhase``. Used for feedback that has no phase of its own — for example telling the user
/// that a capture started a fresh chat because the resumable thread's context window was full.
public enum SessionNotice: Equatable, Sendable {
    /// A capture from the idle home screen started a *new* chat because the resumable thread's
    /// context window is full and can no longer be extended.
    case contextFull
}
