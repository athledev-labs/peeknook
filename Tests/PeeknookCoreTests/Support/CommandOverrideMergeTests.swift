// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// The pure (no-SwiftUI) floor for the Settings → Layout apply seam: `CommandLayout.forPlacement(_:
/// applying:)`. These tests are the contract that reorder/hide compose correctly and — critically —
/// that a command shipped in a FUTURE release (no override entry) can never collide with a saved user
/// rank, vanish, or land non-deterministically. They also pin the customizability guardrail that keeps
/// Capture / Done / Cancel / Shutter / Use-this reachable regardless of the persisted blob.
final class CommandOverrideMergeTests: XCTestCase {

    // MARK: No-override == shipped layout (the byte-identical migration anchor)

    func testNoOverrideByteIdenticalAcrossAllPlacements() {
        for placement in CommandPlacement.allCases {
            XCTAssertEqual(
                CommandLayout.screenDefault.forPlacement(placement, applying: []),
                CommandLayout.screenDefault.forPlacement(placement),
                "screenDefault \(placement) drifted under empty overrides"
            )
            XCTAssertEqual(
                CommandLayout.cameraStudy.forPlacement(placement, applying: []),
                CommandLayout.cameraStudy.forPlacement(placement),
                "cameraStudy \(placement) drifted under empty overrides"
            )
        }
    }

    func testUnknownOverrideIdIsInert() {
        let withGhost = CommandLayout.screenDefault.forPlacement(
            .idle, applying: [CommandOverride(id: "idle.ghost", order: 0, hidden: true)]
        )
        XCTAssertEqual(withGhost, CommandLayout.screenDefault.forPlacement(.idle))
    }

    // MARK: Hide drops only customizable commands

    func testHideDropsACustomizableCommand() {
        let bar = CommandLayout.screenDefault
            .forPlacement(.result, applying: [CommandOverride(id: "result.brief", hidden: true)])
            .map(\.id)
        XCTAssertFalse(bar.contains("result.brief"))
        // The rest of the bar is untouched and stays in default order.
        XCTAssertEqual(
            bar,
            ["result.history", "result.export", "result.followUp",
             "result.retake", "result.addImage", "result.speak", "result.done", "result.newChat",
             "result.compositeCapture"]
        )
    }

    func testHidingAProtectedCommandIsANoOp() {
        // Pinned-trailing (Capture, Done, Shutter), and every exit/confirm (Cancel, Use-this) must
        // survive a hostile hidden:true — a bar can never lose its trigger or its exit.
        assertHideIgnored(layout: .screenDefault, placement: .idle, id: "idle.capture")
        assertHideIgnored(layout: .screenDefault, placement: .result, id: "result.done")
        assertHideIgnored(layout: .screenDefault, placement: .active, id: "active.cancel")
        assertHideIgnored(layout: .screenDefault, placement: .active, id: "active.useThis")
        assertHideIgnored(layout: .cameraStudy, placement: .cameraLive, id: "cameraLive.cancel")
        assertHideIgnored(layout: .cameraStudy, placement: .cameraLive, id: "cameraLive.shutter")
    }

    private func assertHideIgnored(
        layout: CommandLayout, placement: CommandPlacement, id: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let bar = layout.forPlacement(placement, applying: [CommandOverride(id: id, hidden: true)]).map(\.id)
        XCTAssertTrue(bar.contains(id), "\(id) was hidden but must be protected", file: file, line: line)
        XCTAssertEqual(bar, layout.forPlacement(placement).map(\.id),
                       "hiding protected \(id) changed the bar", file: file, line: line)
    }

    // MARK: Reorder honors the stored order (two buckets)

    func testReorderHonorsStoredOrder() {
        // Pull Follow up ahead of Brief by giving the two explicit ranks; the un-ranked commands keep
        // default order and append after the ranked pair.
        let bar = CommandLayout.screenDefault.forPlacement(.result, applying: [
            CommandOverride(id: "result.followUp", order: 0),
            CommandOverride(id: "result.brief", order: 1),
        ]).map(\.id)
        XCTAssertEqual(Array(bar.prefix(2)), ["result.followUp", "result.brief"])
        // Everything else (un-ranked) follows in default order, Done still present (pinned, un-ranked).
        XCTAssertEqual(
            Array(bar.dropFirst(2)),
            ["result.history", "result.export", "result.retake", "result.addImage",
             "result.speak", "result.done", "result.newChat", "result.compositeCapture"]
        )
    }

    // MARK: The core requirement — a future command with no entry never collides

    func testNewCommandWithoutEntryAppendsAfterReorderedByDefaultOrder() {
        // A bar of four customizable commands; `p.new` ships in a later release with defaultOrder 2 and
        // therefore NO override entry. The user has already reordered p.c ahead of p.a.
        let layout = CommandLayout(commands: [
            cmd("p.a", order: 0), cmd("p.b", order: 1), cmd("p.new", order: 2), cmd("p.c", order: 3),
        ])
        let result = layout.forPlacement(.idle, applying: [
            CommandOverride(id: "p.c", order: 0),
            CommandOverride(id: "p.a", order: 1),
        ]).map(\.id)
        // Bucket 1 (ranked): c, a. Bucket 2 (un-ranked, by defaultOrder): b(1), new(2).
        // The new command keeps its authored slot among un-reordered commands — never collides/vanishes.
        XCTAssertEqual(result, ["p.c", "p.a", "p.b", "p.new"])
    }

