// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// The per-profile prompt template must reach `InferenceRequest.profileTemplate` and fold into the
/// system prompt as its own FENCED section, distinct from the standing instruction — and stay nil for
/// a profile that has none (the zero-behavior-change proof).
@MainActor
final class ProfileTemplateWiringTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "peeknook.tests.profileTemplate")!
        defaults.removePersistentDomain(forName: "peeknook.tests.profileTemplate")
    }

    private func makeOrchestrator(engine: ScriptedEngine) -> (SessionOrchestrator, ProfileStore) {
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e4b"),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "hello")]),
            inference: engine
        )
        let store = ProfileStore(defaults: defaults)
        orchestrator.profileStore = store
        return (orchestrator, store)
    }

    // MARK: - Sanitizer

    func testTemplateSanitizerTrimsCapsAndNilsEmpty() {
        XCTAssertNil(ProfileTemplate.sanitized(nil))
        XCTAssertNil(ProfileTemplate.sanitized("   \n "))
        XCTAssertEqual(ProfileTemplate.sanitized("  format as a table  "), "format as a table")
        XCTAssertEqual(
            ProfileTemplate.sanitized(String(repeating: "x", count: 9_000))?.count,
            ProfileTemplate.maxLength
        )
    }

    // MARK: - System prompt fencing

    func testSystemPromptFoldsTemplateAsFencedSectionBeyondInstruction() {
        let prompt = PromptBuilder.systemPrompt(
            agentAppendix: "You are a kind tutor.",
            profileTemplate: "Always answer in three bullet points.\n## Not a real section"
        )
        XCTAssertTrue(prompt.contains("## Custom agent"), "the instruction still rides as the custom-agent block")
        XCTAssertTrue(prompt.contains("## Profile template"), "the template rides as its own distinct section")
        XCTAssertTrue(prompt.contains("Always answer in three bullet points."))
        // The user's `## heading` must be fenced as content, never elevated to a top-level prompt
        // section: each top-level section is its own `\n\n`-joined component, so the pasted heading
        // must NOT start any component (it lives INSIDE the profile-template component).
        XCTAssertTrue(prompt.contains("## Not a real section"), "pasted text rides verbatim inside the fence")
        let components = prompt.components(separatedBy: "\n\n")
        XCTAssertFalse(
            components.contains { $0.hasPrefix("## Not a real section") },
            "the pasted heading stays fenced inside the template block, never its own top-level section"
        )
    }

    func testSystemPromptUnchangedWhenNoTemplate() {
        let withNil = PromptBuilder.systemPrompt()
        let withEmpty = PromptBuilder.systemPrompt(profileTemplate: "   ")
        XCTAssertEqual(withNil, withEmpty, "an empty/whitespace template is byte-identical to none")
        XCTAssertFalse(withNil.contains("## Profile template"))
    }

    // MARK: - Orchestrator wiring

    func testActiveProfileTemplateNilForBuiltIn() {
        let (orchestrator, _) = makeOrchestrator(engine: ScriptedEngine(responsesPerCall: [["ok"]]))
        XCTAssertNil(orchestrator.activeProfileTemplate, "built-ins carry no template")
    }

    func testRunTurnPassesTemplateForEditedProfileAndNilForBuiltIn() async throws {
        let engine = ScriptedEngine(responsesPerCall: [["ok"], ["ok"]])
        let (orchestrator, store) = makeOrchestrator(engine: engine)

        // Built-in active: no template (byte-identical to pre-template behavior).
        orchestrator.beginCapture()
        _ = await orchestrator.waitForResult("ok")
        XCTAssertNil(engine.requests[0].profileTemplate)

        // Edited user copy active: the sanitized template rides the request.
        let copy = try XCTUnwrap(store.duplicate(.screenDefault, name: "Tabular"))
        store.setPromptTemplate(id: copy.id, "  Answer only as a markdown table.  ")
        orchestrator.settings.activeProfileID = copy.id
        orchestrator.startNewChat()

        orchestrator.beginCapture()
        _ = await orchestrator.waitForResult("ok")
        XCTAssertEqual(
            engine.requests.last?.profileTemplate, "Answer only as a markdown table.",
            "the trimmed template reaches the request"
        )
    }

    // MARK: - Store persistence

    func testSetPromptTemplatePersistsAndClears() throws {
        let store = ProfileStore(defaults: defaults)
        let copy = try XCTUnwrap(store.duplicate(.screenDefault, name: "Mine"))
        store.setPromptTemplate(id: copy.id, "Be concise.")

        let reloaded = ProfileStore(defaults: defaults)
        XCTAssertEqual(reloaded.profile(id: copy.id).promptTemplate, "Be concise.")

        store.setPromptTemplate(id: copy.id, "")
        XCTAssertNil(ProfileStore(defaults: defaults).profile(id: copy.id).promptTemplate, "empty clears it")
    }

    func testEditingOtherFieldsKeepsTemplateIntact() throws {
        let store = ProfileStore(defaults: defaults)
        let copy = try XCTUnwrap(store.duplicate(.screenDefault, name: "Mine"))
        store.setPromptTemplate(id: copy.id, "Stay tabular.")
        // A rename / instruction edit must NOT silently wipe the template (the no-silent-drop guard).
        store.rename(id: copy.id, to: "Renamed")
        store.setInstruction(id: copy.id, "Be kind.")
        let reloaded = ProfileStore(defaults: defaults).profile(id: copy.id)
        XCTAssertEqual(reloaded.promptTemplate, "Stay tabular.")
        XCTAssertEqual(reloaded.displayName, "Renamed")
        XCTAssertEqual(reloaded.instruction, "Be kind.")
    }
}
