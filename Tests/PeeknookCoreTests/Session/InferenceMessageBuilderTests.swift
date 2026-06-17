// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// Direct coverage of the pure ``InferenceMessageBuilder``: it folds a composite group into one
/// grounded message, budgets replay group-atomically, keeps a transcript leg image-free, and maps
/// user/assistant follow-ups verbatim. No orchestrator involved — the inputs are passed in.
final class InferenceMessageBuilderTests: XCTestCase {
    private let builder = InferenceMessageBuilder(quickMode: false, sessionBrief: nil)

    private func image(
        _ id: Int,
        group: UUID? = nil,
        ground: Ground = .screen,
        base64: String? = "b64",
        text: String? = "t"
    ) -> ChatTurn {
        ChatTurn(
            id: id,
            kind: .image(CaptureResult(text: text, sourceLabel: "src", screenshotBase64: base64, ground: ground)),
            compositeGroupID: group
        )
    }
    private func assistant(_ id: Int, _ text: String = "a") -> ChatTurn {
        ChatTurn(id: id, kind: .assistant(text))
    }
    private func user(_ id: Int, _ text: String = "q") -> ChatTurn {
        ChatTurn(id: id, kind: .user(text))
    }

    // MARK: - Composite folding + group-atomic replay

    func testCompositeGroupFoldsIntoOneMessageCarryingBothImages() {
        let gid = UUID()
        let convo = [
            image(1, group: gid, ground: .screen, base64: "SCR"),
            image(2, group: gid, ground: .camera, base64: "CAM"),
        ]
        let messages = builder.inferenceMessages(from: convo, policy: .inference)
        let composite = messages.first { $0.imagesBase64.count == 2 }
        XCTAssertNotNil(composite, "the two legs fold into ONE user message")
        XCTAssertEqual(composite?.imagesBase64, ["SCR", "CAM"], "screen first, camera second by id")
        XCTAssertEqual(messages.count, 1, "a folded group emits a single message, not one per leg")
    }

    func testReplayBudgetTreatsAGroupAsOneAtomicUnit() {
        // Two standalone images then a composite group; latestOnly (1 unit) replays only the group,
        // and the group replays whole — never half.
        let gid = UUID()
        let convo = [
            image(1, base64: "OLD1"), assistant(2),
            image(3, group: gid, ground: .screen, base64: "SCR"),
            image(4, group: gid, ground: .camera, base64: "CAM"),
        ]
        let messages = builder.inferenceMessages(from: convo, policy: .inference)
        let withImages = messages.filter { !$0.imagesBase64.isEmpty }
        XCTAssertEqual(withImages.count, 1, "only the latest unit replays images")
        XCTAssertEqual(withImages.first?.imagesBase64, ["SCR", "CAM"], "the whole group rides, not half")
    }

    func testSuggestionsPolicyDropsEveryImagePayload() {
        let convo = [image(1, base64: "SCR"), assistant(2)]
        let messages = builder.inferenceMessages(from: convo, policy: .suggestions)
        XCTAssertTrue(
            messages.allSatisfy(\.imagesBase64.isEmpty),
            "the suggestion pass keeps text grounding but ships no base64"
        )
    }

    // MARK: - Transcript leg carries no image

    func testTranscriptLegInAGroupNeverCarriesAnImagePayload() {
        let gid = UUID()
        let convo = [
            image(1, group: gid, ground: .screen, base64: "SCR"),
            // A system-audio leg resolves to a transcript modality — text only, no base64.
            image(2, group: gid, ground: .systemAudio, base64: "AUDIO", text: "spoken words"),
        ]
        let messages = builder.inferenceMessages(from: convo, policy: .inference)
        let folded = messages.first { $0.role == .user }
        XCTAssertEqual(folded?.imagesBase64, ["SCR"], "only the screen leg contributes an image")
        XCTAssertFalse(
            folded?.imagesBase64.contains("AUDIO") ?? true,
            "the transcript leg rides as text, never as a vision payload"
        )
    }

    // MARK: - Follow-up mapping

    func testUserAndAssistantTurnsMapInOrder() {
        let convo = [
            image(1, base64: "SCR"), assistant(2, "first answer"),
            user(3, "why though"), assistant(4, "second answer"),
        ]
        let messages = builder.inferenceMessages(from: convo, policy: .inference)
        XCTAssertEqual(messages.count, 4, "image + assistant + user + assistant all map through")
        XCTAssertEqual(messages.map(\.role), [.user, .assistant, .user, .assistant])
        XCTAssertEqual(messages[1].text, "first answer", "assistant text passes through verbatim")
        XCTAssertEqual(messages[3].text, "second answer")
        XCTAssertTrue(messages[2].text.contains("why though"), "the typed follow-up is grounded into its message")
    }

    // MARK: - latestTurnLegs

    func testLatestTurnLegsReturnsTheWholeTrailingGroup() {
        let gid = UUID()
        let convo = [
            image(1, base64: "OLD"), assistant(2),
            image(3, group: gid, ground: .screen, base64: "SCR"),
            image(4, group: gid, ground: .camera, base64: "CAM"),
        ]
        let legs = builder.latestTurnLegs(in: convo)
        XCTAssertEqual(legs.map(\.ground), [.screen, .camera], "both legs of the trailing group, in id order")
    }

    func testLatestTurnLegsReturnsASingleStandaloneImage() {
        let convo = [image(1, base64: "OLD"), assistant(2), image(3, ground: .camera, base64: "NEW")]
        let legs = builder.latestTurnLegs(in: convo)
        XCTAssertEqual(legs.map(\.ground), [.camera], "a standalone capture is a one-leg group")
    }

    func testLatestTurnLegsIsEmptyWithNoImages() {
        XCTAssertTrue(builder.latestTurnLegs(in: [user(1), assistant(2)]).isEmpty)
    }
}
