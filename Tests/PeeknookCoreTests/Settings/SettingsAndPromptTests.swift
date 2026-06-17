// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

final class SettingsAndPromptTests: XCTestCase {
    func testLegacySettingsDecodeKeepsValuesAndDefaultsQuickMode() throws {
        // A blob saved before `quickMode` existed must NOT reset the other fields.
        let legacy = Data("""
        {"mode":"general","previewBeforeInfer":false,"ollamaBaseURL":"http://host:1","textModel":"gemma4:e4b"}
        """.utf8)
        let settings = try JSONDecoder().decode(PeeknookSettings.self, from: legacy)
        XCTAssertEqual(settings.textModel, "gemma4:e4b")
        XCTAssertEqual(settings.ollamaBaseURL, "http://host:1")
        XCTAssertFalse(settings.previewBeforeInfer)
        XCTAssertFalse(settings.quickMode) // defaulted, not a decode failure
    }

    func testQuickModeRoundTrips() throws {
        let settings = PeeknookSettings(textModel: "gemma4:e4b", quickMode: true)
        let data = try JSONEncoder().encode(settings)
        let back = try JSONDecoder().decode(PeeknookSettings.self, from: data)
        XCTAssertTrue(back.quickMode)
    }

    func testCaptureScopeDefaultsToWindowAndRoundTrips() throws {
        // Missing key (legacy blob) defaults to .window.
        let legacy = Data("""
        {"mode":"general","previewBeforeInfer":true,"ollamaBaseURL":"http://127.0.0.1:11434","textModel":"gemma4:e4b"}
        """.utf8)
        XCTAssertEqual(try JSONDecoder().decode(PeeknookSettings.self, from: legacy).captureScope, .window)

        let display = PeeknookSettings(textModel: "gemma4:e4b", captureScope: .display)
        let back = try JSONDecoder().decode(PeeknookSettings.self, from: JSONEncoder().encode(display))
        XCTAssertEqual(back.captureScope, .display)
    }

    func testQuickPromptAddsTerseInstruction() {
        let capture = CaptureResult(text: nil, sourceLabel: "Front window (vision)", screenshotBase64: "x")
        let assembly = PromptAssembly(answerDepth: .deep)
        let quickAssembly = PromptAssembly(answerDepth: .quick)
        let normal = PromptBuilder.captureUserMessage(capture: capture, assembly: assembly)
        let quick = PromptBuilder.captureUserMessage(capture: capture, assembly: quickAssembly)
        XCTAssertTrue(normal.contains("**Deep**"))
        XCTAssertTrue(quick.contains("**Quick**"))
    }

    func testCameraGroundLabelsThePrompt() {
        let capture = CaptureResult(
            text: nil,
            sourceLabel: "Camera (live)",
            screenshotBase64: "x",
            ground: .camera
        )
        let message = PromptBuilder.captureUserMessage(capture: capture, assembly: PromptAssembly(answerDepth: .deep))
        XCTAssertTrue(message.contains("Ground: camera"))
        XCTAssertTrue(message.contains("A camera photo is attached"))
        XCTAssertFalse(message.contains("A screenshot is attached"))
    }

    func testScreenGroundPromptKeepsScreenshotWording() {
        let capture = CaptureResult(text: nil, sourceLabel: "Front window (vision)", screenshotBase64: "x")
        let message = PromptBuilder.captureUserMessage(capture: capture, assembly: PromptAssembly(answerDepth: .deep))
        XCTAssertTrue(message.contains("A screenshot is attached to this message (vision)."))
        XCTAssertFalse(message.contains("Ground: camera"))
    }

    func testFileGroundKeepsImportedFileWording() {
        let capture = CaptureResult(text: nil, sourceLabel: "report.pdf", screenshotBase64: "x", ground: .file)
        let message = PromptBuilder.captureUserMessage(capture: capture, assembly: PromptAssembly(answerDepth: .deep))
        XCTAssertTrue(message.contains("Ground: imported file"))
        XCTAssertTrue(message.contains("An image from the imported file is attached to this message (vision)."))
        XCTAssertFalse(message.contains("A screenshot is attached"))
    }

