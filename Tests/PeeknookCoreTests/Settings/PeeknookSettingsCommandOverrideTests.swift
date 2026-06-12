// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// Persistence + controller discipline for the scope-keyed command-override map. Covers the
/// tolerant-decode guarantees (invariant #3: a missing or stale key never resets sibling settings),
/// and the `PeekSettingsController` mutators (sanitize protected ids, dense-rank reorder, per-placement
/// isolation, reset).
final class PeeknookSettingsCommandOverrideTests: XCTestCase {

    // MARK: Tolerant decode

    func testRoundTripsAScopeKeyedMap() throws {
        var settings = PeeknookSettings.default
        settings.commandOverrides = ["global": [
            CommandOverride(id: "result.brief", order: 0, hidden: true),
            CommandOverride(id: "result.followUp", order: 1),
        ]]
        let decoded = try JSONDecoder().decode(PeeknookSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.commandOverrides, settings.commandOverrides)
        XCTAssertEqual(decoded.commandOverrides(forScope: PeeknookSettings.globalCommandScope).count, 2)
    }

    func testMissingKeyDecodesToEmptyAndKeepsEverySiblingField() throws {
        // Simulate an OLD saved blob written before this field existed: encode, strip the key, decode.
        var settings = PeeknookSettings.default
        settings.textModel = "sentinel-model:99"
        settings.quickMode = true
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any]
        )
        object.removeValue(forKey: "commandOverrides")
        let stripped = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(PeeknookSettings.self, from: stripped)
        XCTAssertEqual(decoded.commandOverrides, [:], "missing key must default, not throw")
        XCTAssertEqual(decoded.textModel, "sentinel-model:99", "siblings must survive the missing key")
        XCTAssertTrue(decoded.quickMode)
    }

    func testStaleCommandIdDecodesWithoutThrowAndAppliesInert() throws {
        var settings = PeeknookSettings.default
        settings.commandOverrides = ["global": [CommandOverride(id: "idle.removedInFuture", order: 0, hidden: true)]]
        let decoded = try JSONDecoder().decode(PeeknookSettings.self, from: JSONEncoder().encode(settings))
        // Decodes fine (primitives only) and is a no-op at apply time — never a reset, never a perturbation.
        XCTAssertEqual(
            CommandLayout.screenDefault.forPlacement(.idle, applying: decoded.commandOverrides(forScope: "global")),
            CommandLayout.screenDefault.forPlacement(.idle)
        )
    }

    func testAccessorDefaultsToGlobalScope() {
        var settings = PeeknookSettings.default
        settings.commandOverrides = ["global": [CommandOverride(id: "result.speak", hidden: true)]]
        XCTAssertEqual(settings.commandOverrides().map(\.id), ["result.speak"])
        XCTAssertEqual(settings.commandOverrides(forScope: "nonexistent"), [])
    }

    // MARK: Controller — hide

    @MainActor
    func testSetCommandHiddenPersistsForCustomizableAndReloads() {
        let stack = makeStack()
        stack.settings.setCommandHidden("result.brief", in: .result, hidden: true)

        let reloaded = PeeknookSettings.load(from: defaults)
        XCTAssertTrue(
            reloaded.commandOverrides(forScope: "global").contains { $0.id == "result.brief" && $0.hidden }
        )
        XCTAssertFalse(
            CommandLayout.screenDefault
                .forPlacement(.result, applying: stack.orchestrator.resolvedCommandOverrides(for: .result))
                .map(\.id).contains("result.brief")
        )
    }

    @MainActor
    func testSetCommandHiddenOnProtectedCommandIsDroppedBeforePersist() {
        let stack = makeStack()
        stack.settings.setCommandHidden("active.cancel", in: .active, hidden: true)
        stack.settings.setCommandHidden("idle.capture", in: .idle, hidden: true)
        XCTAssertTrue(
            stack.orchestrator.settings.commandOverrides(forScope: "global").isEmpty,
            "a protected command must never produce a persisted override"
        )
    }

    @MainActor
    func testUnhidingBackToDefaultClearsTheEntry() {
        let stack = makeStack()
        stack.settings.setCommandHidden("result.speak", in: .result, hidden: true)
        XCTAssertFalse(stack.orchestrator.settings.commandOverrides(forScope: "global").isEmpty)
        stack.settings.setCommandHidden("result.speak", in: .result, hidden: false)
        XCTAssertTrue(
            stack.orchestrator.settings.commandOverrides(forScope: "global").isEmpty,
            "un-hiding a command with no other delta should drop its entry (stay sparse)"
        )
    }

    // MARK: Controller — reorder

    @MainActor
    func testMoveCommandSwapsAdjacentCustomizableAndPersistsDenseRanks() {
        let stack = makeStack()
        // Idle customizable order: resume, brief, model, depth, scope (capture is pinned). Move scope up.
        stack.settings.moveCommand("idle.scope", in: .idle, by: -1)

        let resolved = stack.orchestrator.resolvedCommandOverrides(for: .idle)
        // The reorder ranks every customizable command (including the opt-in composite), so they form
        // bucket 1; pinned Capture stays in bucket 2 and appends last.
        XCTAssertEqual(
            CommandLayout.screenDefault.forPlacement(.idle, applying: resolved).map(\.id),
            ["idle.resume", "idle.brief", "idle.model", "idle.scope", "idle.depth",
             "idle.importFile", "idle.compositeCapture", "idle.capture"]
        )
        // Pinned, non-customizable Capture never acquired an entry.
        XCTAssertFalse(resolved.contains { $0.id == "idle.capture" })
    }

    @MainActor
    func testMoveAtTheEndsIsANoOp() {
        let stack = makeStack()
        stack.settings.moveCommand("idle.resume", in: .idle, by: -1)   // first up
        stack.settings.moveCommand("result.refreshLive", in: .result, by: 1) // last customizable down
        XCTAssertTrue(
            stack.orchestrator.settings.commandOverrides(forScope: "global").isEmpty,
            "moving past an end must not write anything"
        )
    }

    @MainActor
    func testReorderLeavesOtherBarsDeltasUntouched() {
        let stack = makeStack()
        stack.settings.setCommandHidden("result.brief", in: .result, hidden: true)
        stack.settings.moveCommand("idle.scope", in: .idle, by: -1)
        // The result-bar hide survives an idle reorder.
        XCTAssertTrue(
            stack.orchestrator.settings.commandOverrides(forScope: "global")
                .contains { $0.id == "result.brief" && $0.hidden }
        )
        XCTAssertEqual(
            CommandLayout.screenDefault.forPlacement(.idle, applying: stack.orchestrator.resolvedCommandOverrides(for: .idle)).map(\.id),
            ["idle.resume", "idle.brief", "idle.model", "idle.scope", "idle.depth",
             "idle.importFile", "idle.compositeCapture", "idle.capture"]
        )
    }

    // MARK: Controller — reset

    @MainActor
    func testResetClearsAllOverridesAndReturnsToShippedLayout() {
        let stack = makeStack()
        stack.settings.setCommandHidden("result.brief", in: .result, hidden: true)
        stack.settings.moveCommand("idle.scope", in: .idle, by: -1)
        XCTAssertFalse(stack.orchestrator.settings.commandOverrides(forScope: "global").isEmpty)

        stack.settings.resetCommandLayout()
        XCTAssertTrue(stack.orchestrator.settings.commandOverrides(forScope: "global").isEmpty)
        XCTAssertNil(stack.orchestrator.settings.commandOverrides["global"])
        for placement in CommandPlacement.allCases {
            XCTAssertEqual(
                CommandLayout.screenDefault.forPlacement(placement, applying: stack.orchestrator.resolvedCommandOverrides(for: placement)),
                CommandLayout.screenDefault.forPlacement(placement),
                "reset must restore the shipped \(placement) bar"
            )
        }
    }

    // MARK: Fixtures

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "peeknook.tests.commandOverrides")!
        defaults.removePersistentDomain(forName: "peeknook.tests.commandOverrides")
    }

    @MainActor
    private func makeStack() -> PeeknookServices.Stack {
        PeeknookServices.makeStack(settings: .default, defaults: defaults)
    }
}
