// SPDX-License-Identifier: Apache-2.0

import Foundation
import PeeknookCore

#if canImport(WhisperKit) && canImport(ScreenCaptureKit) && canImport(AVFoundation)
import AVFoundation
import ScreenCaptureKit
import WhisperKit
import os

/// The on-device Whisper ``StreamingTranscribing`` conformer: a continuous system-audio tap whose buffers
/// feed an on-device WhisperKit (Core ML / Apple Neural Engine) model and emit rolling caption segments.
/// The successor to ``RotatingSFSpeechTranscriber`` for the caption surface — Whisper is far stronger on
/// accented, musical, and multi-speaker audio than `SFSpeechRecognizer`, which is the engine, not the
/// pipeline, that capped caption quality.
///
/// THIN ADAPTER, by design. The one DECISION — when an accumulated buffer is a finished utterance worth a
/// transcribe pass — lives in the pure, unit-tested ``WhisperUtterancePolicy`` (Whisper transcribes a
/// finite array, not a stream, so we "chunk on a pause"). This type owns only the device glue: the shared
/// ``SystemAudioTap`` (configured for 16 kHz mono so buffers arrive in exactly Whisper's expected format,
/// no resampling), the meter window feeding the pure ``AudioLevelMeter``, the model lifecycle, and the
/// clock that drives the policy. One transcribe per utterance deliberately avoids the cumulative
/// rolling-hypothesis overlap that made the SFSpeech path drift worse over time.
///
/// Lives in the isolated `PeeknookWhisper` target so the heavy WhisperKit + Core ML dependency never
/// links into `PeeknookCore` or its fast test suite. Wired as the production caption engine at the single
/// swap point `PeeknookDependencies.production(streamingTranscriberOverride:)` by the host. Device-only —
/// not exercised by `swift test`; the policy it composes is.
///
/// Concurrency mirrors the SFSpeech sibling: all session state is confined to ``queue`` (the SCStream
/// sample-handler queue), so audio buffers, the segmentation/meter ticks, and finalize/complete are
/// serialized there. The off-queue Whisper `transcribe` runs on a detached task and re-enters the queue
/// to deliver; a per-arm ``generation`` drops a completion that lands after a re-arm. ``stopped`` is the
/// synchronous drop-all gate set by ``stop()`` before the async capture teardown. The model is loaded once
/// and kept across arm/stop cycles (the host holds one instance) so re-arm is warm.
public final class WhisperKitStreamingTranscriber: StreamingTranscribing, @unchecked Sendable {
    /// Segmentation poll cadence — a device-glue clock, NOT a decision (thresholds live in
    /// ``WhisperUtterancePolicy``). Timer-driven so a trailing silence still finalizes the pending tail
    /// even when SCStream slows buffer delivery during a quiet stretch.
    private static let segInterval: TimeInterval = 0.25
    /// Meter refresh cadence, decoupled from segmentation (see the SFSpeech sibling's rationale).
    private static let levelInterval: TimeInterval = 1.0 / 15.0
    /// Whisper's required input rate. We ask SCStream for this directly, so no resampling step exists.
    private static let sampleRate = 16_000
    /// Pre-roll kept while no speech has been detected, so the onset of a line isn't clipped while
    /// trailing silence stays bounded (a silent tap can't grow the buffer without limit).
    private static let preRollSamples = 16_000   // 1 s

