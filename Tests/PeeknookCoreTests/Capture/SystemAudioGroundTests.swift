// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// The system-audio ground ("hear the screen"): a new perception surface that records a short,
/// user-triggered window of system audio and transcribes it on-device into a TEXT leg — no image, so
/// it never trips the vision gate. These tests cover everything except the live ScreenCaptureKit /
/// SFSpeechRecognizer tap (hardware-only); that path is isolated behind ``SystemAudioTranscribing``
/// and faked here with ``StubSystemAudioTranscriber``.
final class SystemAudioGroundTests: XCTestCase {
    private static let encoding = CaptureEncodingPolicy.resolve(scope: .window, quick: false, quality: .balanced)

    // MARK: - Ground value + permissions

    func testSystemAudioGroundHasStableRawValue() {
        XCTAssertEqual(Ground.systemAudio.rawValue, "systemAudio")
        XCTAssertEqual(Ground(rawValue: "systemAudio"), .systemAudio)
        XCTAssertTrue(Ground.allCases.contains(.systemAudio))
    }

    func testSystemAudioRequiresScreenRecordingAndSpeech() {
        // ScreenCaptureKit audio needs Screen Recording; on-device transcription needs Speech. NOT
        // Microphone — this ground hears the screen's output, not the user's voice.
        XCTAssertEqual(Ground.systemAudio.requiredPermissions, [.screenRecording, .speechRecognition])
        XCTAssertFalse(Ground.systemAudio.requiredPermissions.contains(.microphone))
    }

    // MARK: - Provider policy (transcript leg, no vision)

    func testProviderReturnsTranscriptTextLegWithNoImage() async throws {
        let provider = SystemAudioCaptureProvider(
            transcriber: StubSystemAudioTranscriber(scriptedTranscript: "We agreed to demo on Thursday.")
        )
        let result = try await provider.capture(scope: .window, quick: false, encoding: Self.encoding)

        XCTAssertEqual(result.ground, .systemAudio)
        XCTAssertEqual(result.text, "We agreed to demo on Thursday.")
        XCTAssertNil(result.screenshotBase64, "an audio leg carries no image")
        XCTAssertNil(result.screenshotBlobID)
        XCTAssertFalse(result.hasVision, "no image means the vision gate must never engage")
    }

    func testProviderThrowsNoContentOnEmptyTranscript() async {
        let provider = SystemAudioCaptureProvider(
            transcriber: StubSystemAudioTranscriber(scriptedTranscript: "   ")
        )
        do {
            _ = try await provider.capture(scope: .window, quick: false, encoding: Self.encoding)
            XCTFail("an empty transcript must throw, not ship a blank leg")
        } catch {
            XCTAssertEqual(error as? CaptureError, .noContent)
        }
    }

    func testProviderSurfacesTranscriberError() async {
        let provider = SystemAudioCaptureProvider(
            transcriber: StubSystemAudioTranscriber(error: .permissionRequired("Speech Recognition"))
        )
        do {
            _ = try await provider.capture(scope: .window, quick: false, encoding: Self.encoding)
            XCTFail("a transcriber failure must propagate")
        } catch {
            XCTAssertEqual(error as? CaptureError, .permissionRequired("Speech Recognition"))
        }
    }

    // MARK: - Registry wiring

    func testTestingDependenciesRegisterSystemAudioProvider() async throws {
        let deps = await PeeknookDependencies.testing()
        let provider = try deps.captureRegistry.resolve(.systemAudio)
        XCTAssertTrue(provider is SystemAudioCaptureProvider)
        let result = try await provider.capture(scope: .window, quick: false, encoding: Self.encoding)
        XCTAssertEqual(result.ground, .systemAudio)
        XCTAssertFalse(result.hasVision)
    }

    // MARK: - Single-leg prompt (transcript, not a screenshot)

    func testTranscriptLegPromptDescribesAudioNotScreenshot() {
        let capture = CaptureResult(
            text: "Q3 numbers are up twelve percent.",
            sourceLabel: "System audio",
            ground: .systemAudio
        )
        let message = PromptBuilder.captureUserMessage(capture: capture, assembly: PromptAssembly(answerDepth: .deep))

        XCTAssertTrue(message.contains("Ground: system audio"), "the audio ground is named")
        XCTAssertTrue(message.contains("Transcript of system audio:"), "the text is labelled as a transcript")
        XCTAssertTrue(message.contains("Q3 numbers are up twelve percent."), "the transcript rides in the message")
        XCTAssertFalse(message.contains("A screenshot is attached"), "no screenshot is claimed")
        XCTAssertFalse(message.contains("rely on the screenshot"), "an image-less leg must not point at a screenshot")
        XCTAssertFalse(message.contains("prefer the screenshot"), "the transcript is primary, not supplementary")
    }

