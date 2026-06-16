// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// Composite D12 slice 3: a composite group's two image legs fold into ONE grounded user message,
/// the replay budget treats the group as a single unit, and context trimming keeps/drops the group
/// atomically. Non-composite behavior stays byte-identical.
@MainActor
final class CompositeFoldingTests: XCTestCase {
    // MARK: - Folding through the real request path

    private func makeOrchestrator(_ engine: ScriptedEngine) -> SessionOrchestrator {
        SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e4b"),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "screen")]),
            inference: engine
        )
    }

    private func appendCompositeGroup(_ o: SessionOrchestrator) {
        let gid = UUID()
        o.turnCounter += 1
        o.conversation.append(ChatTurn(
            id: o.turnCounter,
            kind: .image(CaptureResult(text: "screen text", sourceLabel: "screen", screenshotBase64: "SCRb64", ground: .screen)),
            compositeGroupID: gid
        ))
        o.turnCounter += 1
        o.conversation.append(ChatTurn(
            id: o.turnCounter,
            kind: .image(CaptureResult(text: nil, sourceLabel: "camera", screenshotBase64: "CAMb64", ground: .camera)),
            compositeGroupID: gid
        ))
    }

    func testCompositeGroupFoldsIntoOneMessageWithBothImages() async {
        let engine = ScriptedEngine(responsesPerCall: [["a1"], ["a2"]])
        let o = makeOrchestrator(engine) // inferenceImageReplay default == latestOnly (1 unit)
        o.beginCapture()
        _ = await o.waitForResult("a1")
        appendCompositeGroup(o) // now the latest image unit is the composite group
        o.sendFollowUp("compare these")
        _ = await o.waitForResult("a2")

        let msgs = engine.requests.last?.messages ?? []
        let composite = msgs.first { $0.imagesBase64.count == 2 }
        XCTAssertNotNil(composite, "the two composite legs fold into ONE user message carrying both images")
        XCTAssertEqual(composite?.imagesBase64, ["SCRb64", "CAMb64"], "screen first, camera second")
        XCTAssertTrue(composite?.text.contains("SCREENSHOT") ?? false, "the screenshot leg is named")
        XCTAssertTrue(composite?.text.contains("CAMERA PHOTO") ?? false, "the camera leg is named")
        // Group-atomic replay: under latestOnly only the latest unit (the composite) carries images;
        // the older standalone capture is text-only.
        XCTAssertEqual(
            msgs.filter { !$0.imagesBase64.isEmpty }.count, 1,
            "only the latest unit replays images, and a composite counts as one unit"
        )
    }

    func testFollowUpAfterCompositeStaysVisionAndReplaysWholeGroup() async {
        // A pure follow-up after a composite (no opt-in) resolves the vision model and replays the
        // composite's BOTH images — proving the role router and folding compose (capture == nil but
        // the latest unit is a composite, so two images ride, never half).
        let engine = ScriptedEngine(responsesPerCall: [["a1"], ["a2"]])
        let o = makeOrchestrator(engine)
        o.beginCapture()
        _ = await o.waitForResult("a1")
        appendCompositeGroup(o)
        o.sendFollowUp("why?")
        _ = await o.waitForResult("a2")
        let msgs = engine.requests.last?.messages ?? []
        XCTAssertEqual(engine.requests.last?.model, "gemma4:e4b", "vision model, not a routed text model")
        XCTAssertEqual(msgs.first { $0.imagesBase64.count == 2 }?.imagesBase64, ["SCRb64", "CAMb64"])
    }

    func testThreeGroundGroupFoldsIntoOneMessageNamingEachLeg() async {
        // The combination engine generalizes past screen+camera: a three-ground group (screen +
        // camera + imported file) folds into ONE user message carrying all three images, in id order,
        // each named by its ground, and still counts as a SINGLE replay unit.
        let engine = ScriptedEngine(responsesPerCall: [["a1"], ["a2"]])
        let o = makeOrchestrator(engine)
        o.beginCapture()
        _ = await o.waitForResult("a1")

        let gid = UUID()
        let legs: [(String?, String, String, Ground)] = [
            ("screen text", "screen", "SCRb64", .screen),
            (nil, "camera", "CAMb64", .camera),
            (nil, "file", "FILEb64", .file),
        ]
        for (text, label, base64, ground) in legs {
            o.turnCounter += 1
            o.conversation.append(ChatTurn(
                id: o.turnCounter,
                kind: .image(CaptureResult(text: text, sourceLabel: label, screenshotBase64: base64, ground: ground)),
                compositeGroupID: gid
            ))
        }
        o.sendFollowUp("compare all three")
        _ = await o.waitForResult("a2")

        let msgs = engine.requests.last?.messages ?? []
        let group = msgs.first { $0.imagesBase64.count == 3 }
        XCTAssertNotNil(group, "three legs fold into ONE user message carrying three images")
        XCTAssertEqual(group?.imagesBase64, ["SCRb64", "CAMb64", "FILEb64"], "legs ride in id order")
        XCTAssertTrue(group?.text.contains("3 views, one question") ?? false, "the block counts all three views")
        XCTAssertTrue(group?.text.contains("SCREENSHOT") ?? false, "the screenshot leg is named")
        XCTAssertTrue(group?.text.contains("CAMERA PHOTO") ?? false, "the camera leg is named")
        XCTAssertTrue(group?.text.contains("imported FILE") ?? false, "the imported-file leg is named")
        XCTAssertEqual(
            msgs.filter { !$0.imagesBase64.isEmpty }.count, 1,
            "an N-ground group still counts as ONE replay unit"
        )
    }

    // MARK: - Group-atomic context trim (pure)

    private func image(_ id: Int, group: UUID? = nil, ground: Ground = .screen) -> ChatTurn {
        ChatTurn(
            id: id,
            kind: .image(CaptureResult(text: "t", sourceLabel: "s", screenshotBase64: "b", ground: ground)),
            compositeGroupID: group
        )
    }
    private func assistant(_ id: Int) -> ChatTurn { ChatTurn(id: id, kind: .assistant("a")) }
    private func user(_ id: Int) -> ChatTurn { ChatTurn(id: id, kind: .user("q")) }

    func testCriticalPressureKeepsCompositeGroupAtomically() {
        let gid = UUID()
        let convo = [
            image(1), assistant(2),
            image(3, group: gid, ground: .screen), image(4, group: gid, ground: .camera),
            assistant(5), user(6),
        ]
        let trimmed = ContextBudgetPolicy.trimmedConversation(convo, pressure: .critical)
        XCTAssertEqual(
            trimmed.filter(\.isImage).map(\.id), [3, 4],
            "both composite legs survive together — never a half group while the prompt asserts two images"
        )
        XCTAssertFalse(trimmed.contains { $0.id == 1 }, "the older standalone image is dropped")
    }

    func testCriticalPressureNonCompositeKeepsSingleLatestImage() {
        let convo = [image(1), assistant(2), image(3), assistant(4), user(5)]
        let trimmed = ContextBudgetPolicy.trimmedConversation(convo, pressure: .critical)
        XCTAssertEqual(trimmed.filter(\.isImage).map(\.id), [3], "byte-identical: only the latest image kept")
    }

    func testNormalPressureIsUntrimmed() {
        let gid = UUID()
        let convo = [image(1, group: gid), image(2, group: gid), assistant(3), user(4), assistant(5)]
        XCTAssertEqual(ContextBudgetPolicy.trimmedConversation(convo, pressure: .normal).count, convo.count)
    }
}