    func testSystemAudioGroundKeepsTranscriptWordingAndClaimsNoScreenshot() {
        let capture = CaptureResult(text: "Deadline moved to Monday.", sourceLabel: "System audio", ground: .systemAudio)
        let message = PromptBuilder.captureUserMessage(capture: capture, assembly: PromptAssembly(answerDepth: .deep))
        XCTAssertTrue(message.contains("Ground: system audio"))
        XCTAssertTrue(message.contains("Transcript of system audio:"))
        XCTAssertFalse(message.contains("A screenshot is attached"), "an audio leg must never claim a screenshot")
    }

    func testMultiGroundScreenAndTranscriptKeepTheirModalityWording() {
        let screen = MediaPayload(
            capture: CaptureResult(text: nil, sourceLabel: "Keynote", appName: "Keynote", screenshotBase64: "b", ground: .screen),
            kind: .image,
            imageBase64: "b"
        )
        let audio = MediaPayload(
            capture: CaptureResult(text: "We will reconvene at noon.", sourceLabel: "System audio", ground: .systemAudio),
            kind: .transcript
        )
        let message = PromptBuilder.multiGroundUserMessage(payloads: [screen, audio], assembly: PromptAssembly(answerDepth: .deep))
        XCTAssertTrue(message.contains("Image 1 is a SCREENSHOT of the Mac display"))
        XCTAssertTrue(message.contains("Transcript of the system audio:"))
    }

    /// A never-shipped, text-only ground must NOT silently inherit the screenshot wording: with the
    /// per-ground copy centralized on `Ground`, a transcript leg from such a ground is honestly
    /// labelled and never claims an attached screenshot.
    func testNonScreenTextOnlyGroundDoesNotClaimScreenshot() {
        let capture = CaptureResult(text: "the selection", sourceLabel: "Pages", ground: .selectedText)
        let message = PromptBuilder.captureUserMessage(capture: capture, assembly: PromptAssembly(answerDepth: .deep))
        XCTAssertFalse(
            message.contains("A screenshot is attached to this message (vision)."),
            "a text-only ground without vision must not claim a screenshot"
        )
        XCTAssertTrue(message.contains("Ground: selected text"))
    }

    func testCaptureUserMessageFoldsQuestionWhenPresent() {
        let capture = CaptureResult(text: "t", sourceLabel: "Safari (vision)", screenshotBase64: "x")
        let withQ = PromptBuilder.captureUserMessage(
            capture: capture, assembly: PromptAssembly(answerDepth: .deep), question: "what is this?"
        )
        XCTAssertTrue(withQ.contains("## Question"))
        XCTAssertTrue(withQ.contains("what is this?"))
        XCTAssertTrue(withQ.contains("Answer the question above using the screenshot."))
        XCTAssertFalse(withQ.contains("Respond to the screenshot above."), "the question replaces the default Task line")
    }

    func testCaptureUserMessageWithNilOrBlankQuestionIsByteIdentical() {
        let capture = CaptureResult(text: "t", sourceLabel: "Safari (vision)", screenshotBase64: "x")
        let plain = PromptBuilder.captureUserMessage(capture: capture, assembly: PromptAssembly(answerDepth: .deep))
        let blank = PromptBuilder.captureUserMessage(
            capture: capture, assembly: PromptAssembly(answerDepth: .deep), question: "   "
        )
        XCTAssertEqual(blank, plain, "a blank question is the same as none")
        XCTAssertTrue(plain.contains("Respond to the screenshot above."))
        XCTAssertFalse(plain.contains("## Question"))
    }

