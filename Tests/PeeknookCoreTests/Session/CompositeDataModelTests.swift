// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// Composite D12 slice 2: the additive `ChatTurn.compositeGroupID` and the `compositeCaptureEnabled`
/// opt-in. Guards the tolerant-decode / no-reset-bomb invariant and the byte-identical default
/// (a non-composite turn writes no new key, and the module stays off until opted in).
final class CompositeDataModelTests: XCTestCase {
    private func screenLeg(id: Int, group: UUID?) -> ChatTurn {
        ChatTurn(
            id: id,
            kind: .image(CaptureResult(text: "screen", sourceLabel: "screen", screenshotBase64: "SCR", ground: .screen)),
            compositeGroupID: group
        )
    }

    private func cameraLeg(id: Int, group: UUID?) -> ChatTurn {
        ChatTurn(
            id: id,
            kind: .image(CaptureResult(text: nil, sourceLabel: "camera", screenshotBase64: "CAM", ground: .camera)),
            compositeGroupID: group
        )
    }

    // MARK: ChatTurn.compositeGroupID round-trip + tolerance

    func testCompositeGroupRoundTripsForBothLegs() throws {
        let gid = UUID()
        let thread = [screenLeg(id: 1, group: gid), cameraLeg(id: 2, group: gid),
                      ChatTurn(id: 3, kind: .assistant("answer"))]
        let data = try JSONEncoder().encode(thread)
        let back = try JSONDecoder().decode([ChatTurn].self, from: data)
        XCTAssertEqual(back.count, 3)
        XCTAssertEqual(back[0].compositeGroupID, gid)
        XCTAssertEqual(back[1].compositeGroupID, gid)
        XCTAssertNil(back[2].compositeGroupID, "the assistant turn carries no group")
        XCTAssertTrue(back[0].isImage); XCTAssertTrue(back[1].isImage)
    }

    func testNonCompositeTurnOmitsGroupKeyAndDecodesNil() throws {
        // BYTE-IDENTICAL GUARD: a standalone (pre-D12-shaped) image turn writes no compositeGroupID
        // key (nil optional → encode-if-present) and decodes back to nil — no key, no throw.
        let data = try JSONEncoder().encode(screenLeg(id: 1, group: nil))
        XCTAssertFalse(String(data: data, encoding: .utf8)!.contains("compositeGroupID"))
        let back = try JSONDecoder().decode(ChatTurn.self, from: data)
        XCTAssertNil(back.compositeGroupID)
        XCTAssertTrue(back.isImage)
    }

    func testUnknownExtraKeyDoesNotResetTheTurn() throws {
        // RESET-BOMB GUARD: an unknown future key alongside a known turn must not throw — it loads.
        // Built by round-tripping a real value (no hand-written Kind envelope) then splicing a key.
        var dict = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(ChatTurn(id: 7, kind: .assistant("hi"))))
                as? [String: Any]
        )
        dict["someFutureKey"] = true
        let data = try JSONSerialization.data(withJSONObject: dict)
        let turn = try JSONDecoder().decode(ChatTurn.self, from: data)
        XCTAssertEqual(turn.id, 7)
        XCTAssertTrue(turn.isAssistant)
    }

    // MARK: compositeCaptureEnabled setting

    func testCompositeCaptureEnabledDefaultsFalseAndRoundTrips() throws {
        XCTAssertFalse(PeeknookSettings().compositeCaptureEnabled)
        var s = PeeknookSettings(textModel: "gemma4:e4b")
        s.compositeCaptureEnabled = true
        let back = try JSONDecoder().decode(PeeknookSettings.self, from: JSONEncoder().encode(s))
        XCTAssertTrue(back.compositeCaptureEnabled)
        XCTAssertEqual(back.textModel, "gemma4:e4b")
    }

    func testLegacySettingsMissingKeyDecodesFalseWithoutReset() throws {
        let json = """
        {"textModel":"gemma4:e2b","answerBackend":"ollama","webLookupEnabled":true}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PeeknookSettings.self, from: json)
        XCTAssertFalse(decoded.compositeCaptureEnabled)
        XCTAssertEqual(decoded.textModel, "gemma4:e2b")
        XCTAssertTrue(decoded.webLookupEnabled)
    }

    // MARK: Module gate

    func testParallelScreenModuleFollowsTheSetting() {
        var s = PeeknookSettings()
        XCTAssertFalse(Module.isEnabled(.parallelScreen, in: s, profile: .screenDefault))
        s.compositeCaptureEnabled = true
        XCTAssertTrue(Module.isEnabled(.parallelScreen, in: s, profile: .screenDefault))
        // The camera-study literal sees the same global opt-in (it's a global setting, not per-ground).
        XCTAssertTrue(Module.isEnabled(.parallelScreen, in: s, profile: .cameraStudy))
    }
}
