// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// Structural-fidelity guard for the Phase 1.5 command registry.
///
/// `swift test` has no SwiftUI render coverage, so these tests are the *Layer-A floor* for the bar
/// refactor (H1): because ``CommandLayout/screenDefault`` is pure data, a dropped pill, a flipped
/// order, a lost gate, or a mismatched test identifier is caught here — at the data layer — before
/// `PeekCommandBar` ever renders it. Render fidelity (right bar per phase, `.disabled` state) is the
/// job of XCUITest; nothing here is "snapshot-tested".
final class CommandLayoutTests: XCTestCase {
    private let layout = CommandLayout.screenDefault

    // MARK: Migration anchor — exact per-placement order (reproduces today's three surfaces)

    func testIdleBarReproducesTodaysOrder() {
        // `idle.compositeCapture` is gated on `.parallelScreen` (opt-in), so the renderer hides it by
        // default; it still appears in the unfiltered layout, ordered last in the scroll.
        XCTAssertEqual(
            layout.forPlacement(.idle).map(\.id),
            ["idle.resume", "idle.brief", "idle.model", "idle.depth", "idle.scope",
             "idle.importFile", "idle.capture", "idle.compositeCapture"]
        )
    }

    func testActiveControlsReproduceTodaysOrder() {
        XCTAssertEqual(layout.forPlacement(.active).map(\.id), ["active.useThis", "active.cancel"])
    }

    func testResultBarReproducesTodaysOrder() {
        XCTAssertEqual(
            layout.forPlacement(.result).map(\.id),
            ["result.history", "result.export", "result.brief", "result.followUp",
             "result.retake", "result.addImage", "result.speak", "result.done", "result.newChat",
             "result.compositeCapture", "result.toggleLive", "result.refreshLive", "result.stopLive"]
        )
    }

    func testNoCameraLiveInScreenDefault() {
        // camera.study lands with the camera PR — it must not appear in the screen layout yet.
        XCTAssertTrue(layout.forPlacement(.cameraLive).isEmpty)
    }

    // MARK: Override seam preserves the anchor — no override must equal the shipped bars

    func testEmptyOverridesReproduceShippedBarsByteIdentical() {
        for placement in CommandPlacement.allCases {
            XCTAssertEqual(
                layout.forPlacement(placement, applying: []),
                layout.forPlacement(placement),
                "\(placement) is not byte-identical under empty overrides"
            )
        }
    }

    func testUnknownOverrideIdLeavesEveryBarIdentical() {
        let ghost = [CommandOverride(id: "idle.ghost", order: 0, hidden: true)]
        for placement in CommandPlacement.allCases {
            XCTAssertEqual(
                layout.forPlacement(placement, applying: ghost),
                layout.forPlacement(placement),
                "an unknown override id perturbed \(placement)"
            )
        }
    }

    func testRetakeAndAddImageCarryCaptureGates() {
        XCTAssertEqual(descriptor("result.retake").requiredModules, [.screenCapture])
        XCTAssertEqual(descriptor("result.retake").requiredPermissions, [.screenRecording])
        XCTAssertEqual(descriptor("result.addImage").requiredModules, [.screenCapture])
        XCTAssertEqual(descriptor("result.addImage").requiredPermissions, [.screenRecording])
        XCTAssertEqual(descriptor("result.addImage").hotkey, .settingsSlot(.capture))
    }

    func testRetakeAndAddImageKeepResultBarTestIdentifiers() {
        XCTAssertEqual(descriptor("result.retake").accessibilityIdentifier, "peeknook.retake")
        XCTAssertEqual(descriptor("result.addImage").accessibilityIdentifier, "peeknook.addImage")
    }

    // MARK: Trailing-pin contract (uniform leading-scroll / trailing-pin split)

    func testExactlyOnePinnedTrailingPerScrollingBar() {
        XCTAssertEqual(layout.forPlacement(.idle).filter(\.pinnedTrailing).map(\.id), ["idle.capture"])
        XCTAssertEqual(layout.forPlacement(.result).filter(\.pinnedTrailing).map(\.id), ["result.done"])
        XCTAssertTrue(layout.forPlacement(.active).allSatisfy { !$0.pinnedTrailing })
    }

    // MARK: Accessibility identifiers — the four migrated commands keep the ids XCUITest queries

    func testMigratedCommandsKeepExistingTestIdentifiers() {
        // These literals mirror PeekTestID (PeeknookUI), which the XCUITest suite queries; the derived
        // id must equal them or the existing UI tests silently break (invisible to `swift test`).
        XCTAssertEqual(descriptor("idle.capture").accessibilityIdentifier, "peeknook.capture")
        XCTAssertEqual(descriptor("idle.brief").accessibilityIdentifier, "peeknook.brief")
        XCTAssertEqual(descriptor("result.brief").accessibilityIdentifier, "peeknook.brief")
        XCTAssertEqual(descriptor("result.done").accessibilityIdentifier, "peeknook.done")
        XCTAssertEqual(descriptor("result.newChat").accessibilityIdentifier, "peeknook.newChat")
    }

