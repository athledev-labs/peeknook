// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

final class CapturePermissionTests: XCTestCase {
    func testDisplayNames() {
        XCTAssertEqual(CapturePermission.screenRecording.displayName, "Screen Recording")
        XCTAssertEqual(CapturePermission.camera.displayName, "Camera")
        XCTAssertEqual(CapturePermission.accessibility.displayName, "Accessibility")
    }

    func testSetupChipTitleKeepsRecordingWording() {
        XCTAssertEqual(CapturePermission.screenRecording.setupChipTitle, "Recording")
        XCTAssertEqual(CapturePermission.camera.setupChipTitle, "Camera")
    }

    func testRecoveryActionMapping() {
        XCTAssertEqual(CapturePermission.screenRecording.recoveryAction, .openScreenRecordingSettings)
        XCTAssertEqual(CapturePermission.accessibility.recoveryAction, .openAccessibilitySettings)
        // Not-yet-wired permissions fall back to the setup drill-in until the camera PR.
        XCTAssertEqual(CapturePermission.camera.recoveryAction, .openSetup)
        XCTAssertEqual(CapturePermission.microphone.recoveryAction, .openSetup)
        XCTAssertEqual(CapturePermission.speechRecognition.recoveryAction, .openSetup)
    }

    func testPermissionRequiredFailureCarriesTargetedRecovery() {
        let screen = SessionFailure.permissionRequired(.screenRecording)
        XCTAssertEqual(screen.kind, .permissionRequired(name: "Screen Recording"))
        XCTAssertEqual(screen.primaryRecovery, .openScreenRecordingSettings)
        XCTAssertEqual(screen.secondaryRecovery, .tryAgain)

        let camera = SessionFailure.permissionRequired(.camera)
        XCTAssertEqual(camera.kind, .permissionRequired(name: "Camera"))
        XCTAssertEqual(camera.primaryRecovery, .openSetup)
    }
}