    // MARK: - Multi-ground prompt (screen image + audio transcript)

    func testMultiGroundPromptNamesScreenshotAndTranscriptCorrectly() {
        let screen = MediaPayload(
            capture: CaptureResult(text: "Slide 4 title", sourceLabel: "Keynote", appName: "Keynote", screenshotBase64: "SCRb64", ground: .screen),
            kind: .image,
            imageBase64: "SCRb64"
        )
        let audio = MediaPayload(
            capture: CaptureResult(text: "He said the deadline moved to Monday.", sourceLabel: "System audio", ground: .systemAudio),
            kind: .transcript,
            imageBase64: nil
        )
        let message = PromptBuilder.multiGroundUserMessage(
            payloads: [screen, audio],
            assembly: PromptAssembly(answerDepth: .deep)
        )

        // Only the screen leg is an image; the audio leg contributes text only.
        XCTAssertTrue(message.contains("(1 views, one question)"), "only the one image view is counted")
        XCTAssertTrue(message.contains("SCREENSHOT"), "the screen leg is named as a screenshot")
        XCTAssertTrue(message.contains("Transcript of the system audio:"), "the audio leg reads as a transcript")
        XCTAssertTrue(message.contains("He said the deadline moved to Monday."), "the transcript text is present")
        XCTAssertFalse(
            message.contains("Supplementary extracted text from the system audio"),
            "the transcript must not be framed as supplement-to-image"
        )
    }

    // MARK: - End-to-end: a transcript leg flows through inference as text and is NOT vision-gated

    /// A text-only model would BLOCK a screenshot turn (`.textOnly` readiness), but an audio-only turn
    /// must pass: the gate keys on `hasVision`, which is false for a transcript leg. Proven through the
    /// orchestrator's real request path with a model that declares no vision capability.
    @MainActor
    func testSystemAudioTurnFlowsAsTextAndSkipsVisionGate() async {
        let engine = RecordingTextOnlyEngine(tokens: ["answer about the call"])
        let o = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "text-only-model"),
            captureRegistry: GroundRegistry([:]),   // empty: drive to an accepting phase deterministically
            inference: engine
        )

        // Reach a phase that accepts `.inferenceStarted` without any vision-capable capture: an empty
        // registry fails capture loudly, landing in `.failed` (one of the accepting phases).
        o.beginCapture()
        _ = await o.waitForFailed()

        // Now stage an audio leg and run the turn directly — exactly the shape a "hear the screen"
        // capture produces.
        let audio = CaptureResult(text: "Let's reconvene after lunch.", sourceLabel: "System audio", ground: .systemAudio)
        o.turnCounter += 1
        o.conversation.append(ChatTurn(id: o.turnCounter, kind: .image(audio)))
        await o.runTurn(capturedNow: audio)

        guard case .result(let answer) = o.phase else {
            return XCTFail("an audio-only turn must reach a result, not be blocked by the vision gate; phase = \(o.phase)")
        }
        XCTAssertEqual(answer, "answer about the call")

        let userMessage = engine.requests.last?.messages.last { $0.role == .user }
        XCTAssertTrue(userMessage?.text.contains("Let's reconvene after lunch.") ?? false, "the transcript reaches the model as text")
        XCTAssertTrue(userMessage?.imagesBase64.isEmpty ?? false, "no image rides with an audio leg")
    }
}

/// Records each request and declares NO vision capability, so the vision gate would resolve a
/// screenshot turn to `.textOnly` (block). Lets the test prove an audio leg skips that gate entirely.
private final class RecordingTextOnlyEngine: InferenceEngine, @unchecked Sendable {
    private(set) var requests: [InferenceRequest] = []
    private let tokens: [String]

    init(tokens: [String]) { self.tokens = tokens }

    func health(baseURL: String, model: String, acceptInsecureRemote: Bool) async -> InferenceHealth { .ready }
    func warmUp(model: String, baseURL: String, acceptInsecureRemote: Bool) async -> Bool { true }
    func contextLength(model: String, baseURL: String, acceptInsecureRemote: Bool) async -> Int? { nil }
    // Present-but-no-vision: this is what forces `.textOnly` for an image turn.
    func capabilities(model: String, baseURL: String, acceptInsecureRemote: Bool) async -> [String]? { ["completion"] }

    func generateFollowUps(request: InferenceRequest) async -> FollowUpGenerationResult {
        FollowUpGenerationResult(suggestions: [], stats: nil)
    }

    func stream(request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        requests.append(request)
        let tokens = self.tokens
        return AsyncThrowingStream { continuation in
            for token in tokens { continuation.yield(.token(token)) }
            continuation.yield(.completed(nil))
            continuation.finish()
        }
    }
}
