// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// Live Session v1 slice 2: the armed UI shell. A user can arm Live from an answered thread, sees a
/// persistent chip + a never-hideable Stop, and the session disarms on EVERY exit — including
/// nook-collapse. In-thread work (Retake / Add image) must NOT disarm. Live OFF stays byte-identical.
@MainActor
final class LiveArmedUITests: XCTestCase {

    // MARK: Helpers

    private func makeOrchestrator(_ settings: PeeknookSettings = PeeknookSettings(textModel: "x")) -> SessionOrchestrator {
        SessionOrchestrator(
            settings: settings,
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "s")]),
            inference: MockInferenceEngine(tokens: ["a"])
        )
    }

    /// Drive one capture to `.result` so the thread is answered — the only state Live can arm from.
    private func driveToResult(_ o: SessionOrchestrator) async {
        o.beginCapture()
        _ = await o.waitForResult("a")
    }

    private func makeArmed(_ settings: PeeknookSettings = PeeknookSettings(textModel: "x")) async -> SessionOrchestrator {
        let o = makeOrchestrator(settings)
        await driveToResult(o)
        o.armLive()
        XCTAssertTrue(o.isLiveArmed, "precondition: armed from .result")
        return o
    }

    private func sampleCapture() -> CaptureResult {
        CaptureResult(
            text: "x", sourceLabel: "x",
            screenshotBase64: StubCaptureProvider.defaultScreenshotBase64, ground: .screen
        )
    }

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("peeknook-live-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: Arm

    func testArmsFromResultSeedingPolicyFromSettings() async {
        var s = PeeknookSettings(textModel: "x")
        s.liveAutoRespond = true
        s.liveRefreshTriggerRaw = "timer"
        s.liveRateCapSeconds = 8
        let o = await makeArmed(s)
        XCTAssertEqual(o.livePolicy?.refresh, .timer)
        XCTAssertEqual(o.livePolicy?.autoRespond, true)
        XCTAssertEqual(o.livePolicy?.rateCap, 8)
    }

    func testRateCapClampedAtArm() async {
        var s = PeeknookSettings(textModel: "x")
        s.liveRateCapSeconds = 0.1   // a hand-edited sub-second value clamps to >= 1 at arm
        let o = await makeArmed(s)
        XCTAssertEqual(o.livePolicy?.rateCap, 1)
    }

    func testNotArmableOutsideResult() {
        let o = makeOrchestrator()
        o.armLive()   // still in .idle (no capture has happened)
        XCTAssertNil(o.livePolicy, "arm is a no-op outside .result")
        XCTAssertFalse(o.isLiveArmed)
    }

    func testArmIsIdempotent() async {
        let o = await makeArmed()
        let first = o.livePolicy
        o.armLive()
        XCTAssertEqual(o.livePolicy, first, "arming an already-armed session must not reseed")
    }

    // MARK: Disarm matrix — every exit disarms and clears the pending live frame

    func testStopLiveDisarmsAndClearsPending() async {
        let o = await makeArmed()
        o.lifecycle.pendingLiveCapture = sampleCapture()   // simulate a later-slice pending frame
        o.stopLive()
        XCTAssertNil(o.livePolicy)
        XCTAssertNil(o.lastLiveRefreshAt)
        XCTAssertNil(o.lifecycle.pendingLiveCapture, "disarm clears the pending live frame")
    }

    func testFinishChatDisarms() async {
        let o = await makeArmed()
        o.finishChat()
        XCTAssertNil(o.livePolicy, "Done returns to idle and disarms (the MVP rule)")
    }

    func testDismissResultDisarms() async {
        let o = await makeArmed()
        o.dismissResult()
        XCTAssertNil(o.livePolicy)
    }

    func testStartNewChatDisarms() async {
        let o = await makeArmed()
        o.startNewChat()
        XCTAssertNil(o.livePolicy, "New chat (via dismissResult) disarms")
    }

    func testOpenThreadDisarms() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConversationArchiveTestSupport.makeStore(directory: dir)
        let saved = ConversationThread(
            turns: [ChatTurn(id: 1, kind: .user("q")), ChatTurn(id: 2, kind: .assistant("archived"))],
            turnCounter: 2
        )
        _ = await store.save(saved)

        let o = makeOrchestrator(PeeknookSettings(textModel: "x", persistConversation: true))
        o.conversationArchive = store
        await driveToResult(o)
        o.armLive()
        XCTAssertTrue(o.isLiveArmed)

        await o.openThread(id: saved.id)
        XCTAssertNil(o.livePolicy, "switching to another archived thread disarms the old thread's session")
    }

    func testDeleteActiveThreadDisarms() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConversationArchiveTestSupport.makeStore(directory: dir)

        let o = makeOrchestrator(PeeknookSettings(textModel: "x", persistConversation: true))
        o.conversationArchive = store
        await driveToResult(o)
        o.persistConversationNow()                 // mints the active thread id synchronously
        let id = try XCTUnwrap(o.activeThreadID)
        o.armLive()
        XCTAssertTrue(o.isLiveArmed)

        o.deleteThread(id: id)
        XCTAssertNil(o.livePolicy, "deleting the chat on screen disarms")
    }

    func testPurgeAllConversationsDisarms() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let o = makeOrchestrator(PeeknookSettings(textModel: "x", persistConversation: true))
        o.conversationArchive = ConversationArchiveTestSupport.makeStore(directory: dir)
        await driveToResult(o)
        o.armLive()
        XCTAssertTrue(o.isLiveArmed)

        o.purgeAllConversations()   // turning persistence off wipes everything and returns to idle
        XCTAssertNil(o.livePolicy, "purging all conversations disarms")
    }

    // MARK: Anti-graft — in-thread work (Retake / Add image) must NOT disarm

    func testAbortSessionWorkDoesNotDisarm() async {
        let o = await makeArmed()
        o.abortSessionWork()   // exactly what Retake / Add image invoke — Live must survive it
        XCTAssertTrue(o.isLiveArmed, "abortSessionWork aborts in-flight work but is NOT a disarm")
    }

    func testRetakeKeepsLiveArmedThroughTheFullCycle() async {
        let o = await makeArmed()
        o.retake()                       // replaces the chat ('.fresh') over a fresh capture
        _ = await o.waitForResult("a")
        XCTAssertTrue(o.isLiveArmed, "a Retake (incl. its resetConversation) keeps Live armed")
    }

    // MARK: Collapse / switch-away — the host fires stopLiveSession() (the trust graft)

    func testCollapseHookDisarms() async {
        let o = await makeArmed()
        o.stopLiveSession()   // the exact call onCompact / onHide / prepareForSwitchAway make
        XCTAssertNil(o.livePolicy, "collapse is a full disarm — no armed thread lingers while hidden")
    }

    // MARK: Stop is non-hideable; chip + Stop only when armed; byte-identical when off

    func testStopLiveIsNotCustomizableAndSurvivesHostileHide() {
        let stop = CommandLayout.screenDefault.commands.first { $0.id == "result.stopLive" }
        XCTAssertEqual(stop?.action, .stopLive)
        XCTAssertEqual(stop?.isCustomizable, false, "Layout must never hide the only disarm control")
        // A hand-edited hidden override is dropped at the apply seam.
        let bar = CommandLayout.screenDefault
            .forPlacement(.result, applying: [CommandOverride(id: "result.stopLive", hidden: true)])
            .map(\.id)
        XCTAssertTrue(bar.contains("result.stopLive"))
    }

    func testResultBarByteIdenticalWhenLiveOffAndNotArmed() {
        // Opt-in OFF (no .liveSession module) and not armed: the visible result bar equals the
        // pre-Live golden set — neither Go live nor Stop appears.
        let ctx = CommandBarContext(
            isReady: true, hasConversationHistory: true, showingFullConversation: true,
            isLiveArmed: false, enabledModules: [.screenCapture, .speakAnswers, .parallelScreen]
        )
        XCTAssertEqual(
            CommandLayout.screenDefault.visibleCommands(.result, in: ctx).map(\.id),
            ["result.history", "result.export", "result.brief", "result.followUp",
             "result.retake", "result.addImage", "result.speak", "result.done", "result.newChat",
             "result.compositeCapture"]
        )
    }

    func testGoLiveAppearsOnlyWithOptInAndNotArmed() {
        let modules: Set<ModuleID> = [.screenCapture, .speakAnswers, .parallelScreen, .liveSession]
        let ctx = CommandBarContext(isReady: true, isLiveArmed: false, enabledModules: modules)
        let visible = CommandLayout.screenDefault.visibleCommands(.result, in: ctx).map(\.id)
        XCTAssertTrue(visible.contains("result.toggleLive"), "opt-in on, not armed: Go live shows")
        XCTAssertFalse(visible.contains("result.stopLive"), "Stop hidden while not armed")
        XCTAssertEqual(visible.last, "result.toggleLive", "Go live appends after the existing commands")
    }

    func testStopReplacesGoLiveWhenArmed() {
        let modules: Set<ModuleID> = [.screenCapture, .speakAnswers, .parallelScreen, .liveSession]
        let ctx = CommandBarContext(isReady: true, isLiveArmed: true, enabledModules: modules)
        let visible = CommandLayout.screenDefault.visibleCommands(.result, in: ctx).map(\.id)
        XCTAssertTrue(visible.contains("result.stopLive"), "armed: Stop shows")
        XCTAssertFalse(visible.contains("result.toggleLive"), "armed: Go live hidden")
    }

    // MARK: Settings opt-in + module wiring

    func testLiveEnabledOffByDefaultAndFlipsModule() {
        var s = PeeknookSettings()
        XCTAssertFalse(s.liveEnabled, "off by default")
        XCTAssertFalse(Module.isEnabled(.liveSession, in: s, profile: .screenDefault))
        s.liveEnabled = true
        XCTAssertTrue(Module.isEnabled(.liveSession, in: s, profile: .screenDefault))
    }

    func testLiveEnabledTolerantDecode() throws {
        let decoded = try JSONDecoder().decode(
            PeeknookSettings.self,
            from: #"{"textModel":"gemma4:e2b","liveEnabled":true}"#.data(using: .utf8)!
        )
        XCTAssertTrue(decoded.liveEnabled)
        // A legacy blob missing the key defaults to off without resetting siblings.
        let old = try JSONDecoder().decode(
            PeeknookSettings.self,
            from: #"{"textModel":"gemma4:e4b","webLookupEnabled":true}"#.data(using: .utf8)!
        )
        XCTAssertFalse(old.liveEnabled)
        XCTAssertEqual(old.textModel, "gemma4:e4b")
        XCTAssertTrue(old.webLookupEnabled)
    }

    // MARK: Slice 3 — manual refresh-only (stash the latest frame, no inference)

    func testRefreshLiveStashesPendingFrameWithoutInferring() async {
        let o = await makeArmed()
        let turnsBefore = o.conversation.count
        o.refreshLive()
        let got = await o.waitUntil { o.lifecycle.pendingLiveCapture != nil }
        XCTAssertTrue(got, "refresh captures the latest screen into pending context")
        XCTAssertNotNil(o.lastLiveRefreshAt, "refresh stamps the last-refresh time for the chip")
        XCTAssertNotNil(o.lifecycle.pendingLiveCaptureAt)
        XCTAssertEqual(o.conversation.count, turnsBefore, "refresh adds no turn — no inference yet")
        XCTAssertTrue(o.isLiveArmed, "still armed after a refresh")
        if case .result = o.phase {} else { XCTFail("refresh stays in .result, got \(o.phase)") }
    }

    func testRefreshLiveNoOpWhenNotArmed() async {
        let o = makeOrchestrator()
        await driveToResult(o)   // answered, but NOT armed
        o.refreshLive()
        let leaked = await o.waitUntil(timeout: 0.4) { o.lifecycle.pendingLiveCapture != nil }
        XCTAssertFalse(leaked, "refresh is a no-op when not armed")
        XCTAssertNil(o.lastLiveRefreshAt)
    }

    func testStopLiveCancelsRefreshAndClearsPendingFrame() async {
        let o = await makeArmed()
        o.refreshLive()
        _ = await o.waitUntil { o.lifecycle.pendingLiveCapture != nil }
        o.stopLive()
        XCTAssertNil(o.livePolicy)
        XCTAssertNil(o.lifecycle.pendingLiveCapture, "disarm clears the pending live frame")
        XCTAssertNil(o.lastLiveRefreshAt)
    }

    func testRefreshedFrameSurvivesAbortSessionWork() async {
        // The pending live frame and the refresh task are owned by LiveCoordinator, NOT lifecycle — a
        // Retake's abortSessionWork must not sweep them; Live keeps its latest frame across in-thread work.
        let o = await makeArmed()
        o.refreshLive()
        _ = await o.waitUntil { o.lifecycle.pendingLiveCapture != nil }
        o.abortSessionWork()
        XCTAssertNotNil(o.lifecycle.pendingLiveCapture, "abortSessionWork must not drop the pending live frame")
        XCTAssertTrue(o.isLiveArmed)
    }

    func testRefreshFailureEmitsNoticeAndStaysArmed() async {
        let o = SessionOrchestrator(
            settings: PeeknookSettings(textModel: "x"),
            captureRegistry: GroundRegistry([.screen: FailAfterFirstCaptureProvider()]),
            inference: MockInferenceEngine(tokens: ["a"])
        )
        o.beginCapture()
        _ = await o.waitForResult("a")   // first capture succeeds → result
        o.armLive()
        XCTAssertTrue(o.isLiveArmed)

        o.refreshLive()                  // second capture throws
        let noticed = await o.waitUntil { o.lastNotice == .liveRefreshFailed }
        XCTAssertTrue(noticed, "a failed refresh surfaces a transient notice")
        XCTAssertNil(o.lifecycle.pendingLiveCapture, "a failed refresh leaves no pending frame")
        XCTAssertTrue(o.isLiveArmed, "a failed refresh keeps the session armed (no .failed card)")
        if case .result = o.phase {} else { XCTFail("failed refresh stays in .result, got \(o.phase)") }
    }

    func testRefreshCommandVisibleOnlyWhenArmedAndBeforeStop() {
        let modules: Set<ModuleID> = [.screenCapture, .speakAnswers, .parallelScreen, .liveSession]
        let refresh = CommandLayout.screenDefault.commands.first { $0.id == "result.refreshLive" }
        XCTAssertEqual(refresh?.action, .refreshLive)
        XCTAssertEqual(refresh?.requiredModules, [.screenCapture])
        XCTAssertEqual(refresh?.requiredPermissions, [.screenRecording])
        XCTAssertEqual(refresh?.isCustomizable, true, "Refresh is a normal (hideable) action, unlike Stop")

        let notArmed = CommandBarContext(isReady: true, isLiveArmed: false, enabledModules: modules)
        XCTAssertFalse(
            CommandLayout.screenDefault.visibleCommands(.result, in: notArmed).map(\.id).contains("result.refreshLive"),
            "Refresh is hidden while not armed"
        )
        let armed = CommandBarContext(isReady: true, isLiveArmed: true, enabledModules: modules)
        let visible = CommandLayout.screenDefault.visibleCommands(.result, in: armed).map(\.id)
        XCTAssertTrue(visible.contains("result.refreshLive"), "armed: Refresh shows")
        let ri = try? XCTUnwrap(visible.firstIndex(of: "result.refreshLive"))
        let si = try? XCTUnwrap(visible.firstIndex(of: "result.stopLive"))
        XCTAssertLessThan(ri ?? .max, si ?? .min, "Refresh (action) appears before Stop (exit)")
    }

    func testRefreshDisabledUntilScreenRecordingGranted() {
        let refresh = CommandLayout.screenDefault.commands.first { $0.id == "result.refreshLive" }!
        XCTAssertTrue(refresh.isDisabled(in: CommandBarContext(isReady: false, isLiveArmed: true, enabledModules: [.screenCapture])))
        XCTAssertFalse(refresh.isDisabled(in: CommandBarContext(isReady: true, isLiveArmed: true, enabledModules: [.screenCapture])))
    }

    // MARK: Slice 4 — Update & ask + Answer from pending context

    /// Wait for a promotion's full cycle (image turn committed, then runTurn streams the assistant).
    /// `waitForResult` alone is racy here: every Mock answer is "a", so the phase is already `.result("a")`
    /// before the promote runs — gate on the new image count + a trailing assistant instead.
    @discardableResult
    private func waitForPromotedAnswer(_ o: SessionOrchestrator, expectedImages: Int) async -> Bool {
        await o.waitUntil {
            o.conversation.filter(\.isImage).count == expectedImages && o.conversation.last?.isAssistant == true
        }
    }

    /// "Answer now" promotes the already-parked refreshed frame into an answered turn with NO new
    /// capture: an image turn lands, the frame is consumed, the mirror lowers, and Live stays armed.
    func testAnswerNowPromotesPendingFrameWithoutCapturing() async {
        let o = await makeArmed()
        o.refreshLive()
        _ = await o.waitUntil { o.lifecycle.pendingLiveCapture != nil }
        XCTAssertTrue(o.hasPendingLiveFrame, "refresh raises the observable mirror")
        let imagesBefore = o.conversation.filter(\.isImage).count
        o.answerLive()
        let answered = await waitForPromotedAnswer(o, expectedImages: imagesBefore + 1)
        XCTAssertTrue(answered, "the parked frame became an image turn and was answered")
        XCTAssertNil(o.lifecycle.pendingLiveCapture, "the frame is consumed on answer")
        XCTAssertFalse(o.hasPendingLiveFrame, "the mirror lowers with the slot")
        XCTAssertTrue(o.isLiveArmed, "still armed after answering")
        if case .result = o.phase {} else { XCTFail("answer lands back in .result, got \(o.phase)") }
    }

    func testAnswerNowNoOpWhenNoPendingFrame() async {
        let o = await makeArmed()
        let turnsBefore = o.conversation.count
        o.answerLive()
        let changed = await o.waitUntil(timeout: 0.4) { o.conversation.count != turnsBefore }
        XCTAssertFalse(changed, "Answer now with nothing parked is a no-op")
        XCTAssertTrue(o.isLiveArmed)
    }

    /// A double press is safe: the atomic take means only the first promotes; the second finds no frame.
    func testAnswerNowDoublePressPromotesOnce() async {
        let o = await makeArmed()
        o.refreshLive()
        _ = await o.waitUntil { o.hasPendingLiveFrame }
        let imagesBefore = o.conversation.filter(\.isImage).count
        o.answerLive()
        o.answerLive()   // second press: frame already taken
        let answered = await waitForPromotedAnswer(o, expectedImages: imagesBefore + 1)
        XCTAssertTrue(answered, "only one image turn from a double press, and it gets answered")
    }

    /// "Update & ask" grabs a fresh frame AND answers in one press; it never parks the frame.
    func testUpdateAndAskCapturesThenAnswers() async {
        let o = await makeArmed()
        let imagesBefore = o.conversation.filter(\.isImage).count
        o.updateAndAskLive()
        let answered = await waitForPromotedAnswer(o, expectedImages: imagesBefore + 1)
        XCTAssertTrue(answered, "Update & ask grabs a fresh frame as an image turn and answers it")
        XCTAssertNotNil(o.lastLiveRefreshAt, "Update & ask stamps the last-refresh time")
        XCTAssertNil(o.lifecycle.pendingLiveCapture, "Update & ask never parks a frame")
        XCTAssertFalse(o.hasPendingLiveFrame)
        XCTAssertTrue(o.isLiveArmed)
    }

    /// Anti-graft: a Retake after Update & ask keeps Live armed, and the Retake's `.fresh` reset wipes
    /// the prior thread so no update turn grafts onto the replaced chat.
    func testUpdateAndAskThenRetakeKeepsLiveArmedAndNoGraft() async {
        let o = await makeArmed()
        o.updateAndAskLive()
        _ = await waitForPromotedAnswer(o, expectedImages: 2)   // makeArmed's image + the update's image
        o.retake()
        // Retake's `.fresh` reset wipes the thread, then commits a single fresh image + answer.
        let retook = await waitForPromotedAnswer(o, expectedImages: 1)
        XCTAssertTrue(retook, "the Retake produced a clean single-image thread")
        XCTAssertTrue(o.isLiveArmed, "a Retake after Update & ask keeps Live armed (anti-graft)")
    }

    /// Anti-graft, the PARKED-frame path: a Retake REPLACES the thread via `.fresh` reset, which must
    /// drop the parked refresh frame + its mirror — otherwise "Answer now" would graft a stale
    /// pre-Retake frame onto the new thread. Live stays armed (livePolicy is untouched).
    func testRetakeClearsParkedLiveFrameAndMirror() async {
        let o = await makeArmed()
        o.refreshLive()
        _ = await o.waitUntil { o.hasPendingLiveFrame }
        XCTAssertNotNil(o.lifecycle.pendingLiveCapture, "precondition: a frame is parked")
        o.retake()   // synchronously moves to .capturing, so waitForResult can't return on the pre-retake state
        _ = await o.waitForResult("a")
        XCTAssertEqual(o.conversation.filter(\.isImage).count, 1, ".fresh reset produced one fresh image+answer")
        XCTAssertTrue(o.isLiveArmed, "Retake keeps Live armed (livePolicy untouched)")
        XCTAssertNil(o.lifecycle.pendingLiveCapture, "the pre-Retake frame is dropped — no graft onto the replaced thread")
        XCTAssertFalse(o.hasPendingLiveFrame, "the mirror clears with the slot")
        let visible = CommandLayout.screenDefault.visibleCommands(.result, in:
            CommandBarContext(isReady: true, isLiveArmed: o.isLiveArmed, hasPendingLiveFrame: o.hasPendingLiveFrame,
                              enabledModules: [.liveSession, .screenCapture])
        ).map(\.id)
        XCTAssertFalse(visible.contains("result.answerNow"), "no parked frame → Answer now hidden after a Retake")
    }

    /// Update & ask grabs a NEWER frame, so it supersedes any frame a prior Refresh parked — no stale
    /// "Answer now" / "ask when ready" should linger pointing at the older screenshot.
    func testUpdateAndAskSupersedesAParkedFrame() async {
        let o = await makeArmed()
        o.refreshLive()
        _ = await o.waitUntil { o.hasPendingLiveFrame }   // a frame is parked from the Refresh
        o.updateAndAskLive()
        let answered = await waitForPromotedAnswer(o, expectedImages: 2)
        XCTAssertTrue(answered, "Update & ask grabbed a fresh frame and answered it")
        XCTAssertNil(o.lifecycle.pendingLiveCapture, "the parked refresh frame is superseded by the fresher grab")
        XCTAssertFalse(o.hasPendingLiveFrame, "no lingering 'ask when ready' after Update & ask")
        XCTAssertTrue(o.isLiveArmed)
    }

    /// The observable mirror tracks the parked slot in lockstep across refresh, promote, and disarm.
    func testMirrorTracksStashThroughRefreshPromoteDisarm() async {
        let o = await makeArmed()
        XCTAssertFalse(o.hasPendingLiveFrame)
        o.refreshLive(); _ = await o.waitUntil { o.hasPendingLiveFrame }
        XCTAssertNotNil(o.lifecycle.pendingLiveCapture)
        o.answerLive()
        // Wait for the FULL promote (phase back to .result) before the next refresh — a refresh while
        // inferring would no-op and the next wait would hang.
        _ = await waitForPromotedAnswer(o, expectedImages: 2)
        XCTAssertFalse(o.hasPendingLiveFrame); XCTAssertNil(o.lifecycle.pendingLiveCapture)
        o.refreshLive(); _ = await o.waitUntil { o.hasPendingLiveFrame }
        o.stopLive()
        XCTAssertFalse(o.hasPendingLiveFrame, "disarm lowers the mirror")
        XCTAssertNil(o.lifecycle.pendingLiveCapture, "disarm clears the slot — lockstep with the mirror")
    }

    /// Critical context disables both new commands (mirroring Add image) and the orchestrator-level
    /// guard leaves a parked frame UNCONSUMED so the user can Stop / New chat and retry.
    func testAnswerAndUpdateDisabledAtCriticalContext() {
        let blocked = CommandBarContext(
            isReady: true, isContextBlocked: true, isLiveArmed: true,
            hasPendingLiveFrame: true, enabledModules: [.liveSession, .screenCapture]
        )
        let answer = CommandLayout.screenDefault.commands.first { $0.id == "result.answerNow" }!
        let update = CommandLayout.screenDefault.commands.first { $0.id == "result.updateAndAsk" }!
        XCTAssertTrue(answer.isDisabled(in: blocked))
        XCTAssertTrue(update.isDisabled(in: blocked))
        let calm = CommandBarContext(
            isReady: true, isContextBlocked: false, isLiveArmed: true,
            hasPendingLiveFrame: true, enabledModules: [.liveSession, .screenCapture]
        )
        XCTAssertFalse(answer.isDisabled(in: calm))
        XCTAssertFalse(update.isDisabled(in: calm))
    }

    func testAnswerNowAtCriticalContextKeepsFrameParked() async {
        let o = await makeArmed()
        o.refreshLive()
        _ = await o.waitUntil { o.hasPendingLiveFrame }
        o.lastPromptTokens = 1000
        o.contextWindow = 1000   // contextFraction 1.0 → .critical
        XCTAssertTrue(o.isContextBlocked, "precondition: critical context pressure")
        o.answerLive()
        XCTAssertNotNil(o.lifecycle.pendingLiveCapture, "a full-context Answer now leaves the frame parked to retry")
        XCTAssertTrue(o.hasPendingLiveFrame)
        XCTAssertEqual(o.lastNotice, .contextFull, "the user is told the window is full")
    }

    // MARK: Command descriptor gates

    func testAnswerNowDescriptorAndVisibility() {
        let answer = CommandLayout.screenDefault.commands.first { $0.id == "result.answerNow" }!
        XCTAssertEqual(answer.action, .answerLive)
        XCTAssertEqual(answer.visibility, .liveHasPendingFrame)
        XCTAssertEqual(answer.requiredModules, [.liveSession])
        XCTAssertTrue(answer.requiredPermissions.isEmpty, "Answer now spends an already-captured frame — no Screen Recording gate")
        XCTAssertTrue(answer.isCustomizable, "Answer now is a normal, hideable action")
        let modules: Set<ModuleID> = [.liveSession, .screenCapture]
        XCTAssertFalse(
            CommandLayout.screenDefault.visibleCommands(.result, in:
                CommandBarContext(isReady: true, isLiveArmed: true, hasPendingLiveFrame: false, enabledModules: modules)
            ).map(\.id).contains("result.answerNow"),
            "hidden while armed with no parked frame"
        )
        XCTAssertTrue(
            CommandLayout.screenDefault.visibleCommands(.result, in:
                CommandBarContext(isReady: true, isLiveArmed: true, hasPendingLiveFrame: true, enabledModules: modules)
            ).map(\.id).contains("result.answerNow"),
            "shown once a frame is parked"
        )
    }

    func testUpdateAndAskDescriptorAndOrderBeforeStop() {
        let update = CommandLayout.screenDefault.commands.first { $0.id == "result.updateAndAsk" }!
        XCTAssertEqual(update.action, .updateAndAskLive)
        XCTAssertEqual(update.visibility, .liveArmed)
        XCTAssertEqual(update.requiredModules, [.screenCapture])
        XCTAssertEqual(update.requiredPermissions, [.screenRecording], "it re-captures, so it gates on Screen Recording")
        XCTAssertTrue(update.isCustomizable)
        let visible = CommandLayout.screenDefault.visibleCommands(.result, in:
            CommandBarContext(isReady: true, isLiveArmed: true, hasPendingLiveFrame: true,
                              enabledModules: [.liveSession, .screenCapture])
        ).map(\.id)
        let ui = visible.firstIndex(of: "result.updateAndAsk") ?? .max
        let si = visible.firstIndex(of: "result.stopLive") ?? .min
        XCTAssertLessThan(ui, si, "Update & ask appears before Stop (the exit stays last)")
    }

    // MARK: Follow-up consumes the pending frame — folded into ONE grounded message

    private func makeScriptedOrchestrator(_ engine: ScriptedEngine) -> SessionOrchestrator {
        SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e4b"),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "screen")]),
            inference: engine
        )
    }

    func testFollowUpConsumesPendingFrameFoldedIntoOneMessage() async {
        let engine = ScriptedEngine(responsesPerCall: [["a1"], ["a2"]])
        let o = makeScriptedOrchestrator(engine)
        o.beginCapture()
        _ = await o.waitForResult("a1")
        o.armLive()
        o.refreshLive()
        _ = await o.waitUntil { o.hasPendingLiveFrame }
        o.sendFollowUp("what is this?")
        _ = await o.waitForResult("a2")

        let userMsgs = (engine.requests.last?.messages ?? []).filter { $0.role == .user }
        let withImage = userMsgs.filter { !$0.imagesBase64.isEmpty }
        XCTAssertEqual(withImage.count, 1, "exactly one user message carries the promoted frame's image")
        XCTAssertTrue(withImage.first?.text.contains("what is this?") ?? false,
                      "the note folds into the image's grounded message")
        XCTAssertFalse(
            userMsgs.contains { $0.imagesBase64.isEmpty && $0.text.contains("what is this?") },
            "the note is NOT a separate bare user message — no adjacent user/user shape"
        )
        XCTAssertNil(o.lifecycle.pendingLiveCapture, "the follow-up consumed the parked frame")
        XCTAssertFalse(o.hasPendingLiveFrame)
        XCTAssertTrue(o.isLiveArmed)
    }

    func testFollowUpWithoutPendingFrameStaysTextOnly() async {
        let engine = ScriptedEngine(responsesPerCall: [["a1"], ["a2"]])
        let o = makeScriptedOrchestrator(engine)
        o.beginCapture()
        _ = await o.waitForResult("a1")
        o.armLive()   // armed but NO frame parked
        let imagesBefore = o.conversation.filter(\.isImage).count
        o.sendFollowUp("text only please")
        _ = await o.waitForResult("a2")
        XCTAssertEqual(o.conversation.filter(\.isImage).count, imagesBefore,
                       "no parked frame → a normal text-only follow-up adds no image turn")
        let userMsgs = (engine.requests.last?.messages ?? []).filter { $0.role == .user }
        XCTAssertTrue(
            userMsgs.contains { $0.imagesBase64.isEmpty && $0.text.contains("text only please") },
            "the follow-up rode as a bare text user message (capturedNow nil)"
        )
    }

    /// "Update & ask" with composer text folds the note into the fresh frame's single grounded message,
    /// symmetric with "Answer now" — no adjacent user/user shape.
    func testUpdateAndAskFoldsComposerNoteIntoOneMessage() async {
        let engine = ScriptedEngine(responsesPerCall: [["a1"], ["a2"]])
        let o = makeScriptedOrchestrator(engine)
        o.beginCapture()
        _ = await o.waitForResult("a1")
        o.armLive()
        o.updateAndAskLive(note: "explain this")
        _ = await o.waitForResult("a2")
        let userMsgs = (engine.requests.last?.messages ?? []).filter { $0.role == .user }
        let withImage = userMsgs.filter { !$0.imagesBase64.isEmpty }
        XCTAssertEqual(withImage.count, 1, "the fresh frame rides one user message")
        XCTAssertTrue(withImage.first?.text.contains("explain this") ?? false,
                      "Update & ask folds the note into the fresh frame's message")
        XCTAssertFalse(
            userMsgs.contains { $0.imagesBase64.isEmpty && $0.text.contains("explain this") },
            "the note is NOT a separate bare user message"
        )
    }
}

/// A capture provider that succeeds once (so a test can reach `.result`) then fails — exercising the
/// live-refresh failure path (transient notice, stay armed) without a real screen grab.
private struct LiveRefreshTestError: Error {}

private final class FailAfterFirstCaptureProvider: CaptureProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func capture(scope: CaptureScope, quick: Bool, encoding: CaptureEncodingParams) async throws -> CaptureResult {
        lock.lock(); calls += 1; let n = calls; lock.unlock()
        guard n == 1 else { throw LiveRefreshTestError() }
        return CaptureResult(
            text: "s", sourceLabel: "s",
            screenshotBase64: StubCaptureProvider.defaultScreenshotBase64, ground: .screen
        )
    }
}
