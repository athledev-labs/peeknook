// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// Wires a profile's `outputConfig` to the user-message Task line: the directive rides ONLY the
/// current capture's last image unit, resolves through the same gating profile the module gates use
/// (so a camera turn under a translate screen profile carries none), and never re-translates a
/// replayed screenshot on a follow-up.
@MainActor
final class TranslateDirectiveWiringTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "peeknook.tests.translateWiring")!
        defaults.removePersistentDomain(forName: "peeknook.tests.translateWiring")
    }

    private func makeOrchestrator(_ engine: ScriptedEngine) -> (SessionOrchestrator, ProfileStore) {
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e4b"),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "hola")]),
            inference: engine
        )
        let store = ProfileStore(defaults: defaults)
        orchestrator.profileStore = store
        return (orchestrator, store)
    }

    private func translatorProfileActive(_ orchestrator: SessionOrchestrator, _ store: ProfileStore) throws {
        let copy = try XCTUnwrap(store.duplicate(.screenDefault, name: "Translator"))
        store.setOutputConfig(id: copy.id, ProfileOutputConfig(targetLanguage: "German"))
        orchestrator.settings.activeProfileID = copy.id
    }

    // MARK: - gatingProfile firewall: a camera turn carries no directive

    func testDirectiveResolvesForScreenButNotCameraUnderATranslateScreenProfile() throws {
        let (orchestrator, store) = makeOrchestrator(ScriptedEngine(responsesPerCall: []))
        try translatorProfileActive(orchestrator, store)
        XCTAssertEqual(
            orchestrator.translationDirective(forTurnGround: .screen)?.targetLanguage, "German",
            "the active translate screen profile drives a screen turn"
        )
        XCTAssertNil(
            orchestrator.translationDirective(forTurnGround: .camera),
            "a camera turn resolves through the cameraStudy literal, which carries no output config"
        )
    }

    func testBuiltInActiveCarriesNoDirective() {
        let (orchestrator, _) = makeOrchestrator(ScriptedEngine(responsesPerCall: []))
        XCTAssertNil(
            orchestrator.translationDirective(forTurnGround: .screen),
            "a built-in profile sets no output config, so translate is off by default"
        )
    }

    // MARK: - End-to-end: the capture request carries the translate task

    func testCaptureTurnRequestCarriesTranslateTaskAndDropsDefault() async throws {
        let engine = ScriptedEngine(responsesPerCall: [["Hallo"]])
        let (orchestrator, store) = makeOrchestrator(engine)
        try translatorProfileActive(orchestrator, store)

        orchestrator.beginCapture()
        _ = await orchestrator.waitForResult("Hallo")

        let lastMessage = try XCTUnwrap(engine.requests.first?.messages.last?.text)
        XCTAssertTrue(lastMessage.contains("Translate the captured text into German"))
        XCTAssertFalse(lastMessage.contains("Respond to the screenshot above."), "the directive replaces the default Task")
        XCTAssertFalse(lastMessage.contains("## Answer depth"), "a translate turn drops the depth framing")
    }

    func testFollowUpNeverReTranslatesTheReplayedScreenshot() async throws {
        let engine = ScriptedEngine(responsesPerCall: [["Hallo"], ["weil"]])
        let (orchestrator, store) = makeOrchestrator(engine)
        try translatorProfileActive(orchestrator, store)

        orchestrator.beginCapture()
        _ = await orchestrator.waitForResult("Hallo")
        orchestrator.sendFollowUp("warum?")
        _ = await orchestrator.waitForResult("weil")

        XCTAssertEqual(engine.requests.count, 2)
        XCTAssertFalse(
            engine.requests[1].messages.contains { $0.text.contains("Translate the captured text") },
            "a pure follow-up (capture == nil) carries no directive, so the replayed screenshot is not re-translated"
        )
    }

    // MARK: - Builder: directive rides only the current capture's last image unit

    func testBuilderAppliesDirectiveOnlyToTheLastImageUnit() {
        let builder = InferenceMessageBuilder(quickMode: false, sessionBrief: nil)
        func image(_ id: Int) -> ChatTurn {
            ChatTurn(id: id, kind: .image(CaptureResult(text: "t", sourceLabel: "src", screenshotBase64: "b", ground: .screen)))
        }
        let convo = [image(1), ChatTurn(id: 2, kind: .assistant("a")), image(3)]
        let messages = builder.inferenceMessages(
            from: convo,
            translation: TranslationDirective(targetLanguage: "German")
        )
        let imageMessages = messages.filter { !$0.imagesBase64.isEmpty || $0.text.contains("## Capture") }
        XCTAssertEqual(imageMessages.count, 2)
        XCTAssertFalse(imageMessages[0].text.contains("Translate the captured text"), "an older capture is not re-translated")
        XCTAssertTrue(imageMessages[1].text.contains("Translate the captured text into German"), "only the latest capture translates")
    }
}
