// SPDX-License-Identifier: Apache-2.0

import Foundation

#if canImport(ScreenCaptureKit) && canImport(Speech) && canImport(AVFoundation)
import AVFoundation
import ScreenCaptureKit
import Speech
#endif

/// The hardware arm of the system-audio ground: record a SHORT window of what is playing through the
/// Mac and return an on-device transcript. Isolated behind this protocol so the provider's POLICY
/// (build a text leg, label it, never claim vision) is unit-testable with a stub while the real
/// ScreenCaptureKit audio tap + `SFSpeechRecognizer` live behind the production conformer. Returns the
/// raw transcript string (or throws); turning it into a `CaptureResult` is the provider's job, kept
/// out of the hardware path so the seam stays trivially fakeable.
public protocol SystemAudioTranscribing: Sendable {
    /// Record up to `maxDuration` seconds of system audio and transcribe it on-device. Stops early
    /// when the recognizer finalizes. Throws on missing permission or unavailable transcription.
    func recordAndTranscribe(maxDuration: TimeInterval) async throws -> String
}

/// System-audio ground provider: a one-shot `CaptureProviding`. "Hear the screen" is a single
/// user-triggered action — record a short window, transcribe on-device, hand back a TEXT leg — so it
/// rides the registry's untouched capture seam exactly like a screenshot leg, no live-preview arm
/// needed (unlike the camera). The hardware lives behind ``SystemAudioTranscribing``; this type only
/// shapes the `CaptureResult` (`ground == .systemAudio`, transcript in `text`, NO image, so the
/// vision gate never trips).
public struct SystemAudioCaptureProvider: CaptureProviding, Sendable {
    /// Default capture window. Short and bounded by design — this ground is NEVER continuous.
    public static let defaultMaxDuration: TimeInterval = 8

    private let transcriber: any SystemAudioTranscribing
    private let maxDuration: TimeInterval

    public init(
        transcriber: any SystemAudioTranscribing = SystemAudioCaptureProvider.makeProductionTranscriber(),
        maxDuration: TimeInterval = SystemAudioCaptureProvider.defaultMaxDuration
    ) {
        self.transcriber = transcriber
        self.maxDuration = maxDuration
    }

    /// Registry arm: scope/quick/encoding are screen-image concepts the audio ground ignores. Records
    /// a short window and returns the transcript as a text-only `CaptureResult`.
    public func capture(
        scope: CaptureScope,
        quick: Bool,
        encoding: CaptureEncodingParams
    ) async throws -> CaptureResult {
        _ = (scope, quick, encoding)   // image concepts; the system-audio ground ignores all three
        let transcript = try await transcriber.recordAndTranscribe(maxDuration: maxDuration)
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CaptureError.noContent
        }
        return CaptureResult(
            text: trimmed,
            sourceLabel: "System audio",
            screenshotBase64: nil,   // a transcript carries no image — keep hasVision false
            ground: .systemAudio
        )
    }

    /// The production transcriber (real ScreenCaptureKit tap on Apple platforms; a clearly-failing
    /// stand-in elsewhere so non-mac builds compile). Wired in `PeeknookDependencies.production()`.
    public static func makeProductionTranscriber() -> any SystemAudioTranscribing {
        #if canImport(ScreenCaptureKit) && canImport(Speech) && canImport(AVFoundation)
        return ScreenCaptureKitSystemAudioTranscriber()
        #else
        return UnavailableSystemAudioTranscriber()
        #endif
    }
}

// MARK: - Production hardware tap (isolated; the only platform-coupled code)

#if canImport(ScreenCaptureKit) && canImport(Speech) && canImport(AVFoundation)

/// Live system-audio tap: a short `SCStream` audio-only capture fed into an on-device
/// `SFSpeechRecognizer`. The ONLY hardware-coupled type in this ground — not unit-testable, exercised
/// only on a real Mac with Screen Recording + Speech Recognition granted. Everything above it (the
/// provider policy, the prompt plumbing, the settings gate) is covered by stub-driven tests.
///
/// NOTE: this live tap is the one piece that cannot be verified in `swift test`; it is structured to
/// stay off every other code path until the user opts in and a capture actually resolves to this
/// ground.
final class ScreenCaptureKitSystemAudioTranscriber: NSObject, SystemAudioTranscribing, @unchecked Sendable {
    func recordAndTranscribe(maxDuration: TimeInterval) async throws -> String {
        // On-device speech first: a missing/unavailable recognizer should fail before we ever start
        // the audio tap, so we never light up capture without a way to transcribe.
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            throw SpeechRecognitionError.unavailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw SpeechRecognitionError.onDeviceUnavailable
        }
        let authorized = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard authorized else { throw SpeechRecognitionError.notAuthorized }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true   // INVARIANT: on-device only, never the network

        let collector = TranscriptCollector()
        let task = recognizer.recognitionTask(with: request) { result, error in
            if let result { collector.update(result.bestTranscription.formattedString) }
            if error != nil || result?.isFinal == true { collector.finish() }
        }

        let stream = try await SystemAudioTap.makeStream()
        let output = AudioStreamOutput { sampleBuffer in
            request.appendAudioSampleBuffer(sampleBuffer)
        }
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: Self.audioQueue)
        try await stream.startCapture()

        // Bounded, user-triggered window — never continuous. Stop the tap, then let the recognizer
        // drain the final partial into a finalized transcript.
        try? await Task.sleep(nanoseconds: UInt64(maxDuration * 1_000_000_000))
        try? await stream.stopCapture()
        request.endAudio()

        let transcript = await collector.waitForFinal(timeout: 3)
        task.cancel()
        return transcript
    }

    private static let audioQueue = DispatchQueue(label: "com.peeknook.systemaudio.capture")
}

/// Thread-safe accumulator for the recognizer's partial/final transcripts (callbacks land on an
/// arbitrary queue). Lets the async tap await a finalized string with a hard timeout.
private final class TranscriptCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var latest = ""
    private var isFinished = false

    func update(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        latest = text
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        isFinished = true
    }

    /// Poll for a finalized transcript, returning the best-so-far text once the recognizer finishes
    /// or the timeout elapses. Polling (not a continuation) keeps the unchecked-Sendable surface tiny.
    func waitForFinal(timeout: TimeInterval) async -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let done = isFinished
            let text = latest
            lock.unlock()
            if done { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        lock.lock(); defer { lock.unlock() }
        return latest.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#endif

/// Stand-in for platforms without ScreenCaptureKit/Speech (so the package compiles everywhere). Always
/// throws — the ground simply has no hardware to run on those targets.
struct UnavailableSystemAudioTranscriber: SystemAudioTranscribing {
    func recordAndTranscribe(maxDuration: TimeInterval) async throws -> String {
        _ = maxDuration
        throw CaptureError.failed("Hearing the screen requires macOS with ScreenCaptureKit and Speech.")
    }
}

// MARK: - Test-only stub

/// Deterministic system-audio double for unit tests and the UI test host. Returns a scripted
/// transcript (or throws a scripted error) without touching any hardware, mirroring
/// ``StubCaptureProvider``.
public struct StubSystemAudioTranscriber: SystemAudioTranscribing {
    public var scriptedTranscript: String
    public var error: CaptureError?

    public init(scriptedTranscript: String = "Let's ship the release on Friday.", error: CaptureError? = nil) {
        self.scriptedTranscript = scriptedTranscript
        self.error = error
    }

    public func recordAndTranscribe(maxDuration: TimeInterval) async throws -> String {
        _ = maxDuration
        if let error { throw error }
        return scriptedTranscript
    }
}
