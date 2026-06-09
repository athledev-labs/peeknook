// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

@MainActor
final class ReadinessMatrixTests: XCTestCase {
    private func status(screen: Bool = false, ax: Bool = false) -> CapturePermissionStatus {
        CapturePermissionStatus(accessibilityTrusted: ax, screenRecordingGranted: screen)
    }

    // MARK: CapturePermissionStatus

    func testGrantsMapsEachPermission() {
        let granted = status(screen: true, ax: true)
        XCTAssertTrue(granted.grants(.screenRecording))
        XCTAssertTrue(granted.grants(.accessibility))
        // Not tracked yet — these land with the camera/voice grounds.
        XCTAssertFalse(granted.grants(.camera))
        XCTAssertFalse(granted.grants(.microphone))
        XCTAssertFalse(granted.grants(.speechRecognition))
    }

    func testCanCaptureRequiresScreenRecordingNotAccessibility() {
        XCTAssertFalse(status(screen: false, ax: true).canCapture, "AX alone is not enough (OR-bug fix).")
        XCTAssertTrue(status(screen: true, ax: false).canCapture)
    }

    // MARK: permissionsSatisfied (the pure matrix half)

    func testScreenDefaultSatisfiedOnlyByScreenRecording() {
        XCTAssertTrue(SetupCoordinator.permissionsSatisfied(for: .screenDefault, status: status(screen: true)))
        XCTAssertFalse(SetupCoordinator.permissionsSatisfied(for: .screenDefault, status: status(screen: false)))
        // AX granted but not Screen Recording → still not satisfied (AX is supplementary).
        XCTAssertFalse(SetupCoordinator.permissionsSatisfied(for: .screenDefault, status: status(screen: false, ax: true)))
    }

    func testCameraProfileNeedsCameraNotScreenRecording() {
        let camera = GroundProfile(
            id: "camera.test", displayNameKey: "Cam", symbol: "camera",
            primaryGround: .camera, activeGrounds: [.camera], isBuiltIn: false
        )
        // Screen Recording granted but Camera isn't → not satisfied. The matrix generalizes.
        XCTAssertFalse(SetupCoordinator.permissionsSatisfied(for: camera, status: status(screen: true)))
    }

    // MARK: readiness(for:) integration

    func testBypassedCoordinatorIsReady() {
        let setup = makeCoordinator(suite: "peeknook.tests.readiness-bypass")
        setup.applyTestBypass()
        XCTAssertTrue(setup.isReady)
        XCTAssertTrue(setup.readiness(for: .screenDefault))
    }

    func testFreshCoordinatorNotReadyEvenWhenPermissionsGranted() {
        // Steps are pending on a fresh coordinator — that gates before permissions, so injecting a
        // fully-granted status must still report not-ready.
        let setup = makeCoordinator(
            suite: "peeknook.tests.readiness-fresh",
            permissionStatus: { CapturePermissionStatus(accessibilityTrusted: true, screenRecordingGranted: true) }
        )
        XCTAssertFalse(setup.isReady, "Pending Ollama/model steps gate readiness before permissions.")
    }

    // MARK: permissionChecklist (profile-conditional, exercises the injected provider)

    func testChecklistForScreenDefaultIsScreenRecording() {
        let setup = makeCoordinator(
            suite: "peeknook.tests.checklist-screen",
            permissionStatus: { CapturePermissionStatus(accessibilityTrusted: false, screenRecordingGranted: true) }
        )
        let list = setup.permissionChecklist(for: .screenDefault)
        XCTAssertEqual(list.map(\.permission), [.screenRecording])
        XCTAssertEqual(list.map(\.isGranted), [true])
    }

    func testChecklistForCameraProfileShowsCameraNotScreenRecording() {
        let setup = makeCoordinator(
            suite: "peeknook.tests.checklist-camera",
            permissionStatus: { CapturePermissionStatus(accessibilityTrusted: false, screenRecordingGranted: true) }
        )
        let camera = GroundProfile(
            id: "camera.test", displayNameKey: "Cam", symbol: "camera",
            primaryGround: .camera, activeGrounds: [.camera], isBuiltIn: false
        )
        let list = setup.permissionChecklist(for: camera)
        XCTAssertEqual(list.map(\.permission), [.camera])
        XCTAssertEqual(list.map(\.isGranted), [false], "Camera isn't tracked yet → not granted.")
    }

    private func makeCoordinator(
        suite: String,
        permissionStatus: @escaping @MainActor () -> CapturePermissionStatus = { CapturePermissionStatus.current() }
    ) -> SetupCoordinator {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return SetupCoordinator(settings: .default, defaults: defaults, permissionStatus: permissionStatus)
    }
}
