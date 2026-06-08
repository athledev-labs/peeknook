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

    func waitForPreviewing(timeout: TimeInterval = 3) async -> SessionPhase {
        await waitForPhase(timeout: timeout) { if case .previewing = $0 { return true }; return false }
    }

    func waitForInferring(timeout: TimeInterval = 3) async -> SessionPhase {
        await waitForPhase(timeout: timeout) { if case .inferring = $0 { return true }; return false }
    }

    func waitForFailed(
        timeout: TimeInterval = 3,
        matching: ((SessionFailure) -> Bool)? = nil
    ) async -> SessionPhase {
        await waitForPhase(timeout: timeout) { phase in
            guard case .failed(let failure) = phase else { return false }
            return matching?(failure) ?? true
        }
    }

    func waitUntil(
        timeout: TimeInterval = 3,
        pollNanoseconds: UInt64 = 25_000_000,
        _ predicate: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: pollNanoseconds)
        }
        return predicate()
    }

    func waitForSuggestions(_ expected: [String], timeout: TimeInterval = 3) async -> Bool {
        await waitUntil(timeout: timeout) {
            !isFetchingSuggestions && suggestedFollowUps == expected
        }
    }

    func waitForPrewarmComplete(timeout: TimeInterval = 3) async {
        _ = await waitUntil(timeout: timeout) { !isPrewarming }
    }

    func waitForArchivePersistenceIssue(
        _ expected: ConversationArchiveError,
        timeout: TimeInterval = 3
    ) async -> Bool {
        await waitUntil(timeout: timeout) { archivePersistenceIssue == expected }
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

extension ConversationArchiveStore {
    func waitForSummaries(count: Int, timeout: TimeInterval = 3) async -> [ConversationSummary] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let list = await summaries()
            if list.count == count { return list }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return await summaries()
    }
}
