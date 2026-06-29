// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

// MARK: - Pure FSM transitions for the `.captioning` phase

final class SessionPhaseMachineCaptionTests: XCTestCase {
    private let context = SessionTransitionContext()

    func testOpenCaptionLegalFromIdleResultFailed() {
        for start in [SessionPhase.idle, .result("a"), .failed(.emptyAnswer)] {
            var machine = SessionPhaseMachine(phase: start)
            XCTAssertEqual(machine.apply(.openCaption, context: context), .applied(.captioning))
        }
    }

    func testOpenCaptionRejectedFromBusyPhases() {
        let preview = CapturePreview(excerpt: "", sourceLabel: "x")
        for start in [SessionPhase.previewing(preview), .cameraLive, .captioning, .inferring, .capturing] {
            var machine = SessionPhaseMachine(phase: start)
            XCTAssertEqual(machine.apply(.openCaption, context: context), .rejected)
        }
    }

    func testCancelCaptionReturnsToIdleFromCaptioning() {
        var machine = SessionPhaseMachine(phase: .captioning)
        XCTAssertEqual(machine.apply(.cancelCaption, context: context), .applied(.idle))
    }

    /// Outside `.captioning` the cancel is a NO-OP, not a reject — the host fires it unconditionally on
    /// every nook-collapse / switch-away, whatever the phase (exactly like `cancelCameraLive`).
    func testCancelCaptionOutsideCaptioningIsNoOp() {
        for start in [SessionPhase.idle, .capturing, .inferring, .cameraLive, .result("a"), .failed(.emptyAnswer)] {
            var machine = SessionPhaseMachine(phase: start)
            XCTAssertEqual(machine.apply(.cancelCaption, context: context), .noOp)
            XCTAssertEqual(machine.phase, start, "cancelCaption must not disturb \(start)")
        }
    }

    func testCaptionFailedSurfacesTheFailure() {
        var machine = SessionPhaseMachine(phase: .captioning)
        XCTAssertEqual(
            machine.apply(.captionFailed(.emptyAnswer), context: context),
            .applied(.failed(.emptyAnswer))
        )
        var idle = SessionPhaseMachine(phase: .idle)
        XCTAssertEqual(idle.apply(.captionFailed(.emptyAnswer), context: context), .rejected)
    }

    /// ⌘⇧P and ⌘⇧C during the caption surface are documented no-ops.
    func testBeginCaptureAndOpenCameraRejectedDuringCaptioning() {
        var machine = SessionPhaseMachine(phase: .captioning)
        XCTAssertEqual(machine.apply(.beginCapture, context: context), .rejected)
        XCTAssertEqual(machine.apply(.openCameraLive, context: context), .rejected)
        XCTAssertEqual(machine.phase, .captioning)
    }

    /// Defense in depth: a caption surface must never be cancel-preserved into a result, nor dropped to
    /// idle through the generic cancel — both are rejected so the orchestrator's `cancel()` top-guard
    /// (full disarm) is the only path.
    func testGenericCancelsRejectedDuringCaptioning() {
        for event in [SessionEvent.cancelPreservingResult(answer: "a"), .cancelToIdle] {
            var machine = SessionPhaseMachine(phase: .captioning)
            XCTAssertEqual(machine.apply(event, context: context), .rejected)
            XCTAssertEqual(machine.phase, .captioning)
        }
    }
}

// MARK: - Orchestrator caption flow

