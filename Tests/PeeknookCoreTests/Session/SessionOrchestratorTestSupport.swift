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
}
