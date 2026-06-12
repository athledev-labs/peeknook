// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Tracks generation epochs and pending capture state so async completions can detect stale work.
@MainActor
final class SessionLifecycleCoordinator {
    private(set) var captureGeneration = 0
    private(set) var sessionGeneration = 0

    var inferenceTask: Task<Void, Never>?
    var suggestionTask: Task<Void, Never>?
    /// Camera live-preview work (startPreview / the in-flight shutter still).
    var cameraTask: Task<Void, Never>?

    var pendingPreview: CapturePreview?
    var pendingCapture: CaptureResult?
    var pendingIntent: SessionOrchestrator.CaptureIntent = .fresh

    /// Composite (screen + camera) in flight: the screen leg is captured first and held here while
    /// the live camera preview is up; the shutter then commits BOTH legs atomically. Non-nil only
    /// between a composite's screen grab and its shutter. Cleared in `stopCameraPreview` (the single
    /// camera-teardown choke point), so an abort/cancel/collapse leaves NO partial turn behind.
    var pendingCompositeGroupID: UUID?
    var pendingCompositeScreen: CaptureResult?
    var pendingCompositeIntent: SessionOrchestrator.CaptureIntent = .fresh

    /// A frame grabbed by a live-session refresh, held pending until "Update & ask" / auto-respond
    /// promotes it (or it's cleared on disarm / Done). A SEPARATE slot from the composite legs, never
    /// aliased. `pendingLiveCaptureAt` drives the armed chip's "Last refresh …" timestamp.
    var pendingLiveCapture: CaptureResult?
    var pendingLiveCaptureAt: Date?

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
        cameraTask?.cancel()
        cameraTask = nil
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

    func clearPendingComposite() {
        pendingCompositeGroupID = nil
        pendingCompositeScreen = nil
        pendingCompositeIntent = .fresh
    }

    func clearPendingLive() {
        pendingLiveCapture = nil
        pendingLiveCaptureAt = nil
    }
}
