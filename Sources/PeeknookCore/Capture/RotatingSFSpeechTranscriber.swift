// SPDX-License-Identifier: Apache-2.0

import Foundation

#if canImport(ScreenCaptureKit) && canImport(Speech) && canImport(AVFoundation)
import AVFoundation
import os
import ScreenCaptureKit
import Speech

/// The production ``StreamingTranscribing`` conformer: a continuous, on-device system-audio tap that
/// feeds an `SFSpeechRecognizer` and emits rolling ``TranscriptSegment``s for the ephemeral caption
/// surface. The streaming sibling of the bounded ``ScreenCaptureKitSystemAudioTranscriber`` — it shares
/// that one's SCStream glue (``SystemAudioTap``) and fail-closed preflight, but runs for the life of an
/// armed caption session rather than a fixed window.
///
/// THIN ADAPTER, by design: every DECISION lives in a pure, clock-free, unit-tested leaf policy —
/// ``CaptionSegmentPolicy`` decides WHEN an interim has settled into a stable segment,
/// ``RecognizerRolloverPolicy`` decides WHEN to rotate the recognizer around its ~60s on-device session
/// ceiling, and ``CaptionSegmentSlicer`` extracts the not-yet-finalized delta from the recognizer's
/// growing cumulative transcript. This type only owns the device glue and the clock that feeds those
/// policies their `TimeInterval` inputs; the rotation/ring mechanism is an internal detail and never
/// leaks into the protocol. A future engine (macOS 26 SpeechAnalyzer, or an alternative recognizer) is a
/// NEW conformer wired at the single swap point ``PeeknookDependencies/makeProductionStreamingTranscriber()``,
/// not a branch here or in the coordinator.
///
/// Device-only — not exercised by `swift test`. The policies it composes ARE covered; this shell is
/// verified by compiling under the framework gates and by the on-device checklist.
///
/// Concurrency: all session state is confined to ``queue`` (the SCStream `sampleHandlerQueue`, so audio
/// buffers, recognizer callbacks, the segmentation/rollover tick, and rotation are all serialized there —
/// no append can race a rotation, and the shared refs are only ever mutated under it). `stopped` is the
/// one exception: a standalone atomic ``stop()`` sets SYNCHRONOUSLY so the handlers drop at the top
/// before the (async) capture teardown runs. The authoritative late-segment drop is the consumer's
/// main-actor generation re-guard; this flag is the load-bearing best-effort gate.
///
/// The instance is reused across arm/stop cycles (the orchestrator holds one), so ``start(locale:onSegment:)``
/// un-latches `stopped` and resets session state.
final class RotatingSFSpeechTranscriber: StreamingTranscribing, @unchecked Sendable {
    /// How often the segmentation/rollover policies are consulted. A device-glue poll cadence, NOT a
    /// decision (the thresholds live in the policies) — driven by a timer rather than audio-buffer arrival
    /// so a quiet stretch (where SCStream may slow buffer delivery) still finalizes the pending tail and
    /// honors the rollover ceiling.
    private static let tickInterval: TimeInterval = 0.25

    /// Serial owner of ALL session state below, and the SCStream sample-handler queue.
    private let queue = DispatchQueue(label: "com.peeknook.caption.transcriber")
    /// The sync drop-all gate. Set true by ``stop()`` synchronously; checked at the top of every handler.
    /// Un-latched by ``start()`` so a reused instance arms again.
    private let stopped = OSAllocatedUnfairLock(initialState: false)

    // Mutated only on `queue` (published there by the setup `queue.sync` in `start`).
    private var onSegment: (@Sendable (TranscriptSegment) -> Void)?
    private var recognizer: SFSpeechRecognizer?
    private var stream: SCStream?
    private var output: AudioStreamOutput?
    private var ticker: DispatchSourceTimer?

    // Session state — touched only on `queue`.
    private var activeRequest: SFSpeechAudioBufferRecognitionRequest?
    private var activeTask: SFSpeechRecognitionTask?
    /// Bumped on every new recognizer session; a re-dispatched callback from a rotated-away task drops.
    private var sessionGeneration = 0
    /// Latest cumulative `formattedString` for the active session.
    private var currentCumulative = ""
    /// The portion of `currentCumulative` already emitted as a stable segment (the slicer's input).
    private var committedPrefix = ""
    /// Monotonic within an armed session and across its rotations — the consumer dedupes the rollover
    /// overlap by `segment.sequence`, so this must NOT reset when a session rolls. Reset only on a fresh
    /// `start`, where the consumer also resets its `lastSequence`.
    private var sequence = 0
    private var sawFinal = false
    private var sessionStartedAt = Date()
    private var segmentStartedAt = Date()
    private var lastTokenAt = Date()