    func testTwoBucketOrderingIsDeterministicForMixedSet() {
        let layout = CommandLayout(commands: [
            cmd("p.a", order: 0), cmd("p.b", order: 1), cmd("p.c", order: 2), cmd("p.d", order: 3),
        ])
        // Rank only b and d; a and c stay un-ranked.
        let result = layout.forPlacement(.idle, applying: [
            CommandOverride(id: "p.d", order: 0),
            CommandOverride(id: "p.b", order: 1),
        ]).map(\.id)
        XCTAssertEqual(result, ["p.d", "p.b", "p.a", "p.c"])  // ranked first by order, then rest by defaultOrder
    }

    // MARK: Customizability truth table

    func testIsCustomizableTruthTable() {
        for command in CommandLayout.cameraStudy.commands {
            let expected = !command.pinnedTrailing
                && command.action != .cancel
                && command.action != .confirmPreview
            XCTAssertEqual(command.isCustomizable, expected, "isCustomizable wrong for \(command.id)")
        }
        // Spot-check the protected set explicitly.
        XCTAssertFalse(descriptor("idle.capture").isCustomizable)     // pinned
        XCTAssertFalse(descriptor("result.done").isCustomizable)      // pinned
        XCTAssertFalse(descriptor("active.cancel").isCustomizable)    // .cancel
        XCTAssertFalse(descriptor("active.useThis").isCustomizable)   // .confirmPreview
        XCTAssertTrue(descriptor("result.brief").isCustomizable)
        XCTAssertTrue(descriptor("result.newChat").isCustomizable)
        XCTAssertTrue(descriptor("idle.model").isCustomizable)        // a dropdown is customizable
    }

    // MARK: Editor ordering keeps hidden commands (so they can be un-hidden)

    func testEditorOrderingKeepsHiddenCommands() {
        let overrides = [CommandOverride(id: "result.brief", hidden: true)]
        XCTAssertFalse(
            CommandLayout.screenDefault.forPlacement(.result, applying: overrides).map(\.id).contains("result.brief"),
            "the bar must drop the hidden command"
        )
        XCTAssertTrue(
            CommandLayout.screenDefault.orderedForEditing(.result, applying: overrides).map(\.id).contains("result.brief"),
            "the editor must keep the hidden command so it can be un-hidden"
        )
    }

    // MARK: cameraStudy honors global overrides on shared groups, keeps its own exit

    func testCameraStudyHonorsGlobalHideOnSharedGroupKeepsCameraExit() {
        let overrides = [
            CommandOverride(id: "result.brief", hidden: true),     // a shared screen command
            CommandOverride(id: "cameraLive.cancel", hidden: true), // hostile: try to kill the exit
        ]
        XCTAssertFalse(
            CommandLayout.cameraStudy.forPlacement(.result, applying: overrides).map(\.id).contains("result.brief"),
            "global hide of a shared command should apply to cameraStudy's result group"
        )
        XCTAssertTrue(
            CommandLayout.cameraStudy.forPlacement(.cameraLive, applying: overrides).map(\.id).contains("cameraLive.cancel"),
            "the live camera exit must survive a hostile hidden:true"
        )
    }

    // MARK: CommandOverride is primitives-only on disk (the reset-bomb guard, enforced not commented)

    func testCommandOverrideSerializesAsFlatPrimitives() throws {
        // Invariant #3: no Command* associated-value enum may reach disk, or an unknown raw value would
        // throw at decode and PeeknookSettings.load's top-level try? would wipe ALL settings.
        let data = try JSONEncoder().encode(CommandOverride(id: "result.brief", order: 3, hidden: true))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        for (key, value) in object {
            XCTAssertTrue(
                value is String || value is NSNumber,
                "CommandOverride.\(key) serialized as \(type(of: value)); only primitives may reach disk"
            )
        }
    }

    func testCommandOverrideArrayRoundTrips() throws {
        let input = [
            CommandOverride(id: "result.followUp", order: 0),
            CommandOverride(id: "result.brief", order: 1, hidden: true),
            CommandOverride(id: "result.speak"),  // hidden-only-absent / inert
        ]
        let decoded = try JSONDecoder().decode([CommandOverride].self, from: JSONEncoder().encode(input))
        XCTAssertEqual(decoded, input)
    }

    // MARK: Helpers

    private func cmd(_ id: String, order: Int, placement: CommandPlacement = .idle) -> CommandDescriptor {
        CommandDescriptor(
            id: id, kind: .button, action: .followUp, titleKey: id, symbol: "circle",
            placement: placement, defaultOrder: order
        )
    }

    private func descriptor(_ id: String) -> CommandDescriptor {
        guard let match = CommandLayout.cameraStudy.commands.first(where: { $0.id == id }) else {
            XCTFail("no descriptor with id \(id)")
            return CommandLayout.cameraStudy.commands[0]
        }
        return match
    }
}