    func testWebLookupPromptAddsSearchContext() {
        let capture = CaptureResult(text: "Swift actors", sourceLabel: "Front window (vision)", screenshotBase64: "x")
        let snapshot = WebLookupSnapshot(
            query: "Swift actors",
            results: [WebSearchResult(title: "Actors", url: URL(string: "https://example.com")!, snippet: "Docs")]
        )
        let message = PromptBuilder.captureUserMessage(
            capture: capture,
            assembly: PromptAssembly(answerDepth: .deep),
            webLookup: snapshot
        )
        XCTAssertTrue(message.contains("Live web lookup"))
        XCTAssertTrue(message.contains("Actors"))
    }

    func testCameraHotkeyDefaultsToCommandShiftCAndRoundTrips() throws {
        // A settings blob written before the key existed keeps everything and defaults ⌘⇧C.
        let legacy = Data("""
        {"mode":"general","textModel":"gemma4:e4b"}
        """.utf8)
        XCTAssertEqual(try JSONDecoder().decode(PeeknookSettings.self, from: legacy).cameraHotkey, .defaultCamera)
        XCTAssertEqual(CaptureHotkey.defaultCamera.display, "⇧⌘C")   // display order is ⌃⌥⇧⌘

        var custom = PeeknookSettings(textModel: "gemma4:e4b")
        custom.cameraHotkey = CaptureHotkey(keyCode: 40, carbonModifiers: 256 | 512, keySymbol: "K")
        let back = try JSONDecoder().decode(PeeknookSettings.self, from: JSONEncoder().encode(custom))
        XCTAssertEqual(back.cameraHotkey.keySymbol, "K")
    }

    func testCaptureHotkeyDefaultsToCommandShiftPAndRoundTrips() throws {
        let legacy = Data("""
        {"mode":"general","textModel":"gemma4:e4b"}
        """.utf8)
        XCTAssertEqual(try JSONDecoder().decode(PeeknookSettings.self, from: legacy).captureHotkey, .default)

        var custom = PeeknookSettings(textModel: "gemma4:e4b")
        custom.captureHotkey = CaptureHotkey(keyCode: 9, carbonModifiers: 256, keySymbol: "V")
        let back = try JSONDecoder().decode(PeeknookSettings.self, from: JSONEncoder().encode(custom))
        XCTAssertEqual(back.captureHotkey.keySymbol, "V")
    }

    func testTextModelCatalogDisplayName() {
        XCTAssertEqual(TextModelCatalog.displayName(for: "gemma4:e2b"), "Gemma 4 E2B")
        XCTAssertEqual(TextModelCatalog.displayName(for: "gemma4:26b"), "Gemma 4 26B")
        XCTAssertEqual(TextModelCatalog.displayName(for: "custom:model"), "custom:model")
    }

    func testInferenceModelOptionMenuDetail() {
        let option = TextModelCatalog.offered[1]
        XCTAssertEqual(option.displayName, "Gemma 4 E4B")
        XCTAssertEqual(option.menuDetail, "gemma4:e4b · Ollama · ~10 GB")
    }

