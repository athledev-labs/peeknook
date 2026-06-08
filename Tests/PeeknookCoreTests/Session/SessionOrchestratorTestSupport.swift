// SPDX-License-Identifier: Apache-2.0

import Foundation
@testable import PeeknookCore

@MainActor
extension SessionOrchestrator {
    /// Poll until `predicate` matches or `timeout` elapses. Fixed sleeps flake on loaded CI runners.
    func waitForPhase(
        timeout: TimeInterval = 3,
        pollNanoseconds: UInt64 = 25_000_000,
        matching predicate: (SessionPhase) -> Bool
    ) async -> SessionPhase {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(phase) { return phase }
            try? await Task.sleep(nanoseconds: pollNanoseconds)
        }
        return phase
    }

    func waitForResult(_ expected: String, timeout: TimeInterval = 3) async -> SessionPhase {
        await waitForPhase(timeout: timeout) { phase in
            if case .result(expected) = phase { return true }
            return false
        }
    }

    /// Negative-assertion counterpart to ``waitForPhase``: poll for `duration`, returning the first
    /// phase that *violates* `predicate` (a leaked task flipping state), or the final phase if it
    /// held the whole time. Robust where a fixed sleep is not — it catches a violation whenever it
    /// surfaces in the window, and never false-fails when the phase legitimately stays put.
    func phaseHolding(
        _ predicate: (SessionPhase) -> Bool,
        for duration: TimeInterval = 0.5,
        pollNanoseconds: UInt64 = 20_000_000
    ) async -> SessionPhase {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            if !predicate(phase) { return phase }
            try? await Task.sleep(nanoseconds: pollNanoseconds)
        }
        return phase
    }
}
