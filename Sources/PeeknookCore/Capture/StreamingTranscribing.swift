// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A slice of a continuous on-device transcription. `isStable` lets the consumer tell a still-changing
/// interim hypothesis (a "hearing…" cue) from a finalized segment ready to translate; `sequence`
/// increases monotonically so the consumer can dedupe the short overlap a recognizer rollover produces
/// at the seam.
public struct TranscriptSegment: Sendable, Equatable {
    public let text: String
    public let isStable: Bool
    public let sequence: Int

    public init(text: String, isStable: Bool, sequence: Int) {
        self.text = text
        self.isStable = isStable
        self.sequence = sequence
    }
}

/// A continuous, on-device system-audio transcription seam — the streaming sibling of the batch
/// ``SystemAudioTranscribing`` and distinct from one-shot ``CaptureProviding``: it emits rolling
/// segments over the life of an armed caption session rather than returning one finalized string.
/// `Sendable` / off-main (its SCStream audio buffers land off the main actor); the consumer hops to the
/// main actor.
///
/// Implementations MUST keep `requiresOnDeviceRecognition = true` (no network fallback, ever) and fail
/// closed — throw ``SpeechRecognitionError/onDeviceUnavailable`` — when on-device recognition or the
/// requested locale's model is unavailable, BEFORE any audio is tapped.
///
/// Two callbacks, by design: `onSegment` is low-frequency, discrete, and content-bearing; `onLevel` is
/// high-frequency, continuous, and content-FREE (a normalized 0...1 loudness reading for the surface's
/// audio meter). Folding the level into `TranscriptSegment` would force a meter update to fabricate a
/// segment or make every segment consumer branch in its hot path, so they stay separate seams that
/// happen to share one tap. A conformer that cannot meter simply never calls `onLevel` (the meter rests
/// at 0) — the level signal is additive and never widens the segment path.
public protocol StreamingTranscribing: Sendable {
    /// Begin transcribing system audio per `plan`, delivering rolling segments via `onSegment` and a
    /// normalized 0...1 audio level via `onLevel` (loudness only, no content) until ``stop()``. Throws
    /// before tapping audio when on-device recognition is unavailable. `onLevel` is optional for a
    /// conformer to drive; segments are the contract.
    ///
    /// `plan` carries the source-language hint and whether to translate to English in-engine (one pass).
    /// A conformer that cannot translate (e.g. `SFSpeechRecognizer`) honors `plan.sourceLocale` and
    /// transcribes regardless of mode; the production English-direct route uses the Whisper conformer.
    func start(
        plan: CaptionTranscriptionPlan,
        onSegment: @escaping @Sendable (TranscriptSegment) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void
    ) async throws
    /// Stop transcribing. SYNCHRONOUS and idempotent: it must synchronously stop delivering segments (set
    /// a drop-all flag the audio handler checks at the top) so no segment lands after this returns, then
    /// may finish the underlying capture asynchronously.
    func stop()
}

/// Pure policy for the SFSpeechRecognizer ~1-minute on-device session ceiling: rotate to a pre-warmed
/// second recognizer before the limit, or at a natural finalization. Clock-free and deterministic, so
/// the rotation decision is unit-testable apart from the (device-only) audio tap.
public enum RecognizerRolloverPolicy: Sendable {
    /// Rotate this many seconds into a recognizer session — comfortably under the ~60s ceiling, leaving
    /// headroom to finalize and hand off with a short overlap.
    public static let safeWindow: TimeInterval = 50

    /// Roll when the session ran past `safeWindow`, or the recognizer already produced a natural final
    /// result (the cleanest seam).
    public static func shouldRoll(elapsed: TimeInterval, sawFinal: Bool) -> Bool {
        elapsed >= safeWindow || sawFinal
    }
}

/// The transcriber used when the platform can't provide on-device streaming (non-Apple toolchain, or a
/// build without the frameworks). Fails closed so arming a caption session surfaces the typed
/// "on-device unavailable" recovery rather than silently tapping nothing.
public struct UnavailableStreamingTranscriber: StreamingTranscribing {
    public init() {}
    public func start(
        plan: CaptionTranscriptionPlan,
        onSegment: @escaping @Sendable (TranscriptSegment) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void
    ) async throws {
        throw SpeechRecognitionError.onDeviceUnavailable
    }
    public func stop() {}
}

#if DEBUG
/// A scriptable test double. `start` replays `scripted` segments through `onSegment` (or throws
/// `startError` to simulate a missing on-device model) and retains the callback so a test can drive
/// later segments via ``emit(_:)``. Records start/stop counts + the requested locale for assertions.
public final class StubStreamingTranscriber: StreamingTranscribing, @unchecked Sendable {
    public var scripted: [TranscriptSegment]
    public var startError: Error?
    public private(set) var startCount = 0
    public private(set) var stopCount = 0
    public private(set) var lastPlan: CaptionTranscriptionPlan?
    /// Convenience for assertions that only care about the source locale.
    public var lastLocale: Locale? { lastPlan?.sourceLocale }
    private var handler: (@Sendable (TranscriptSegment) -> Void)?
    private var levelHandler: (@Sendable (Float) -> Void)?

    public init(scripted: [TranscriptSegment] = [], startError: Error? = nil) {
        self.scripted = scripted
        self.startError = startError
    }

    public func start(
        plan: CaptionTranscriptionPlan,
        onSegment: @escaping @Sendable (TranscriptSegment) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void
    ) async throws {
        startCount += 1
        lastPlan = plan
        if let startError { throw startError }
        handler = onSegment
        levelHandler = onLevel
        for segment in scripted { onSegment(segment) }
    }

    /// Deliver one more segment as if the recognizer produced it (no-op before `start` / after `stop`).
    public func emit(_ segment: TranscriptSegment) { handler?(segment) }

    /// Deliver one audio-level reading as if the tap measured it (no-op before `start` / after `stop`).
    public func emitLevel(_ level: Float) { levelHandler?(level) }

    public func stop() {
        stopCount += 1
        handler = nil
        levelHandler = nil
    }
}
#endif