    func testSuggestFollowUpsSettingDefaultsTrueAndRoundTrips() throws {
        // Legacy blob without the key keeps suggestions on.
        let legacy = Data(#"{"mode":"general","textModel":"gemma4:e4b"}"#.utf8)
        XCTAssertTrue(try JSONDecoder().decode(PeeknookSettings.self, from: legacy).suggestFollowUps)

        let off = PeeknookSettings(textModel: "gemma4:e4b", suggestFollowUps: false)
        XCTAssertFalse(try JSONDecoder().decode(PeeknookSettings.self, from: JSONEncoder().encode(off)).suggestFollowUps)
    }

    func testParseSuggestionsReadsSchemaConstrainedJSON() {
        // What Ollama returns for a non-stream chat with a JSON-schema `format`: blank dropped,
        // then capped at 3 (so the trailing "extra" is cut).
        let body = Data(#"""
        {"message":{"role":"assistant","content":"{\"suggestions\":[\"How do I fix it?\",\"  \",\"What line?\",\"Why did it happen?\",\"extra\"]}"}}
        """#.utf8)
        let suggestions = OllamaInferenceEngine.parseSuggestions(from: body)
        XCTAssertEqual(suggestions, ["How do I fix it?", "What line?", "Why did it happen?"])
    }

    func testParseSuggestionsToleratesGarbage() {
        XCTAssertTrue(OllamaInferenceEngine.parseSuggestions(from: Data("not json".utf8)).isEmpty)
        XCTAssertTrue(OllamaInferenceEngine.parseSuggestions(from: Data(#"{"message":{"content":"oops"}}"#.utf8)).isEmpty)
    }

    func testParseChatStatsReadsTokenCounts() {
        let body = Data(#"{"done":true,"prompt_eval_count":1200,"eval_count":45,"eval_duration":500000000}"#.utf8)
        let stats = OllamaInferenceEngine.parseChatStats(from: body)
        XCTAssertEqual(stats?.promptTokens, 1200)
        XCTAssertEqual(stats?.responseTokens, 45)
    }

    func testParseContextLengthFindsArchPrefixedKey() {
        let body = Data(#"{"model_info":{"general.architecture":"gemma3","gemma3.context_length":8192}}"#.utf8)
        XCTAssertEqual(OllamaInferenceEngine.parseContextLength(from: body), 8192)
        XCTAssertNil(OllamaInferenceEngine.parseContextLength(from: Data("{}".utf8)))
    }

    func testParseCapabilitiesReadsArrayAndNilWhenAbsent() {
        let body = Data(#"{"capabilities":["completion","vision"]}"#.utf8)
        XCTAssertEqual(OllamaInferenceEngine.parseCapabilities(from: body), ["completion", "vision"])
        XCTAssertNil(OllamaInferenceEngine.parseCapabilities(from: Data("{}".utf8)))
    }

    func testCustomModelsDecodeTolerantlyAndRoundTrip() throws {
        // Legacy blob (no key) keeps an empty list, not a decode failure.
        let legacy = Data(#"{"mode":"general","textModel":"gemma4:e4b"}"#.utf8)
        XCTAssertTrue(try JSONDecoder().decode(PeeknookSettings.self, from: legacy).customModels.isEmpty)

        let withCustom = PeeknookSettings(
            textModel: "gemma4:e4b",
            customModels: [CustomModelEntry(tag: "qwen3-vl:8b", displayName: "Qwen3 VL")]
        )
        let back = try JSONDecoder().decode(PeeknookSettings.self, from: JSONEncoder().encode(withCustom))
        XCTAssertEqual(back.customModels.map(\.tag), ["qwen3-vl:8b"])
        XCTAssertEqual(back.customModels.first?.resolvedDisplayName, "Qwen3 VL")
    }

    func testCustomModelEntryTrimsAndFallsBackToTag() {
        let entry = CustomModelEntry(tag: "  llava:13b  ", displayName: "   ")
        XCTAssertEqual(entry.tag, "llava:13b")
        XCTAssertNil(entry.displayName)
        XCTAssertEqual(entry.resolvedDisplayName, "llava:13b")
    }

    func testMergedCatalogAppendsCustomAndDedupes() {
        let custom = [
            CustomModelEntry(tag: "qwen3-vl:8b"),
            CustomModelEntry(tag: "gemma4:e2b"), // already curated, must not duplicate
        ]
        let merged = TextModelCatalog.merged(custom: custom)
        XCTAssertEqual(merged.filter { $0.tag == "gemma4:e2b" }.count, 1)
        XCTAssertTrue(merged.contains { $0.tag == "qwen3-vl:8b" })
        XCTAssertEqual(TextModelCatalog.displayName(for: "qwen3-vl:8b", custom: custom), "qwen3-vl:8b")
    }

    @MainActor
    func testOnboardingCompletePersists() {
        let defaults = UserDefaults(suiteName: "peeknook.tests.onboarding")!
        defaults.removePersistentDomain(forName: "peeknook.tests.onboarding")
        let setup = SetupCoordinator(settings: .default, defaults: defaults)
        XCTAssertFalse(setup.hasCompletedOnboarding)
        setup.markOnboardingComplete()
        XCTAssertTrue(defaults.bool(forKey: SetupCoordinator.onboardingCompleteKey))
        let reloaded = SetupCoordinator(settings: .default, defaults: defaults)
        XCTAssertTrue(reloaded.hasCompletedOnboarding)
    }

    func testUndiscoveredTagsExcludeKnownAndDedupe() {
        let known = TextModelCatalog.offered.map(\.tag)
        let installed = ["gemma4:e4b", "qwen3-vl:8b", "qwen3-vl:8b", "llama3:latest"]
        let undiscovered = ModelTagDiscovery.undiscovered(installedNames: installed, knownTags: known)
        XCTAssertEqual(undiscovered, ["llama3:latest", "qwen3-vl:8b"])
    }

    func testPersonalAndAnswerRenderingSettingsDefaultAndRoundTrip() throws {
        let legacy = Data(#"{"mode":"general","textModel":"gemma4:e4b"}"#.utf8)
        let decoded = try JSONDecoder().decode(PeeknookSettings.self, from: legacy)
        XCTAssertEqual(decoded.displayName, "")
        XCTAssertTrue(decoded.showGreeting)
        XCTAssertTrue(decoded.renderAnswerMarkdown)

        let custom = PeeknookSettings(
            textModel: "gemma4:e4b",
            displayName: "Alex",
            showGreeting: false,
            renderAnswerMarkdown: false
        )
        let back = try JSONDecoder().decode(PeeknookSettings.self, from: JSONEncoder().encode(custom))
        XCTAssertEqual(back.displayName, "Alex")
        XCTAssertFalse(back.showGreeting)
        XCTAssertFalse(back.renderAnswerMarkdown)
    }

    func testSessionBriefPromptIncludesUserIntent() {
        let capture = CaptureResult(text: nil, sourceLabel: "Front window (vision)", screenshotBase64: "x")
        let message = PromptBuilder.captureUserMessage(
            capture: capture,
            assembly: PromptAssembly(
                answerDepth: .deep,
                sessionBrief: "Recommend the best move with one line why"
            )
        )
        XCTAssertTrue(message.contains("## Session brief"))
        XCTAssertTrue(message.contains("Recommend the best move with one line why"))
    }

    func testSystemPromptDefinesPriorityOrder() {
        let prompt = PromptBuilder.systemPrompt()
        XCTAssertTrue(prompt.contains("## Priority"))
        XCTAssertTrue(prompt.contains("Session brief"))
        XCTAssertTrue(prompt.contains("Answer depth"))
    }

    func testSystemPromptAcceptsAgentAppendix() {
        let prompt = PromptBuilder.systemPrompt(agentAppendix: "Always respond in bullet points.")
        XCTAssertTrue(prompt.contains("## Custom agent"))
        XCTAssertTrue(prompt.contains("Always respond in bullet points."))
    }

    func testFollowUpMessageRemindsSessionBrief() {
        let message = PromptBuilder.followUpUserMessage(
            question: "What next?",
            assembly: PromptAssembly(
                answerDepth: .deep,
                sessionBrief: "Themes only, no engine lines"
            )
        )
        XCTAssertTrue(message.contains("## Session brief (reminder)"))
        XCTAssertTrue(message.contains("Themes only"))
        XCTAssertTrue(message.contains("What next?"))
    }

    func testContinuingSessionMessageOnLaterCapture() {
        let capture = CaptureResult(text: nil, sourceLabel: "Front window (vision)", screenshotBase64: "x")
        let message = PromptBuilder.captureUserMessage(
            capture: capture,
            assembly: PromptAssembly(answerDepth: .deep, continuingSession: true)
        )
        XCTAssertTrue(message.contains("## Session context"))
        XCTAssertTrue(message.contains("Continuing chat"))
    }

    func testVoiceSettingsDefaultOffAndRoundTrip() throws {
        let legacy = Data(#"{"mode":"general","textModel":"gemma4:e4b"}"#.utf8)
        let decoded = try JSONDecoder().decode(PeeknookSettings.self, from: legacy)
        XCTAssertFalse(decoded.voiceInputEnabled)
        XCTAssertFalse(decoded.speakAnswersEnabled)
        XCTAssertTrue(decoded.highlightSpeechWhileReading)
        XCTAssertEqual(decoded.speechVoiceIdentifier, "")
        XCTAssertEqual(decoded.briefHotkey, .defaultBrief)

        let on = PeeknookSettings(
            textModel: "gemma4:e4b",
            voiceInputEnabled: true,
            speakAnswersEnabled: true,
            highlightSpeechWhileReading: false,
            speechVoiceIdentifier: "com.apple.voice.enhanced.en-US.Ava",
            briefHotkey: CaptureHotkey(keyCode: 9, carbonModifiers: 256, keySymbol: "V")
        )
        let back = try JSONDecoder().decode(PeeknookSettings.self, from: JSONEncoder().encode(on))
        XCTAssertTrue(back.voiceInputEnabled)
        XCTAssertTrue(back.speakAnswersEnabled)
        XCTAssertFalse(back.highlightSpeechWhileReading)
        XCTAssertEqual(back.speechVoiceIdentifier, "com.apple.voice.enhanced.en-US.Ava")
        XCTAssertEqual(back.briefHotkey.keySymbol, "V")
    }

    func testLivePersistAcrossDoneDefaultsOffAndRoundTrips() throws {
        // A legacy blob missing the key keeps its siblings and defaults persist-across-Done to off (the
        // MVP behavior: Done disarms). Tolerant decode — adding the field must not reset saved state.
        let legacy = Data(#"{"mode":"general","textModel":"gemma4:e4b","liveEnabled":true}"#.utf8)
        let decoded = try JSONDecoder().decode(PeeknookSettings.self, from: legacy)
        XCTAssertFalse(decoded.livePersistAcrossDone, "a missing key defaults off")
        XCTAssertTrue(decoded.liveEnabled, "sibling live field is preserved")
        XCTAssertEqual(decoded.textModel, "gemma4:e4b")

        let on = PeeknookSettings(textModel: "gemma4:e4b", liveEnabled: true, livePersistAcrossDone: true)
        let back = try JSONDecoder().decode(PeeknookSettings.self, from: JSONEncoder().encode(on))
        XCTAssertTrue(back.livePersistAcrossDone, "the field round-trips through encode/decode")
    }

    func testSystemAudioSettingDefaultsOffAndRoundTrips() throws {
        // A legacy blob missing the key keeps its siblings and defaults "hear the screen" to off —
        // tolerant decode, adding the field must not reset saved state.
        let legacy = Data(#"{"mode":"general","textModel":"gemma4:e4b","webLookupEnabled":true}"#.utf8)
        let decoded = try JSONDecoder().decode(PeeknookSettings.self, from: legacy)
        XCTAssertFalse(decoded.systemAudioEnabled, "a missing key defaults off")
        XCTAssertTrue(decoded.webLookupEnabled, "the sibling opt-in is preserved")
        XCTAssertEqual(decoded.textModel, "gemma4:e4b")

        let on = PeeknookSettings(textModel: "gemma4:e4b", systemAudioEnabled: true)
        let back = try JSONDecoder().decode(PeeknookSettings.self, from: JSONEncoder().encode(on))
        XCTAssertTrue(back.systemAudioEnabled, "the field round-trips through encode/decode")
    }

    func testSpeechVoiceOptionMenuLabelIncludesQuality() {
        let enhanced = SpeechVoiceOption(identifier: "x", displayName: "Ava", qualityLabel: "Enhanced")
        XCTAssertEqual(enhanced.menuLabel, "Ava · Enhanced")
        XCTAssertEqual(SpeechVoiceOption(identifier: "", displayName: "Automatic").menuLabel, "Automatic")
    }

    @MainActor
    func testPreviewReadingVoiceSpeaksSampleWithChosenVoice() {
        let previewSynth = StubSpeechSynthesizer()
        let answerSynth = StubSpeechSynthesizer()
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(textModel: "x", speakAnswersEnabled: true),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "x")]),
            inference: ScriptedEngine(responsesPerCall: []),
            speechSynthesizer: answerSynth,
            previewSpeechSynthesizer: previewSynth
        )
        orchestrator.previewReadingVoice(voiceIdentifier: "com.apple.voice.en-US.test")
        XCTAssertEqual(previewSynth.lastSpoken, SessionOrchestrator.readingVoicePreviewSample)
        XCTAssertEqual(previewSynth.lastVoiceIdentifier, "com.apple.voice.en-US.test")
        XCTAssertNil(answerSynth.lastSpoken)
    }

    @MainActor
    func testSpeakingLastAnswerStateUpdatesWhenSpeechEnds() async {
        let answerSynth = StubSpeechSynthesizer()
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(textModel: "x", speakAnswersEnabled: true),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "x")]),
            inference: MockInferenceEngine(tokens: ["hello"]),
            speechSynthesizer: answerSynth
        )
        orchestrator.beginCapture()
        _ = await orchestrator.waitForResult("hello")
        XCTAssertTrue(orchestrator.isSpeakingLastAnswer)
        orchestrator.stopSpeaking()
        XCTAssertFalse(orchestrator.isSpeakingLastAnswer)
    }

    @MainActor
    func testSpeakLastAnswerAfterPreviewUsesAnswerTextNotSample() async {
        let previewSynth = StubSpeechSynthesizer()
        let answerSynth = StubSpeechSynthesizer()
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(textModel: "x", speakAnswersEnabled: true),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "x")]),
            inference: MockInferenceEngine(tokens: ["Knight ", "takes ", "e5"]),
            speechSynthesizer: answerSynth,
            previewSpeechSynthesizer: previewSynth
        )

        orchestrator.previewReadingVoice(voiceIdentifier: "com.apple.voice.en-US.test")
        XCTAssertEqual(previewSynth.lastSpoken, SessionOrchestrator.readingVoicePreviewSample)

        orchestrator.beginCapture()
        let phase = await orchestrator.waitForResult("Knight takes e5")
        guard case .result("Knight takes e5") = phase else {
            XCTFail("Expected completed answer, got \(phase)")
            return
        }

        XCTAssertEqual(answerSynth.lastSpoken, "Knight takes e5")
        XCTAssertEqual(previewSynth.lastSpoken, SessionOrchestrator.readingVoicePreviewSample)
        XCTAssertNil(answerSynth.lastVoiceIdentifier)
    }

    func testSpeechRecognitionErrorEquatable() {
        XCTAssertEqual(SpeechRecognitionError.unavailable, .unavailable)
        XCTAssertEqual(SpeechRecognitionError.notAuthorized, .notAuthorized)
        XCTAssertEqual(SpeechRecognitionError.onDeviceUnavailable, .onDeviceUnavailable)
        XCTAssertNotEqual(SpeechRecognitionError.unavailable, .onDeviceUnavailable)
    }

    @MainActor
    func testToggleVoiceInputSurfacesRecognitionIssue() async {
        let recognizer = StubSpeechRecognizer()
        recognizer.startError = .onDeviceUnavailable
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(textModel: "x", voiceInputEnabled: true),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "x")]),
            inference: ScriptedEngine(responsesPerCall: []),
            speechRecognizer: recognizer
        )

        _ = await orchestrator.toggleVoiceInput()

        XCTAssertEqual(orchestrator.voiceInputIssue, .onDeviceUnavailable)
        XCTAssertFalse(orchestrator.isListeningForVoice)
        orchestrator.dismissVoiceInputIssue()
        XCTAssertNil(orchestrator.voiceInputIssue)
    }
}