    func start(locale: Locale, onSegment: @escaping @Sendable (TranscriptSegment) -> Void) async throws {
        // Un-latch the reused instance for this arm, BEFORE any await: a stop() that races in during the
        // setup awaits below then re-latches it, and the post-startCapture check tears the capture down.
        stopped.withLock { $0 = false }

        // FAIL CLOSED, before tapping any audio (mirrors the batch sibling's ordering). Constructing the
        // recognizer WITH `locale` makes `supportsOnDeviceRecognition` locale-specific and authoritative
        // for "is this locale's on-device model present", so no separate `supportedLocales()` check is
        // needed (and adding one risks admitting a server-only locale).
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw SpeechRecognitionError.unavailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw SpeechRecognitionError.onDeviceUnavailable
        }
        let authorized = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard authorized else { throw SpeechRecognitionError.notAuthorized }

        let stream = try await SystemAudioTap.makeStream()
        // Capture self weakly so the stream -> output -> closure chain can't retain this adapter past
        // teardown.
        let output = AudioStreamOutput { [weak self] sampleBuffer in
            self?.handleAudio(sampleBuffer)
        }
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: queue)

        // Publish refs, un-latch, reset, and prime the first session ON the queue (serialized with any
        // still-pending teardown from a prior stop(), so a quick re-arm can't race shared-ref writes).
        // No audio is flowing yet (capture starts below), so this returns immediately.
        queue.sync {
            self.recognizer = recognizer
            self.onSegment = onSegment
            self.stream = stream
            self.output = output
            self.sequence = 0
            self.startSession(at: Date())
            self.startTicker()
        }

        do {
            try await stream.startCapture()
        } catch {
            // Capture refused (e.g. Screen Recording not granted) — unwind so a failed arm leaves nothing
            // running, then let the coordinator map the error to a recovery card.
            tearDownOnQueue()
            throw error
        }

        // If stop() raced in during the setup awaits / startCapture, tear the freshly-started capture down
        // now so nothing keeps running after a stop that already returned.
        if stopped.withLock({ $0 }) {
            try? await stream.stopCapture()
            tearDownOnQueue()
        }
    }

    func stop() {
        // SYNCHRONOUS drop-all gate first: no handler emits a segment after this returns.
        stopped.withLock { $0 = true }
        // Then tear the capture down asynchronously (SCStream.stopCapture is async). Idempotent — a second
        // stop finds the refs already cleared.
        queue.async { [weak self] in
            guard let self else { return }
            let stream = self.stream
            self.clearSessionRefs()
            if let stream {
                // Capture only the local `stream`, never `self`, so this outlives teardown without a cycle.
                Task.detached { try? await stream.stopCapture() }
            }
        }
    }

    // MARK: - Teardown helpers

    /// Synchronously clear the recognizer/stream refs and the ticker on the queue (used by stop's async
    /// block and the aborted-start paths). Does NOT await `stopCapture`.
    private func clearSessionRefs() {
        ticker?.cancel(); ticker = nil
        activeTask?.cancel()
        activeRequest?.endAudio()
        activeTask = nil
        activeRequest = nil
        stream = nil
        output = nil
    }

    private func tearDownOnQueue() {
        queue.sync { self.clearSessionRefs() }
    }

    // MARK: - Queue-confined session machinery

    private func startTicker() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.tickInterval, repeating: Self.tickInterval)
        timer.setEventHandler { [weak self] in self?.tick() }
        ticker = timer
        timer.resume()
    }

    /// Begin a fresh recognizer session. A NEW request is created every rotation, and every request
    /// re-asserts `requiresOnDeviceRecognition = true` — a fresh request defaults to `false`, which would
    /// be a silent server-recognition path. `sequence` is deliberately NOT reset (it spans rotations).
    private func startSession(at now: Date) {
        guard let recognizer, !stopped.withLock({ $0 }) else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true   // INVARIANT: on-device only, never the network
        activeRequest = request
        currentCumulative = ""
        committedPrefix = ""
        sawFinal = false
        sessionStartedAt = now
        segmentStartedAt = now
        lastTokenAt = now
        sessionGeneration += 1
        let generation = sessionGeneration
        activeTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Recognizer callbacks land on an arbitrary queue. Read the Sendable primitives off the
            // (non-Sendable) result here, then re-dispatch onto our serial queue so all session-state
            // mutation stays single-threaded, tagged with the session generation so a callback from a
            // rotated-away task is dropped. The outer closure holds `self` weakly (it is retained by
            // `activeTask`); the transient re-dispatch captures it strongly only until it runs.
            guard let self else { return }
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let hadError = error != nil
            self.queue.async {
                self.handleResult(text: text, isFinal: isFinal, hadError: hadError, generation: generation)
            }
        }
    }

    /// SCStream audio callback — already on `queue`. Only appends the buffer (and honors the sync-stop
    /// gate). The segmentation/rollover DECISIONS run on the independent ``tick()`` timer, so they fire on
    /// a steady cadence even if audio buffers slow during a silent stretch.
    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        if stopped.withLock({ $0 }) { return }   // top-of-handler sync gate
        activeRequest?.appendAudioSampleBuffer(sampleBuffer)
    }

    /// The clock: consult the clock-free policies. A finalize emits the pending delta WITHOUT rotating;
    /// only the rollover policy rotates the recognizer. Decoupled so finalization cadence (pauses, max
    /// age) is independent of the ~60s recognizer ceiling.
    private func tick() {
        if stopped.withLock({ $0 }) { return }
        guard activeRequest != nil else { return }
        let now = Date()
        let pending = CaptionSegmentSlicer.pending(cumulative: currentCumulative, committedPrefix: committedPrefix)
        let decision = CaptionSegmentPolicy.decide(
            interim: pending,
            secondsSinceLastToken: now.timeIntervalSince(lastTokenAt),
            secondsSinceSegmentStart: now.timeIntervalSince(segmentStartedAt),
            recognizerMarkedFinal: false
        )
        if decision == .finalize {
            commitStable(pending, at: now)
        }
        if RecognizerRolloverPolicy.shouldRoll(elapsed: now.timeIntervalSince(sessionStartedAt), sawFinal: false) {
            rotate(at: now)
        }
    }

    /// Recognizer result/error — re-dispatched onto `queue`. Updates the cumulative hypothesis and emits
    /// the interim "hearing…" cue; a natural `isFinal` is the cleanest seam, so it flushes the residual
    /// tail and rotates. A mid-stream error recovers by rotating to a fresh session (a persistent failure
    /// then ends the surface via the coordinator's silence watchdog).
    private func handleResult(text: String?, isFinal: Bool, hadError: Bool, generation: Int) {
        if stopped.withLock({ $0 }) { return }
        guard generation == sessionGeneration else { return }   // stale rotated-away callback
        if let text {
            if text != currentCumulative {
                currentCumulative = text
                lastTokenAt = Date()
                emitInterim()
            }
            if isFinal {
                sawFinal = true
                rotate(at: Date())
                return
            }
        }
        if hadError {
            rotate(at: Date())
        }
    }

    /// Rotate the recognizer at a seam: flush whatever stable tail remains, end the outgoing request, and
    /// start a fresh session. Bumping the generation in `startSession` means the outgoing task's last
    /// callbacks drop rather than mutate the new session.
    private func rotate(at now: Date) {
        let pending = CaptionSegmentSlicer.pending(cumulative: currentCumulative, committedPrefix: committedPrefix)
        if pending.count >= CaptionSegmentPolicy.minCharacters {
            commitStable(pending, at: now)
        }
        activeRequest?.endAudio()
        activeTask?.cancel()
        activeRequest = nil
        activeTask = nil
        startSession(at: now)
    }

    /// Emit the current pending tail as the live interim cue (still-changing hypothesis). `sequence` is
    /// the last stable's value — the consumer keys interim handling on `isStable`, not the number.
    private func emitInterim() {
        if stopped.withLock({ $0 }) { return }
        let pending = CaptionSegmentSlicer.pending(cumulative: currentCumulative, committedPrefix: committedPrefix)
        onSegment?(TranscriptSegment(text: pending, isStable: false, sequence: sequence))
    }

    /// Finalize `text` as the next stable segment: advance the committed prefix and the segment clock
    /// first (so state is consistent), bump the monotonic sequence, then deliver off-`queue` via the
    /// consumer's closure (which hops to the main actor and re-guards).
    private func commitStable(_ text: String, at now: Date) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        committedPrefix = currentCumulative
        segmentStartedAt = now
        sequence += 1
        if stopped.withLock({ $0 }) { return }
        onSegment?(TranscriptSegment(text: trimmed, isStable: true, sequence: sequence))
    }
}
#endif
