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

/// On-device speech recognition for briefs and follow-ups.
public protocol SpeechRecognizing: Sendable {
    @MainActor func requestAuthorization() async -> Bool
    @MainActor func startListening(onPartial: @escaping @Sendable (String) -> Void) async throws
    @MainActor func stopListening() -> String
    @MainActor var isListening: Bool { get }
}

#if canImport(AVFoundation)
@MainActor
public final class AppleSpeechSynthesizer: SpeechSynthesizing {
    private let synthesizer = AVSpeechSynthesizer()

    public init() {}

    public var isSpeaking: Bool { synthesizer.isSpeaking }

    public func speak(_ text: String, voiceIdentifier: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stopSpeaking()
        let utterance = AVSpeechUtterance(string: trimmed)
        let voiceID = voiceIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let voiceID, !voiceID.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: voiceID) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: Locale.preferredLanguages.first ?? "en-US")
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    public func stopSpeaking() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
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
        latestTranscript = ""
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
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

public enum SpeechRecognitionError: Error, Sendable, Equatable {
    case unavailable
    case notAuthorized
}
#endif

/// Test double — records speak calls without audio output.
@MainActor
public final class StubSpeechSynthesizer: SpeechSynthesizing {
    public private(set) var lastSpoken: String?
    public private(set) var lastVoiceIdentifier: String?
    public var isSpeaking = false

    public init() {}

    public func speak(_ text: String, voiceIdentifier: String? = nil) {
        lastSpoken = text
        lastVoiceIdentifier = voiceIdentifier
        isSpeaking = true
    }

    public func stopSpeaking() {
        isSpeaking = false
    }
}

@MainActor
public final class StubSpeechRecognizer: SpeechRecognizing {
    public var authorized = true
    public var isListening = false
    public var scriptedFinal = ""
    private var partialHandler: (@Sendable (String) -> Void)?

    public init() {}

    public func requestAuthorization() async -> Bool { authorized }

    public func startListening(onPartial: @escaping @Sendable (String) -> Void) async throws {
        isListening = true
        partialHandler = onPartial
        if !scriptedFinal.isEmpty { onPartial(scriptedFinal) }
    }

    public func stopListening() -> String {
        isListening = false
        return scriptedFinal
    }
}