@MainActor
final class SessionOrchestratorCaptionTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "peeknook.tests.caption")!
        defaults.removePersistentDomain(forName: "peeknook.tests.caption")
    }

    /// Build an orchestrator with an injected stub transcriber and (optionally) a translate-configured
    /// active profile. `textModel` defaults local; pass a `:cloud` tag to force a remote-egress route.
    private func makeOrchestrator(
        transcriber: StubStreamingTranscriber,
        engine: ScriptedEngine,
        textModel: String = "gemma4:e4b",
        targetLanguage: String? = "German",
        captionAllowRemote: Bool = false
    ) throws -> SessionOrchestrator {
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: textModel, captionEnabled: true),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "screen")]),
            inference: engine,
            streamingTranscriber: transcriber
        )
        let store = ProfileStore(defaults: defaults)
        orchestrator.profileStore = store
        if let targetLanguage {
            let copy = try XCTUnwrap(store.duplicate(.screenDefault, name: "Captioner"))
            store.setOutputConfig(
                id: copy.id,
                ProfileOutputConfig(targetLanguage: targetLanguage, captionAllowRemote: captionAllowRemote)
            )
            orchestrator.settings.activeProfileID = copy.id
        }
        return orchestrator
    }

    private func stableSegment(_ text: String, _ sequence: Int) -> TranscriptSegment {
        TranscriptSegment(text: text, isStable: true, sequence: sequence)
    }

    // MARK: Preguards (no phase entry, no tap)

    func testArmWithoutTargetLanguageRefusesAndNeverStarts() throws {
        let transcriber = StubStreamingTranscriber()
        let orchestrator = try makeOrchestrator(
            transcriber: transcriber, engine: ScriptedEngine(responsesPerCall: []), targetLanguage: nil
        )

        orchestrator.armCaption()

        XCTAssertEqual(orchestrator.phase, .idle)
        XCTAssertNil(orchestrator.liveCaption)
        XCTAssertNil(orchestrator.livePolicy)
        XCTAssertEqual(orchestrator.lastNotice, .captionNeedsTargetLanguage)
        XCTAssertEqual(transcriber.startCount, 0, "a refused arm must never tap audio")
    }

    func testArmOverRemoteRouteWithoutOptInRefuses() throws {
        let transcriber = StubStreamingTranscriber()
        let orchestrator = try makeOrchestrator(
            transcriber: transcriber, engine: ScriptedEngine(responsesPerCall: []),
            textModel: "gemma4:cloud", captionAllowRemote: false
        )

        orchestrator.armCaption()

        XCTAssertEqual(orchestrator.phase, .idle)
        XCTAssertNil(orchestrator.liveCaption)
        XCTAssertEqual(orchestrator.lastNotice, .captionRemoteBlocked)
        XCTAssertEqual(transcriber.startCount, 0, "captions are local-only by default — the tap never starts")
    }

    func testArmOverRemoteRouteWithOptInProceedsAndIndicatesHost() async throws {
        let transcriber = StubStreamingTranscriber()
        let orchestrator = try makeOrchestrator(
            transcriber: transcriber, engine: ScriptedEngine(responsesPerCall: []),
            textModel: "gemma4:cloud", captionAllowRemote: true
        )

        orchestrator.armCaption()

        XCTAssertEqual(orchestrator.phase, .captioning)
        XCTAssertNotNil(orchestrator.liveCaption?.remoteEgressHost,
                        "an opted-in remote caption lights the distinct sending indicator")
        let started = await orchestrator.waitUntil { transcriber.startCount == 1 }
        XCTAssertTrue(started)
    }

    func testArmIsNoOpWhenCaptionDisabled() throws {
        // The master opt-in gates the orchestrator entry point itself, not just UI reachability.
        let transcriber = StubStreamingTranscriber()
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e4b", captionEnabled: false),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "s")]),
            inference: ScriptedEngine(responsesPerCall: []),
            streamingTranscriber: transcriber
        )
        let store = ProfileStore(defaults: defaults)
        orchestrator.profileStore = store
        let copy = try XCTUnwrap(store.duplicate(.screenDefault, name: "Captioner"))
        store.setOutputConfig(id: copy.id, ProfileOutputConfig(targetLanguage: "German"))
        orchestrator.settings.activeProfileID = copy.id

        orchestrator.armCaption()

        XCTAssertEqual(orchestrator.phase, .idle, "captionEnabled=false makes arm a no-op even with a target language")
        XCTAssertNil(orchestrator.liveCaption)
        XCTAssertEqual(transcriber.startCount, 0)
    }

    // MARK: Happy path

    func testArmEntersCaptioningWithBoundedSurfaceAndStartsTap() async throws {
        let transcriber = StubStreamingTranscriber()
        let orchestrator = try makeOrchestrator(transcriber: transcriber, engine: ScriptedEngine(responsesPerCall: []))

        orchestrator.armCaption()

        XCTAssertEqual(orchestrator.phase, .captioning)
        XCTAssertTrue(orchestrator.isCaptioning)
        XCTAssertNil(orchestrator.liveCaption?.remoteEgressHost, "a local caption shows no remote indicator")
        XCTAssertEqual(orchestrator.liveCaption?.targetLabel, "German")
        // Always bounded: a mandatory auto-disarm deadline is snapshot at arm (the user cannot disable it).
        XCTAssertNotNil(orchestrator.livePolicy?.expiresAt, "captioning is always bounded by a mandatory cap")
        XCTAssertEqual(orchestrator.livePolicy?.refresh, .manual, "the loop only watches the deadline, never auto-captures")
        let started = await orchestrator.waitUntil { transcriber.startCount == 1 }
        XCTAssertTrue(started)
    }

    func testFinalizedSegmentTranslatesIntoCurrentLineAndStaysEphemeral() async throws {
        let transcriber = StubStreamingTranscriber(scripted: [stableSegment("hola", 0)])
        let engine = ScriptedEngine(responsesPerCall: [["Hallo"]])
        let orchestrator = try makeOrchestrator(transcriber: transcriber, engine: engine)

        orchestrator.armCaption()

        let translated = await orchestrator.waitUntil { orchestrator.liveCaption?.currentLine == "Hallo" }
        XCTAssertTrue(translated, "a finalized segment streams its translation into the caption line")
        // Ephemeral + non-committing: nothing reaches the conversation, the request envelope, or usage.
        XCTAssertTrue(orchestrator.conversation.isEmpty, "a caption never appends to the conversation")
        let request = try XCTUnwrap(engine.requests.first)
        XCTAssertTrue(request.messages.last?.text.contains("Translate the captured text into German") ?? false,
                      "the caption routes through the shared translate-directive seam")
        XCTAssertTrue(request.messages.last?.imagesBase64.isEmpty ?? false, "an audio transcript carries no image")
    }

    /// The egress gate runs once at arm and FREEZES the route. A mid-session model change (here a drift to
    /// a remote `:cloud` tag, with no disarm hook firing) must NOT redirect the running tap's translate
    /// pass — otherwise audio-derived text would egress remotely without the opt-in.
    func testRouteFrozenAtArmSoMidSessionModelChangeCannotDriftEgress() async throws {
        let transcriber = StubStreamingTranscriber()
        let engine = ScriptedEngine(responsesPerCall: [["Hallo"]])
        let orchestrator = try makeOrchestrator(transcriber: transcriber, engine: engine, textModel: "gemma4:e4b")
        orchestrator.armCaption()   // gate passes on the LOCAL gemma4:e4b route, which is frozen
        _ = await orchestrator.waitUntil { transcriber.startCount == 1 }

        // Drift the answer model to a remote :cloud tag mid-session (nothing disarms the caption here).
        orchestrator.settings.textModel = "gemma4:cloud"
        transcriber.emit(stableSegment("hola", 0))

        _ = await orchestrator.waitUntil { orchestrator.liveCaption?.currentLine == "Hallo" }
        let request = try XCTUnwrap(engine.requests.first)
        XCTAssertEqual(request.model, "gemma4:e4b",
                       "the translate route is frozen at arm — a mid-session model change must not drift egress")
    }

    /// A still-streaming line superseded by a faster-arriving finalized segment is partial, so it is
    /// DROPPED rather than rolled into the bounded tail as if it were a finished subtitle.
    func testSupersedingAnInFlightTranslationDropsThePartialLine() async throws {
        let transcriber = StubStreamingTranscriber(scripted: [stableSegment("uno", 0)])
        let engine = ScriptedEngine(responsesPerCall: [["par", "tial"], ["done"]], tokenDelayNanoseconds: 60_000_000)
        let orchestrator = try makeOrchestrator(transcriber: transcriber, engine: engine)
        orchestrator.armCaption()
        let partial = await orchestrator.waitUntil {
            orchestrator.liveCaption?.currentLine == "par" && orchestrator.liveCaption?.isTranslating == true
        }
        XCTAssertTrue(partial, "precondition: the first translation is mid-stream")

        transcriber.emit(stableSegment("dos", 1))   // supersede the in-flight translation

        let done = await orchestrator.waitUntil { orchestrator.liveCaption?.currentLine == "done" }
        XCTAssertTrue(done)
        XCTAssertEqual(orchestrator.liveCaption?.recentLines ?? [], [],
                       "a superseded, still-streaming line is dropped, never archived as a finalized subtitle")
    }

    func testInterimSegmentOnlyUpdatesHearingCue() async throws {
        let transcriber = StubStreamingTranscriber()
        let orchestrator = try makeOrchestrator(transcriber: transcriber, engine: ScriptedEngine(responsesPerCall: []))
        orchestrator.armCaption()
        _ = await orchestrator.waitUntil { transcriber.startCount == 1 }

        transcriber.emit(TranscriptSegment(text: "bonjo", isStable: false, sequence: 0))

        let heard = await orchestrator.waitUntil { orchestrator.liveCaption?.hearingPartial == "bonjo" }
        XCTAssertTrue(heard)
        XCTAssertEqual(orchestrator.liveCaption?.currentLine ?? "", "", "an interim hypothesis never finalizes a line")
    }

    func testSecondFinalizedSegmentRollsThePreviousLineIntoTheTail() async throws {
        let transcriber = StubStreamingTranscriber(scripted: [stableSegment("uno", 0)])
        let engine = ScriptedEngine(responsesPerCall: [["eins"], ["zwei"]])
        let orchestrator = try makeOrchestrator(transcriber: transcriber, engine: engine)
        orchestrator.armCaption()
        _ = await orchestrator.waitUntil { orchestrator.liveCaption?.currentLine == "eins" }

        transcriber.emit(stableSegment("dos", 1))

        let rolled = await orchestrator.waitUntil {
            orchestrator.liveCaption?.currentLine == "zwei"
                && orchestrator.liveCaption?.recentLines == ["eins"]
        }
        XCTAssertTrue(rolled, "a new segment commits the finished line into the bounded tail")
    }

    // MARK: On-device unavailable → typed failure card

    func testUnavailableTranscriberFailsAndTearsDown() async throws {
        // The fail-closed default: arming surfaces a recovery card and leaves no armed surface behind.
        let orchestrator = try makeOrchestrator(
            transcriber: StubStreamingTranscriber(startError: SpeechRecognitionError.onDeviceUnavailable),
            engine: ScriptedEngine(responsesPerCall: [])
        )

        orchestrator.armCaption()

        let phase = await orchestrator.waitForFailed()
        guard case .failed = phase else { return XCTFail("Expected failed, got \(phase)") }
        XCTAssertNil(orchestrator.liveCaption, "a failed start tears the surface down")
        XCTAssertNil(orchestrator.livePolicy, "a failed start drops the mandatory-cap policy")
    }

    func testNotAuthorizedMapsToSpeechPermissionCard() async throws {
        let orchestrator = try makeOrchestrator(
            transcriber: StubStreamingTranscriber(startError: SpeechRecognitionError.notAuthorized),
            engine: ScriptedEngine(responsesPerCall: [])
        )

        orchestrator.armCaption()

        let phase = await orchestrator.waitForFailed { failure in
            failure.kind == .permissionRequired(name: CapturePermission.speechRecognition.displayName)
        }
        guard case .failed = phase else { return XCTFail("Expected the speech-permission card, got \(phase)") }
    }

    // MARK: Teardown matrix (disarm on EVERY exit)

    func testStopCaptionDisarmsAndReturnsToIdle() async throws {
        let transcriber = StubStreamingTranscriber()
        let orchestrator = try makeOrchestrator(transcriber: transcriber, engine: ScriptedEngine(responsesPerCall: []))
        orchestrator.armCaption()
        _ = await orchestrator.waitUntil { transcriber.startCount == 1 }

        orchestrator.stopCaption()

        XCTAssertEqual(orchestrator.phase, .idle)
        XCTAssertNil(orchestrator.liveCaption)
        XCTAssertNil(orchestrator.livePolicy)
        XCTAssertEqual(transcriber.stopCount, 1, "Stop tears the tap down exactly once")
    }

    func testDoubleStopIsIdempotent() async throws {
        let transcriber = StubStreamingTranscriber()
        let orchestrator = try makeOrchestrator(transcriber: transcriber, engine: ScriptedEngine(responsesPerCall: []))
        orchestrator.armCaption()
        _ = await orchestrator.waitUntil { transcriber.startCount == 1 }

        orchestrator.stopCaption()
        orchestrator.stopCaption()

        XCTAssertEqual(orchestrator.phase, .idle)
        XCTAssertEqual(transcriber.stopCount, 1, "the second Stop finds nothing to tear down")
    }

    /// The host fires `stopLiveSession()` THEN `stopCaption()` unconditionally on collapse/hide. During
    /// captioning the first nils `liveCaption` while the phase is still `.captioning`; the phase-guarded
    /// `stop()` must still run `.cancelCaption` and reach idle, never strand the phase.
    func testHostCollapseSequenceDuringCaptioningReachesIdle() async throws {
        let transcriber = StubStreamingTranscriber()
        let orchestrator = try makeOrchestrator(transcriber: transcriber, engine: ScriptedEngine(responsesPerCall: []))
        orchestrator.armCaption()
        _ = await orchestrator.waitUntil { transcriber.startCount == 1 }

        orchestrator.stopLiveSession()   // clears the tap + livePolicy; phase still .captioning
        orchestrator.stopCaption()       // phase-guard passes -> .cancelCaption -> idle

        XCTAssertEqual(orchestrator.phase, .idle, "the collapse sequence must reach idle, not strand .captioning")
        XCTAssertNil(orchestrator.liveCaption)
        XCTAssertNil(orchestrator.livePolicy)
    }

    func testCancelDuringCaptioningRoutesThroughFullDisarm() async throws {
        let transcriber = StubStreamingTranscriber()
        let orchestrator = try makeOrchestrator(transcriber: transcriber, engine: ScriptedEngine(responsesPerCall: []))
        orchestrator.armCaption()
        _ = await orchestrator.waitUntil { transcriber.startCount == 1 }

        orchestrator.cancel()

        XCTAssertEqual(orchestrator.phase, .idle)
        XCTAssertNil(orchestrator.liveCaption)
        XCTAssertEqual(transcriber.stopCount, 1)
    }

    func testNewChatDuringCaptioningTearsDownAndReturnsToIdle() async throws {
        let transcriber = StubStreamingTranscriber()
        let orchestrator = try makeOrchestrator(transcriber: transcriber, engine: ScriptedEngine(responsesPerCall: []))
        orchestrator.armCaption()
        _ = await orchestrator.waitUntil { transcriber.startCount == 1 }

        orchestrator.startNewChat()   // routes through dismissResult → stopLiveSession (folds the tap teardown)

        XCTAssertEqual(orchestrator.phase, .idle)
        XCTAssertNil(orchestrator.liveCaption)
        XCTAssertNil(orchestrator.livePolicy)
        XCTAssertGreaterThanOrEqual(transcriber.stopCount, 1)
    }

    /// `stopCaption()` outside `.captioning` is a GENUINE no-op — it must never reach into a Live
    /// session's `livePolicy` (disarming Live is `stopLiveSession()`'s job).
    func testStopCaptionDoesNotDisarmAnArmedLiveSession() async throws {
        let transcriber = StubStreamingTranscriber()
        let engine = ScriptedEngine(responsesPerCall: [["a"]])
        let orchestrator = try makeOrchestrator(transcriber: transcriber, engine: engine)
        orchestrator.beginCapture()
        _ = await orchestrator.waitForResult("a")
        orchestrator.armLive()
        XCTAssertTrue(orchestrator.isLiveArmed)

        orchestrator.stopCaption()

        XCTAssertTrue(orchestrator.isLiveArmed, "stopCaption outside captioning must not disarm Live")
        XCTAssertEqual(orchestrator.phase, .result("a"))
    }

    // MARK: Mutual exclusion + bounds

    func testArmingCaptionDisarmsAnArmedLiveSession() async throws {
        let transcriber = StubStreamingTranscriber()
        let engine = ScriptedEngine(responsesPerCall: [["a"]])
        let orchestrator = try makeOrchestrator(transcriber: transcriber, engine: engine)
        // Get to an answered result, then arm Live.
        orchestrator.beginCapture()
        _ = await orchestrator.waitForResult("a")
        orchestrator.armLive()
        XCTAssertTrue(orchestrator.isLiveArmed)

        orchestrator.armCaption()

        XCTAssertEqual(orchestrator.phase, .captioning)
        XCTAssertTrue(orchestrator.isCaptioning, "a caption supersedes a Live session (shared livePolicy)")
        XCTAssertFalse(orchestrator.hasPendingLiveFrame)
    }

    func testMemoryPressureDoesNotUnloadDuringCaptioning() async throws {
        let transcriber = StubStreamingTranscriber()
        let engine = ScriptedEngine(responsesPerCall: [["a"]])
        engine.residentModels = ["gemma4:e4b"]
        let orchestrator = try makeOrchestrator(transcriber: transcriber, engine: engine)
        // Answer once so the warm gate is honestly warm — otherwise the unload's warm-guard returns
        // first and the test wouldn't exercise the `.captioning` busy-guard at all.
        orchestrator.beginCapture()
        _ = await orchestrator.waitForResult("a")
        orchestrator.armCaption()
        _ = await orchestrator.waitUntil { transcriber.startCount == 1 }
        XCTAssertTrue(orchestrator.modelLikelyWarm, "precondition: the model is warm, so the unload's warm-guard passes")

        orchestrator.handleCriticalMemoryPressure()

        // The busy-guard must keep the surface up — captioning is an active experience, never unloaded.
        let held = await orchestrator.phaseHolding({ $0 == .captioning })
        XCTAssertEqual(held, .captioning)
        XCTAssertNotNil(orchestrator.liveCaption)
        XCTAssertNotEqual(orchestrator.lastNotice, .modelUnloadedUnderMemoryPressure,
                          "captioning must block the memory-pressure unload")
    }

    /// The caption surface reuses the Live timer loop to enforce its mandatory cap: a passed deadline
    /// `.expire`s through the caption fork (`stopCaption()` + `.captionEnded`), not the Live fork.
    func testMandatoryCapExpiryEndsCaptionWithNotice() async throws {
        let transcriber = StubStreamingTranscriber()
        let orchestrator = try makeOrchestrator(transcriber: transcriber, engine: ScriptedEngine(responsesPerCall: []))
        orchestrator.armCaption()
        _ = await orchestrator.waitUntil { transcriber.startCount == 1 }

        // Force the deadline into the past and restart the loop so its first decide() reads `.expire`.
        orchestrator.livePolicy?.expiresAt = Date().addingTimeInterval(-1)
        orchestrator.liveCoordinator.startTimerLoopIfNeeded()

        let ended = await orchestrator.waitUntil {
            orchestrator.phase == .idle && orchestrator.lastNotice == .captionEnded
        }
        XCTAssertTrue(ended, "the mandatory cap disarms a caption with the caption-specific notice")
        XCTAssertNil(orchestrator.liveCaption)
        XCTAssertNil(orchestrator.livePolicy)
    }
}

// MARK: - Caption routing helpers

@MainActor
final class CaptionRoutingTests: XCTestCase {
    func testCaptionRolePrefersLocalTextOnlyModel() {
        var settings = PeeknookSettings(textModel: "gemma4:e4b")
        settings.textOnlyModelTag = "qwen2.5:3b"   // local text-only model configured
        let orchestrator = SessionOrchestrator(
            settings: settings,
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "s")]),
            inference: MockInferenceEngine(tokens: ["a"])
        )
        XCTAssertEqual(orchestrator.captionRole, .textOnly,
                       "a local text-only model is preferred for the text→text caption translation")
    }

    func testCaptionRoleFallsBackToFastVisionWithoutLocalTextOnly() {
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(textModel: "gemma4:e4b"),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "s")]),
            inference: MockInferenceEngine(tokens: ["a"])
        )
        XCTAssertEqual(orchestrator.captionRole, .fastVision,
                       "with no usable local text-only model the caption uses the profile's vision model")
    }
}
