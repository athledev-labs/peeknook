// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

final class CameraStudyLayoutTests: XCTestCase {
    private let layout = CommandLayout.cameraStudy

    func testCameraLivePlacementOrderAndIdentity() {
        XCTAssertEqual(
            layout.forPlacement(.cameraLive).map(\.id),
            ["cameraLive.cancel", "cameraLive.shutter"]
        )
        XCTAssertEqual(
            layout.forPlacement(.cameraLive).map(\.accessibilityIdentifier),
            ["peeknook.cancel", "peeknook.shutter"]
        )
    }

    /// A live camera surface must never render without an exit: Cancel carries no module or
    /// permission gate and stays visible even in a context with nothing enabled.
    func testCancelAlwaysRenders() {
        let cancel = layout.forPlacement(.cameraLive)[0]
        XCTAssertTrue(cancel.requiredModules.isEmpty)
        XCTAssertTrue(cancel.requiredPermissions.isEmpty)
        XCTAssertTrue(cancel.isVisible(in: CommandBarContext(enabledModules: [])))
    }

    func testShutterGatesAndPinning() {
        let shutter = layout.forPlacement(.cameraLive)[1]
        XCTAssertEqual(shutter.requiredModules, [.cameraCapture])
        XCTAssertEqual(shutter.requiredPermissions, [.camera])
        XCTAssertTrue(shutter.pinnedTrailing)
        XCTAssertTrue(shutter.prominent)
        XCTAssertEqual(shutter.hotkey, .settingsSlot(.camera))
    }

    func testExactlyOnePinnedTrailingInCameraLive() {
        XCTAssertEqual(
            layout.forPlacement(.cameraLive).filter(\.pinnedTrailing).map(\.id),
            ["cameraLive.shutter"]
        )
    }

    /// THE single profile-source rule: the `.cameraLive` context derives its modules from the
    /// `camera.study` literal — never from the active profile, which stays `screen.default` in v1
    /// (⌘⇧C is event-scoped). Deriving from the active profile would hide Shutter and orphan a
    /// live camera with no way to capture.
    func testShutterVisibleUnderScreenDefaultActiveProfile() {
        let settings = PeeknookSettings(textModel: "x")
        XCTAssertEqual(
            GroundProfile.resolve(id: settings.activeProfileID, in: []).id,
            GroundProfile.screenDefault.id
        )

        let cameraModules = Set(ModuleID.allCases.filter {
            Module.isEnabled($0, in: settings, profile: .cameraStudy)
        })
        let shutter = layout.forPlacement(.cameraLive)[1]
        XCTAssertTrue(shutter.isVisible(in: CommandBarContext(enabledModules: cameraModules)))

        // The same gate derived from the SCREEN profile hides Shutter — the contradiction the
        // single-source rule exists to prevent.
        let screenModules = Set(ModuleID.allCases.filter {
            Module.isEnabled($0, in: settings, profile: .screenDefault)
        })
        XCTAssertFalse(shutter.isVisible(in: CommandBarContext(enabledModules: screenModules)))
    }

    /// `screenDefault` itself never gains `.cameraLive` descriptors (the Phase 1.5 migration
    /// anchor); `cameraStudy` reuses its idle/active/result bars untouched.
    func testOtherPlacementsReuseScreenDefault() {
        for placement in [CommandPlacement.idle, .active, .result] {
            XCTAssertEqual(
                layout.forPlacement(placement).map(\.id),
                CommandLayout.screenDefault.forPlacement(placement).map(\.id)
            )
        }
    }

    func testCameraStudyRoundTripsThroughCodable() throws {
        let decoded = try JSONDecoder().decode(CommandLayout.self, from: JSONEncoder().encode(layout))
        XCTAssertEqual(decoded, layout)
    }

    func testCameraStudyProfileLiteral() {
        let profile = GroundProfile.cameraStudy
        XCTAssertEqual(profile.id, "camera.study")
        XCTAssertEqual(profile.primaryGround, .camera)
        XCTAssertEqual(profile.activeGrounds, [.camera])
        XCTAssertEqual(profile.requiredPermissions, [.camera], "camera.study must never demand Screen Recording")
        XCTAssertTrue(GroundProfile.all.contains { $0.id == profile.id })
        XCTAssertEqual(GroundProfile.builtIn(id: "camera.study").id, profile.id)
    }
}