    func testDropdownIdentifiersFallBackToId() {
        // Dropdowns carry no action, so their identifier keys off the stable id.
        XCTAssertEqual(descriptor("idle.model").accessibilityIdentifier, "peeknook.idle.model")
    }

    // MARK: Capability gating maps onto the Phase 1 module / permission enums

    func testCaptureGatesOnScreenCaptureAndScreenRecording() {
        let capture = descriptor("idle.capture")
        XCTAssertEqual(capture.requiredModules, [.screenCapture])
        XCTAssertEqual(capture.requiredPermissions, [.screenRecording])
    }

    func testSpeakGatesOnSpeakAnswersModule() {
        XCTAssertEqual(descriptor("result.speak").requiredModules, [.speakAnswers])
    }

    func testTransientVisibilityGates() {
        XCTAssertEqual(descriptor("idle.resume").visibility, .hasResumePreview)
        XCTAssertEqual(descriptor("active.useThis").visibility, .previewing)
        XCTAssertEqual(descriptor("result.history").visibility, .hasConversationHistory)
        XCTAssertEqual(descriptor("result.export").visibility, .showingFullConversation)
        XCTAssertEqual(descriptor("idle.capture").visibility, .always)
    }

    // MARK: Kind / action invariants

    func testButtonsCarryAnActionAndDropdownsDoNot() {
        for command in layout.commands {
            switch command.kind {
            case .button:
                XCTAssertNotNil(command.action, "\(command.id) is a button but has no action")
            case .valueDropdown:
                XCTAssertNil(command.action, "\(command.id) is a dropdown but carries an action")
            }
        }
    }

    func testIdleDropdownsBindTheThreeShippedDimensions() {
        let dimensions = layout.forPlacement(.idle).compactMap { command -> PreflightDimension? in
            if case let .valueDropdown(dimension) = command.kind { return dimension }
            return nil
        }
        // Exactly model · depth · scope, in that order — imageReplay is reserved, not shipped in the bar.
        XCTAssertEqual(dimensions, [.model, .depth, .scope])
    }

    func testIdsAreUniqueWithinEachPlacement() {
        for placement in CommandPlacement.allCases {
            let ids = layout.forPlacement(placement).map(\.id)
            XCTAssertEqual(ids.count, Set(ids).count, "duplicate id within \(placement)")
        }
    }

    // MARK: Toggled appearance (state-dependent face) is data, not a closure

    func testToggleCommandsCarryAnAlternateFace() {
        XCTAssertEqual(descriptor("idle.brief").alternateFace, CommandFace(symbol: "text.alignleft.fill"))
        XCTAssertEqual(descriptor("result.brief").alternateFace, CommandFace(symbol: "text.alignleft.fill"))
        XCTAssertEqual(
            descriptor("result.speak").alternateFace,
            CommandFace(titleKey: "Stop", symbol: "stop.fill", helpKey: "Stop reading the answer aloud")
        )
        XCTAssertEqual(
            descriptor("result.history").alternateFace,
            CommandFace(helpKey: "Show only the latest answer")
        )
        // A plain command has no alternate face.
        XCTAssertNil(descriptor("result.done").alternateFace)
    }

    // MARK: Hotkey bindings reference real settings slots

    func testHotkeyBindings() {
        XCTAssertEqual(descriptor("idle.capture").hotkey, .settingsSlot(.capture))
        XCTAssertEqual(descriptor("idle.brief").hotkey, .settingsSlot(.brief))
        XCTAssertEqual(descriptor("result.brief").hotkey, .settingsSlot(.brief))
        XCTAssertEqual(descriptor("result.done").hotkey, .none)
    }

    // MARK: Codable round-trip (proves auto-synth survives the CommandKind associated value)

    func testCodableRoundTripPreservesLayout() throws {
        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(CommandLayout.self, from: data)
        XCTAssertEqual(decoded, layout)
    }

    func testValueDropdownKindRoundTrips() throws {
        let kind = CommandKind.valueDropdown(.depth)
        let decoded = try JSONDecoder().decode(CommandKind.self, from: JSONEncoder().encode(kind))
        XCTAssertEqual(decoded, kind)
    }

    // MARK: Helper

    private func descriptor(_ id: String) -> CommandDescriptor {
        guard let match = layout.commands.first(where: { $0.id == id }) else {
            XCTFail("no descriptor with id \(id)")
            return layout.commands[0]
        }
        return match
    }
}
