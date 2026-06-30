// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The production ``StreamingTranscribing`` the caption surface taps: it OWNS both an audio transcriber
/// and a screen-text source and fuses them into ONE segment stream, so the coordinator and the protocol
/// stay exactly as they were — the resourcefulness ("read the subtitles when they are on screen, listen
/// when they are not") lives entirely behind this seam. A future engine (macOS 26 SpeechAnalyzer, an
/// alternative recognizer, a MusicKit lyric source) is still just one of the children swapped in here,
/// never a branch in the coordinator.
///
/// The arbitration is the pure, tested ``CaptionSourcePolicy``; this type owns only the glue — wiring
/// each child's callback, the clock that measures how long since the screen last spoke, and a single
/// monotonic `sequence` re-stamped across both sources so the consumer's rollover dedupe still holds.
/// Audio's `onLevel` passes straight through, so the meter keeps showing real loudness even while the
/// screen is the authoritative TEXT source.
///
/// Fail-closed, additive screen: audio is the contract — if it cannot start on-device the whole caption
/// fails closed exactly as before. The screen source is started best-effort; a missing window, untrusted
/// accessibility, or unavailable OCR just means audio-only, never a failed arm.
///
/// Concurrency: child callbacks arrive off the main actor on the children's own queues; all fusion state
/// is guarded by `lock`, and the consumer closure is always invoked OUTSIDE the lock. A synchronous
/// `stopped` flag (under the same lock) drops any late callback so nothing is forwarded after ``stop()``.
final class FusingStreamingTranscriber: StreamingTranscribing, @unchecked Sendable {
    private let audio: any StreamingTranscribing
    private let screen: any StreamingTranscribing
    private let now: @Sendable () -> Date

    private let lock = NSLock()
    private var state = State()

    private struct State {
        var stopped = false
        var currentSource: CaptionSource = .audio
        var lastScreenSegmentAt: Date?
        var sequence = 0
    }

    init(
        audio: any StreamingTranscribing,
        screen: any StreamingTranscribing,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.audio = audio
        self.screen = screen
        self.now = now
    }

    func start(
        plan: CaptionTranscriptionPlan,
        onSegment: @escaping @Sendable (TranscriptSegment) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void
    ) async throws {
        withState { s in
            s.stopped = false
            s.currentSource = .audio
            s.lastScreenSegmentAt = nil
            s.sequence = 0
        }

        // Audio is the contract: start it first and let it throw (fail-closed) if on-device recognition
        // is unavailable, exactly as the lone transcriber did before. The plan passes straight through to
        // each child — fusion arbitrates which SOURCE is authoritative, never how a child transcribes.
        try await audio.start(plan: plan) { [weak self] segment in
            self?.route(segment, from: .audio, forward: onSegment)
        } onLevel: { [weak self] level in
            self?.forwardLevel(level, to: onLevel)
        }

        // Screen is additive: best-effort, its failure never fails the caption.
        do {
            try await screen.start(plan: plan) { [weak self] segment in
                self?.route(segment, from: .screen, forward: onSegment)
            } onLevel: { _ in }
        } catch {
            // Audio-only for this session; the router simply never sees a screen segment.
        }

        // If stop() raced in during the awaits, make sure neither child keeps running.
        if withState({ $0.stopped }) {
            audio.stop()
            screen.stop()
        }
    }

    func stop() {
        withState { $0.stopped = true }
        audio.stop()
        screen.stop()
    }

    // MARK: - Fusion

    /// Route one child segment: update the clock, ask the pure router which source is authoritative, drop
    /// the segment if it is not from that source, else re-stamp the unified sequence and forward. The
    /// router decision and sequence bump happen under the lock; the consumer callback runs after release.
    private func route(
        _ segment: TranscriptSegment,
        from source: CaptionSource,
        forward: @escaping @Sendable (TranscriptSegment) -> Void
    ) {
        let toForward: TranscriptSegment? = withState { s in
            guard !s.stopped else { return nil }
            let timestamp = now()
            if source == .screen { s.lastScreenSegmentAt = timestamp }
            let sinceScreen = s.lastScreenSegmentAt.map { timestamp.timeIntervalSince($0) } ?? .infinity
            s.currentSource = CaptionSourcePolicy.authoritativeSource(
                current: s.currentSource,
                secondsSinceScreenSegment: sinceScreen
            )
            guard source == s.currentSource else { return nil }
            if segment.isStable { s.sequence += 1 }
            return TranscriptSegment(text: segment.text, isStable: segment.isStable, sequence: s.sequence)
        }
        if let toForward { forward(toForward) }
    }

    private func forwardLevel(_ level: Float, to onLevel: @escaping @Sendable (Float) -> Void) {
        guard !withState({ $0.stopped }) else { return }
        onLevel(level)
    }

    private func withState<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
}
