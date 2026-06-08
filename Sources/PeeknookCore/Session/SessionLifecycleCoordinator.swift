// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Tracks generation epochs and pending capture state so async completions can detect stale work.
@MainActor
final class SessionLifecycleCoordinator {
    private(set) var captureGeneration = 0
    private(set) var sessionGeneration = 0

    var inferenceTask: Task<Void, Never>?
    var suggestionTask: Task<Void, Never>?

    var pendingPreview: CapturePreview?
    var pendingCapture: CaptureResult?
    var pendingIntent: SessionOrchestrator.CaptureIntent = .fresh

    func snapshotCapture() -> Int { captureGeneration }
    func snapshotSession() -> Int { sessionGeneration }

    func isCurrentCapture(_ generation: Int) -> Bool {
        generation == captureGeneration
    }

    func isCurrentSession(_ generation: Int) -> Bool {
        generation == sessionGeneration
    }

    /// Invalidate in-flight work and bump both generation counters.
    func invalidateAllWork() {
        sessionGeneration += 1
        captureGeneration += 1
        inferenceTask?.cancel()
        inferenceTask = nil
        suggestionTask?.cancel()
        suggestionTask = nil
    }

    func cancelInferenceAndSuggestions() {
        inferenceTask?.cancel()
        inferenceTask = nil
        suggestionTask?.cancel()
        suggestionTask = nil
    }

    func clearPendingCapture() {
        pendingPreview = nil
        pendingCapture = nil
    }
}
