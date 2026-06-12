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
}
