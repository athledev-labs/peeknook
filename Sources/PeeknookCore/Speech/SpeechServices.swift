// SPDX-License-Identifier: Apache-2.0

import Foundation

#if canImport(AVFoundation)
import AVFoundation
#endif

/// Local text-to-speech for answers. Implementations must stay on-device.
public protocol SpeechSynthesizing: Sendable {
    @MainActor func speak(_ text: String, voiceIdentifier: String?)
    @MainActor func stopSpeaking()
    @MainActor var isSpeaking: Bool { get }
}

/// Optional UI callbacks for synthesizers that report lifecycle and read-along ranges.
@MainActor
public protocol SpeechSynthesizingStateful: SpeechSynthesizing {
    var onSpeakingChanged: (() -> Void)? { get set }
    var onSpeakRange: ((NSRange) -> Void)? { get set }
}

/// On-device speech recognition for briefs and follow-ups.
public protocol SpeechRecognizing: Sendable {
    @MainActor func requestAuthorization() async -> Bool
    @MainActor func startListening(onPartial: @escaping @Sendable (String) -> Void) async throws
    @MainActor func stopListening() -> String
    @MainActor var isListening: Bool { get }
}

public enum SpeechRecognitionError: Error, Sendable, Equatable {
    case unavailable
    case notAuthorized
    case onDeviceUnavailable
}

#if canImport(AVFoundation)
@MainActor
public final class AppleSpeechSynthesizer: SpeechSynthesizingStateful {
    private let synthesizer = AVSpeechSynthesizer()
    private let delegateBridge = SynthesizerDelegateBridge()
    private var trackSpeaking = false

    public var onSpeakingChanged: (() -> Void)?
    public var onSpeakRange: ((NSRange) -> Void)?

    public init() {
        synthesizer.delegate = delegateBridge
        delegateBridge.onUtteranceEnded = { [weak self] in
            guard let self else { return }
            self.trackSpeaking = false
            self.onSpeakingChanged?()
        }
        delegateBridge.onSpeakRange = { [weak self] range in
            self?.onSpeakRange?(range)
        }
    }

    public var isSpeaking: Bool { trackSpeaking || synthesizer.isSpeaking }

    public func speak(_ text: String, voiceIdentifier: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stopSpeaking()
        let utterance = AVSpeechUtterance(string: trimmed)
        let voiceID = voiceIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let voiceID, SpeechVoiceCatalog.isOffered(identifier: voiceID),
           let voice = AVSpeechSynthesisVoice(identifier: voiceID) {
            utterance.voice = voice
        } else {
            // "Automatic" (or a saved voice we no longer offer, e.g. an old novelty "Whisper" pick):
            // prefer the best installed neural voice over macOS's robotic compact default.
            let language = Locale.preferredLanguages.first ?? "en-US"
            utterance.voice = SpeechVoiceCatalog.bestAvailableVoice(forLanguage: language)
                ?? AVSpeechSynthesisVoice(language: language)
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        trackSpeaking = true
        synthesizer.speak(utterance)
        onSpeakingChanged?()
    }

    public func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        trackSpeaking = false
        onSpeakingChanged?()
    }
}

@MainActor
private final class SynthesizerDelegateBridge: NSObject, @preconcurrency AVSpeechSynthesizerDelegate {
    var onUtteranceEnded: (() -> Void)?
    var onSpeakRange: ((NSRange) -> Void)?

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        onSpeakRange?(characterRange)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onUtteranceEnded?()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        onUtteranceEnded?()
    }
}
#endif

#if canImport(Speech) && canImport(AVFoundation)
import Speech

@MainActor
public final class AppleSpeechRecognizer: SpeechRecognizing {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let engine = AVAudioEngine()
    private var latestTranscript = ""
    public private(set) var isListening = false

    public init() {}

    public func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    public func startListening(onPartial: @escaping @Sendable (String) -> Void) async throws {
        guard !isListening else { return }
        guard recognizer?.isAvailable == true else {
            throw SpeechRecognitionError.unavailable
        }
        guard recognizer?.supportsOnDeviceRecognition == true else {
            throw SpeechRecognitionError.onDeviceUnavailable
        }
        latestTranscript = ""
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        engine.prepare()
        try engine.start()
        isListening = true

        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                self.latestTranscript = text
                onPartial(text)
            }
            if error != nil || result?.isFinal == true {
                Task { @MainActor in
                    _ = self.stopListening()
                }
            }
        }
    }

    public func stopListening() -> String {
        guard isListening else { return latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines) }
        isListening = false
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        return latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif

/// Test double — records speak calls without audio output.
@MainActor
public final class StubSpeechSynthesizer: SpeechSynthesizingStateful {
    public private(set) var lastSpoken: String?
    public private(set) var lastVoiceIdentifier: String?
    public var isSpeaking = false
    public var onSpeakingChanged: (() -> Void)?
    public var onSpeakRange: ((NSRange) -> Void)?

    public init() {}

    public func speak(_ text: String, voiceIdentifier: String? = nil) {
        lastSpoken = text
        lastVoiceIdentifier = voiceIdentifier
        isSpeaking = true
        onSpeakingChanged?()
    }

    public func stopSpeaking() {
        isSpeaking = false
        onSpeakingChanged?()
    }
}

@MainActor
public final class StubSpeechRecognizer: SpeechRecognizing {
    public var authorized = true
    public var isListening = false
    public var scriptedFinal = ""
    public var startError: SpeechRecognitionError?
    private var partialHandler: (@Sendable (String) -> Void)?

    public init() {}

    public func requestAuthorization() async -> Bool { authorized }

    public func startListening(onPartial: @escaping @Sendable (String) -> Void) async throws {
        if let startError { throw startError }
        isListening = true
        partialHandler = onPartial
        if !scriptedFinal.isEmpty { onPartial(scriptedFinal) }
    }

    public func stopListening() -> String {
        isListening = false
        return scriptedFinal
    }
}
