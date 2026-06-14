// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

@MainActor
final class ReadinessMatrixTests: XCTestCase {
    private func status(screen: Bool = false, ax: Bool = false, camera: Bool = false) -> CapturePermissionStatus {
        CapturePermissionStatus(accessibilityTrusted: ax, screenRecordingGranted: screen, cameraGranted: camera)
    }

    // MARK: CapturePermissionStatus

    func testGrantsMapsEachPermission() {
        let granted = status(screen: true, ax: true, camera: true)
        XCTAssertTrue(granted.grants(.screenRecording))
        XCTAssertTrue(granted.grants(.accessibility))
        XCTAssertTrue(granted.grants(.camera))
        XCTAssertFalse(status(camera: false).grants(.camera))
        // Not tracked yet — these land with the voice profiles.
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

    /// The shipped camera profile: Camera TCC alone satisfies it — Screen Recording is irrelevant
    /// in BOTH directions (locked invariant: camera.study never demands Screen Recording).
    func testCameraStudySatisfiedByCameraAloneAndIndependentOfScreenRecording() {
        XCTAssertTrue(SetupCoordinator.permissionsSatisfied(for: .cameraStudy, status: status(screen: false, camera: true)))
        XCTAssertFalse(SetupCoordinator.permissionsSatisfied(for: .cameraStudy, status: status(screen: true, camera: false)))
    }

    /// The setup capture step derives from the ACTIVE profile's permissions, not hardcoded Screen
    /// Recording — a camera-profile user must see Camera copy, and screen.default keeps its exact
    /// legacy string.
    func testCaptureStepIsProfileAware() {
        var cameraSettings = PeeknookSettings.default
        cameraSettings.activeProfileID = GroundProfile.cameraStudy.id
        let suite = "peeknook.tests.capture-step-camera"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let cameraSetup = SetupCoordinator(
            settings: cameraSettings,
            defaults: defaults,
            permissionStatus: { CapturePermissionStatus(accessibilityTrusted: false, screenRecordingGranted: true, cameraGranted: false) }
        )
        cameraSetup.refreshCapturePermission()
        guard case .failed(let cameraMessage) = cameraSetup.captureStep else {
            return XCTFail("Expected a failed capture step for the camera profile")
        }
        XCTAssertTrue(cameraMessage.contains("Camera"), "Camera profile must name Camera, got: \(cameraMessage)")
        XCTAssertFalse(cameraMessage.contains("Screen Recording"))

        let screenSetup = makeCoordinator(
            suite: "peeknook.tests.capture-step-screen",
            permissionStatus: { CapturePermissionStatus(accessibilityTrusted: false, screenRecordingGranted: false) }
        )
        screenSetup.refreshCapturePermission()
        guard case .failed(let screenMessage) = screenSetup.captureStep else {
            return XCTFail("Expected a failed capture step for screen.default")
        }
        XCTAssertTrue(screenMessage.hasPrefix("Screen Recording is required so the model can see your screen."),
                      "got: \(screenMessage)")
        XCTAssertTrue(screenMessage.contains("quit and reopen Peeknook"),
                      "the screen-recording capture step should carry the relaunch hint")
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
        XCTAssertEqual(list.map(\.isGranted), [false], "Injected status has no camera grant.")
    }

    // MARK: missingActivePermissions (the capture-routing seam — keys off requiredPermissions, not a literal)

    func testMissingActivePermissionsTracksTheActiveProfile() {
        let denied = makeCoordinator(
            suite: "peeknook.tests.missing-perms-denied",
            permissionStatus: { CapturePermissionStatus(accessibilityTrusted: false, screenRecordingGranted: false) }
        )
        XCTAssertEqual(denied.missingActivePermissions, [.screenRecording],
                       "screen.default has exactly one required permission; only Screen Recording is missing.")

        let granted = makeCoordinator(
            suite: "peeknook.tests.missing-perms-granted",
            permissionStatus: { CapturePermissionStatus(accessibilityTrusted: false, screenRecordingGranted: true) }
        )
        XCTAssertEqual(granted.missingActivePermissions, [], "Nothing missing once Screen Recording is granted.")
    }

    func testMissingActivePermissionsCountsEveryUngrantedPermissionForMultiGroundProfiles() {
        // A two-permission profile must report BOTH gaps, so routeUnready keeps the blanket
        // "Finish setup first" card (count != 1) — proving the routing keys off requiredPermissions,
        // not a Screen-Recording literal, and generalizes to future profiles.
        let suite = "peeknook.tests.missing-perms-multi"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let profile = GroundProfile(
            id: "test.screen-camera", displayNameKey: "Screen+Camera", symbol: "rectangle.on.rectangle",
            primaryGround: .screen, activeGrounds: [.screen, .camera], isBuiltIn: false
        )
        let catalog = ProfileCatalog(profiles: [profile])
        defaults.set(try! JSONEncoder().encode(catalog), forKey: ProfileCatalog.defaultsKey)
        var settings = PeeknookSettings.default
        settings.activeProfileID = profile.id
        let setup = SetupCoordinator(
            settings: settings,
            defaults: defaults,
            permissionStatus: {
                CapturePermissionStatus(accessibilityTrusted: false, screenRecordingGranted: false, cameraGranted: false)
            }
        )
        setup.profileStore = ProfileStore(defaults: defaults)
        XCTAssertEqual(Set(setup.missingActivePermissions), [.screenRecording, .camera])
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