    /// Whisper's required input format. Every delivered buffer is converted to this off its ACTUAL
    /// format (see ``mono16kSamples(from:)``) because SCStream does not reliably honor the requested
    /// `sampleRate` / `channelCount` on the audio config; trusting them feeds Whisper up-rate,
    /// multi-channel audio that decodes to 3x-speed garbage.
    private static let whisperFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false
    )!

    /// Device-glue diagnostics (the actual delivered audio format, etc.). Not a decision surface.
    private static let log = Logger(subsystem: "com.peeknook", category: "caption.whisper")

    /// Crosses the WhisperKit instance (non-`Sendable`) into the detached transcribe task and back.
    private final class KitBox: @unchecked Sendable {
        let kit: WhisperKit
        init(_ kit: WhisperKit) { self.kit = kit }
    }

    /// Hands the converter its single input buffer exactly once across the resampler's repeated polls.
    /// A reference box (vs. a captured `var`) keeps the synchronous `AVAudioConverterInputBlock` clean
    /// under strict concurrency.
    private final class PendingInput: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        func take() -> AVAudioPCMBuffer? {
            defer { buffer = nil }
            return buffer
        }
    }

    private let modelName: String
    private let queue = DispatchQueue(label: "com.peeknook.caption.whisper")
    private let stopped = OSAllocatedUnfairLock(initialState: false)

    // Model load is shared across arm/stop cycles. Guarded by `loadLock`; the Task result is awaited in
    // `start` so a failed/in-flight download is a clean fail-closed throw rather than a half-armed tap.
    private let loadLock = NSLock()
    private var loadTask: Task<KitBox, Error>?

    // Session state — mutated only on `queue`.
    private var onSegment: (@Sendable (TranscriptSegment) -> Void)?
    private var onLevel: (@Sendable (Float) -> Void)?
    private var stream: SCStream?
    private var output: AudioStreamOutput?
    private var segTicker: DispatchSourceTimer?
    private var levelTicker: DispatchSourceTimer?
    private var kitBox: KitBox?
    private var languageCode: String?
    /// The decode task for this arm: `.translate` (audio -> English, source auto-detected) when the caption
    /// target is English, else `.transcribe`. Set from the ``CaptionTranscriptionPlan`` at `start`.
    private var whisperTask: DecodingTask = .transcribe

    /// Resamples + downmixes each delivered buffer to ``whisperFormat``; built lazily from the first
    /// buffer's ACTUAL format and rebuilt if that format ever changes. Queue-confined.
    private var converter: AVAudioConverter?
    /// One-shot gate so the delivered input format is logged once per arm, not once per buffer.
    private var loggedInputFormat = false

    private var buffer: [Float] = []
    private var hadSpeech = false
    private var lastVoiceAt = Date()
    /// Monotonic stable-segment counter; the consumer keys on it. Reset on a fresh `start`.
    private var sequence = 0
    /// True while a transcribe pass is in flight, so the segmentation tick never overlaps Whisper calls.
    private var transcribing = false
    /// Bumped on every `start`; a transcribe completion tagged with a stale generation is dropped.
    private var generation = 0

    // Meter window — touched only on `queue`.
    private var windowSumSquares: Double = 0
    private var windowSampleCount = 0
    private var smoothedLevel: Float = 0
    private var lastEmittedLevel: Float = 0

    /// - Parameter model: the WhisperKit model identifier. Defaults to large-v3-turbo (~626 MB): near
    ///   large-v3 accuracy at several times the throughput, comfortably real-time on Apple Silicon.
    public init(model: String = "large-v3-v20240930_626MB") {
        self.modelName = model
        // Begin the (download +) load in the background at construction so the first arm is likely warm.
        _ = ensureModelTask()
    }

    /// The shared, idempotent model load. Created once; subsequent calls await the same task.
    @discardableResult
    private func ensureModelTask() -> Task<KitBox, Error> {
        loadLock.lock()
        defer { loadLock.unlock() }
        if let loadTask { return loadTask }
        let model = modelName
        let task = Task<KitBox, Error> {
            let config = WhisperKitConfig(model: model, verbose: false, load: true, download: true)
            return KitBox(try await WhisperKit(config))
        }
        loadTask = task
        return task
    }

    public func start(
        plan: CaptionTranscriptionPlan,
        onSegment: @escaping @Sendable (TranscriptSegment) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void
    ) async throws {
        // Un-latch the reused instance BEFORE any await (mirrors the SFSpeech sibling).
        stopped.withLock { $0 = false }

        // FAIL CLOSED before tapping audio: the model must be loaded. On the first ever run this downloads
        // it once; offline with no cached model throws and the coordinator surfaces recovery.
        let box = try await ensureModelTask().value
        // `.translateToEnglish` -> Whisper translate task with NO language hint, so the model auto-detects
        // the spoken language and emits English in one pass; `.transcribe` -> verbatim in the source locale.
        let task: DecodingTask
        let code: String?
        switch plan.mode {
        case .transcribe:
            task = .transcribe
            code = Self.whisperLanguageCode(for: plan.sourceLocale)
        case .translateToEnglish:
            task = .translate
            code = nil
        }

        let stream = try await SystemAudioTap.makeStream(sampleRate: Self.sampleRate, channelCount: 1)
        let output = AudioStreamOutput { [weak self] sampleBuffer in
            self?.handleAudio(sampleBuffer)
        }
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: queue)

        queue.sync {
            self.kitBox = box
            self.languageCode = code
            self.whisperTask = task
            self.onSegment = onSegment
            self.onLevel = onLevel
            self.stream = stream
            self.output = output
            self.buffer.removeAll(keepingCapacity: true)
            self.hadSpeech = false
            self.lastVoiceAt = Date()
            self.transcribing = false
            self.converter = nil
            self.loggedInputFormat = false
            self.sequence = 0
            self.windowSumSquares = 0
            self.windowSampleCount = 0
            self.smoothedLevel = 0
            self.lastEmittedLevel = 0
            self.generation += 1
            self.startTickers()
        }

        do {
            try await stream.startCapture()
        } catch {
            tearDownOnQueue()
            throw error
        }

        if stopped.withLock({ $0 }) {
            try? await stream.stopCapture()
            tearDownOnQueue()
        }
    }

    public func stop() {
        stopped.withLock { $0 = true }
        queue.async { [weak self] in
            guard let self else { return }
            let stream = self.stream
            self.clearSessionRefs()
            if let stream {
                Task.detached { try? await stream.stopCapture() }
            }
        }
    }

    // MARK: - Teardown

    private func clearSessionRefs() {
        segTicker?.cancel(); segTicker = nil
        levelTicker?.cancel(); levelTicker = nil
        stream = nil
        output = nil
        converter = nil
        loggedInputFormat = false
        buffer.removeAll(keepingCapacity: false)
        // Keep `kitBox` / `loadTask`: the loaded model stays warm for the next arm.
    }

    private func tearDownOnQueue() {
        queue.sync { self.clearSessionRefs() }
    }

    // MARK: - Queue-confined machinery

    private func startTickers() {
        let seg = DispatchSource.makeTimerSource(queue: queue)
        seg.schedule(deadline: .now() + Self.segInterval, repeating: Self.segInterval)
        seg.setEventHandler { [weak self] in self?.segTick() }
        segTicker = seg
        seg.resume()

        let level = DispatchSource.makeTimerSource(queue: queue)
        level.schedule(deadline: .now() + Self.levelInterval, repeating: Self.levelInterval)
        level.setEventHandler { [weak self] in self?.meterTick() }
        levelTicker = level
        level.resume()
    }

    /// SCStream audio callback — already on `queue`. Appends samples, feeds the meter window, and marks
    /// voice activity (for the silence clock). Bounds the buffer to a short pre-roll while no speech has
    /// been seen, so steady silence never grows it.
    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        if stopped.withLock({ $0 }) { return }
        let samples = mono16kSamples(from: sampleBuffer)
        guard !samples.isEmpty else { return }
        buffer.append(contentsOf: samples)

        let sumSquares = AudioLevelMeter.sumOfSquares(samples)
        windowSumSquares += Double(sumSquares)
        windowSampleCount += samples.count

        let meanSquare = Float(Double(sumSquares) / Double(samples.count))
        if WhisperUtterancePolicy.isVoice(level: AudioLevelMeter.normalized(meanSquare: meanSquare)) {
            lastVoiceAt = Date()
            hadSpeech = true
        } else if !hadSpeech, buffer.count > Self.preRollSamples {
            buffer.removeFirst(buffer.count - Self.preRollSamples)
        }
    }

    /// Convert one delivered SCStream audio buffer to the 16 kHz mono Float array Whisper requires, off
    /// its ACTUAL format rather than the requested config. SCStream does not reliably honor
    /// `SCStreamConfiguration.sampleRate` / `channelCount`, so reinterpreting the bytes as 16 kHz mono
    /// would feed Whisper up-rate, multi-channel audio (3x-speed garbage, finalized too early because
    /// `bufferSeconds` would run ahead of real time). We read the real ASBD, build an `AVAudioConverter`
    /// for it once per arm, and resample + downmix every buffer; a stream that already delivers 16 kHz
    /// mono float is a passthrough. Queue-confined (runs via ``handleAudio``). Returns `[]` on any
    /// format/convert failure so the caller reads silence instead of a garbage signal.
    private func mono16kSamples(from sampleBuffer: CMSampleBuffer) -> [Float] {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return []
        }
        let inputFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        if !loggedInputFormat {
            loggedInputFormat = true
            Self.log.notice(
                "caption audio in: \(inputFormat.sampleRate, privacy: .public) Hz, \(inputFormat.channelCount, privacy: .public) ch (requested \(Self.sampleRate, privacy: .public) Hz mono)"
            )
        }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
            return []
        }
        inputBuffer.frameLength = frameCount
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frameCount), into: inputBuffer.mutableAudioBufferList
        ) == noErr else {
            return []
        }

        // Passthrough when the stream already delivers exactly 16 kHz mono float.
        if inputFormat == Self.whisperFormat {
            guard let channel = inputBuffer.floatChannelData else { return [] }
            return Array(UnsafeBufferPointer(start: channel[0], count: Int(frameCount)))
        }

        if converter == nil || converter?.inputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: Self.whisperFormat)
        }
        guard let converter else { return [] }

        let ratio = Self.whisperFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(frameCount) * ratio) + 1_024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: Self.whisperFormat, frameCapacity: capacity) else {
            return []
        }
        // Feed the one input buffer exactly once; the resampler may poll the block again for more, which
        // we answer `.noDataNow`. The box (not a captured `var`) keeps the synchronous callback clean.
        let pending = PendingInput(inputBuffer)
        var conversionError: NSError?
        converter.convert(to: outputBuffer, error: &conversionError) { _, statusOut in
            guard let next = pending.take() else {
                statusOut.pointee = .noDataNow
                return nil
            }
            statusOut.pointee = .haveData
            return next
        }
        guard conversionError == nil, let channel = outputBuffer.floatChannelData else { return [] }
        let produced = Int(outputBuffer.frameLength)
        guard produced > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: produced))
    }

    /// The segmentation clock: consult the pure policy; on `.finalize`, hand the buffer to a transcribe
    /// pass. Skipped while a pass is already in flight so Whisper calls never overlap.
    private func segTick() {
        if stopped.withLock({ $0 }) { return }
        if transcribing { return }
        let now = Date()
        let bufferSeconds = Double(buffer.count) / Double(Self.sampleRate)
        let decision = WhisperUtterancePolicy.decide(
            hadSpeech: hadSpeech,
            bufferSeconds: bufferSeconds,
            secondsSinceVoice: now.timeIntervalSince(lastVoiceAt)
        )
        if decision == .finalize { finalize() }
    }

    /// Snapshot and clear the buffer, then transcribe it off-queue. Re-enters the queue to deliver so all
    /// state mutation stays single-threaded; the generation tag drops a completion that lands post-re-arm.
    private func finalize() {
        guard let box = kitBox else { return }
        let snapshot = buffer
        buffer.removeAll(keepingCapacity: true)
        hadSpeech = false
        transcribing = true
        let generation = self.generation
        let code = languageCode
        let task = whisperTask
        Task.detached { [weak self] in
            var options = DecodingOptions(task: task, language: code)
            options.skipSpecialTokens = true
            options.withoutTimestamps = true
            let text: String
            do {
                let results = try await box.kit.transcribe(audioArray: snapshot, decodeOptions: options)
                text = results.map(\.text).joined(separator: " ")
            } catch {
                text = ""
            }
            self?.queue.async { self?.complete(rawText: text, generation: generation) }
        }
    }

    /// Deliver a finished transcription as the next stable segment (off-queue via the consumer's closure,
    /// which hops to the main actor and re-guards). Drops blank / non-speech-annotation output.
    private func complete(rawText: String, generation: Int) {
        transcribing = false
        if stopped.withLock({ $0 }) { return }
        guard generation == self.generation else { return }
        guard let cleaned = WhisperUtterancePolicy.cleaned(rawText) else { return }
        sequence += 1
        if stopped.withLock({ $0 }) { return }
        onSegment?(TranscriptSegment(text: cleaned, isStable: true, sequence: sequence))
    }

    /// Fold the meter window into a smoothed 0...1 level and emit it only on a perceptible change (steady
    /// silence decays to and rests at 0 for free). Identical ballistics to the SFSpeech sibling.
    private func meterTick() {
        if stopped.withLock({ $0 }) { return }
        let meanSquare = windowSampleCount > 0 ? Float(windowSumSquares / Double(windowSampleCount)) : 0
        windowSumSquares = 0
        windowSampleCount = 0
        let target = AudioLevelMeter.normalized(meanSquare: meanSquare)
        smoothedLevel = AudioLevelMeter.smoothed(previous: smoothedLevel, target: target)
        guard AudioLevelMeter.isPerceptibleChange(from: lastEmittedLevel, to: smoothedLevel) else { return }
        lastEmittedLevel = smoothedLevel
        if stopped.withLock({ $0 }) { return }
        onLevel?(smoothedLevel)
    }

    /// Map a `Locale` to the ISO language code Whisper expects (`ko`, `ja`, `es`, ...). `nil` lets Whisper
    /// auto-detect rather than forcing a wrong language.
    private static func whisperLanguageCode(for locale: Locale) -> String? {
        locale.language.languageCode?.identifier
    }
}
#endif
