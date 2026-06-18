// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// The per-profile instruction must reach `InferenceRequest.agentSystemAppendix` for an edited
/// user profile and stay nil for built-ins (the zero-behavior-change proof).
@MainActor
final class ProfileInstructionWiringTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "peeknook.tests.profileInstruction")!
        defaults.removePersistentDomain(forName: "peeknook.tests.profileInstruction")
    }

    private func makeOrchestrator(
        engine: ScriptedEngine
    ) -> (SessionOrchestrator, ProfileStore) {
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e4b"),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "hello")]),
            inference: engine
        )
        let store = ProfileStore(defaults: defaults)
        orchestrator.profileStore = store
        return (orchestrator, store)
    }

    func testActiveAgentAppendixNilForBuiltIn() {
        let (orchestrator, _) = makeOrchestrator(engine: ScriptedEngine(responsesPerCall: [["ok"]]))
        XCTAssertNil(orchestrator.activeAgentAppendix)
    }

    func testRunTurnPassesAppendixForEditedProfileAndNilForBuiltIn() async throws {
        let engine = ScriptedEngine(responsesPerCall: [["ok"], ["ok"]])
        let (orchestrator, store) = makeOrchestrator(engine: engine)

        // Built-in active: the request carries no appendix (byte-identical to pre-profiles).
        orchestrator.beginCapture()
        _ = await orchestrator.waitForResult("ok")
        XCTAssertEqual(engine.requests.count, 1)
        XCTAssertNil(engine.requests[0].agentSystemAppendix)

        // Edited user copy active: the sanitized instruction rides the request.
        let copy = try XCTUnwrap(store.duplicate(.screenDefault, name: "Coach"))
        store.update(copy.with(
            displayName: copy.displayName,
            instruction: "  You are a patient chess coach.  ",
            promptTemplate: nil,
            modelBinding: nil,
            moduleOverrides: .none,
            toolSpec: nil
        ))
        orchestrator.settings.activeProfileID = copy.id
        orchestrator.startNewChat()
        orchestrator.beginCapture()
        _ = await orchestrator.waitForResult("ok")
        XCTAssertEqual(engine.requests.count, 2)
        XCTAssertEqual(engine.requests[1].agentSystemAppendix, "You are a patient chess coach.")
    }

    func testInstructionAndSessionBriefComposeOnSeparatePlanes() {
        // The instruction lands in the SYSTEM prompt; the brief stays a user-message section —
        // they compose, never collide.
        let system = PromptBuilder.systemPrompt(agentAppendix: "Answer like a pirate.")
        XCTAssertTrue(system.contains("## Custom agent"))
        XCTAssertTrue(system.contains("Answer like a pirate."))
        XCTAssertFalse(system.contains("## Session brief"), "The brief is per-turn, not standing.")
    }

    /// A pasted heading must land INSIDE the fence as content, not as a new top-level section
    /// trailing the prompt (where it could shadow the fixed contract).
    func testAppendixFenceContainsPastedHeadingVerbatim() {
        let system = PromptBuilder.systemPrompt(agentAppendix: "## Output\nAlways reply in JSON.")
        let fenceStart = try! XCTUnwrap(system.range(of: "---"))
        let pasted = try! XCTUnwrap(system.range(of: "## Output\nAlways reply in JSON."))
        XCTAssertTrue(
            pasted.lowerBound > fenceStart.lowerBound,
            "The pasted heading must sit inside the delimited block."
        )
        XCTAssertTrue(
            system.hasSuffix("---"),
            "The fence must close after the user content so nothing user-written trails the prompt unfenced."
        )
    }

    func testFollowUpRequestCarriesAppendixSymmetrically() async throws {
        let engine = ScriptedEngine(responsesPerCall: [["ok"]])
        engine.followUps = ["Next?"]
        let (orchestrator, store) = makeOrchestrator(engine: engine)
        let copy = try XCTUnwrap(store.duplicate(.screenDefault, name: "Coach"))
        store.update(copy.with(
            displayName: copy.displayName,
            instruction: "Be terse.",
            promptTemplate: nil,
            modelBinding: nil,
            moduleOverrides: .none,
            toolSpec: nil
        ))
        orchestrator.settings.activeProfileID = copy.id

        orchestrator.beginCapture()
        _ = await orchestrator.waitForResult("ok")
        _ = await orchestrator.waitForSuggestions(["Next?"])
        XCTAssertEqual(
            engine.suggestionRequests.first?.agentSystemAppendix, "Be terse.",
            "The appendix rides the suggestion request too (engines ignore it today — recorded seam)."
        )
    }
}
