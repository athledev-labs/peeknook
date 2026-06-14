// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

@MainActor
final class SetupCoordinatorDiskCheckTests: XCTestCase {
    private struct StubProbe: ModelStorageProbe {
        let available: Int64?
        func availableBytesForModelStore() -> Int64? { available }
    }

    private func makeCoordinator(
        settings: PeeknookSettings,
        suite: String,
        probe: ModelStorageProbe
    ) -> SetupCoordinator {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return SetupCoordinator(
            settings: settings,
            defaults: defaults,
            storageProbe: probe,
            permissionStatus: { CapturePermissionStatus(accessibilityTrusted: false, screenRecordingGranted: true) }
        )
    }

    func testBlocksWhenFreeSpaceIsShort() {
        var settings = PeeknookSettings()
        settings.textModel = "gemma4:e4b"   // ~10 GB
        let setup = makeCoordinator(
            settings: settings, suite: "peeknook.tests.disk-short", probe: StubProbe(available: 4_000_000_000)
        )

        setup.pullRecommendedModel()

        XCTAssertFalse(setup.isPullingModel, "A too-small disk must block the pull before it starts.")
        guard case .failed(let message) = setup.modelStep else {
            return XCTFail("Expected a sized .failed disk block, got \(setup.modelStep).")
        }
        XCTAssertTrue(message.contains("Free up some space"), "got: \(message)")
    }

    func testProceedsWhenSpaceIsAmple() {
        var settings = PeeknookSettings()
        settings.textModel = "gemma4:e4b"
        settings.ollamaBaseURL = "http://127.0.0.1:1"   // dead, but the gate passed so the pull starts
        let setup = makeCoordinator(
            settings: settings, suite: "peeknook.tests.disk-ample", probe: StubProbe(available: 100_000_000_000)
        )

        setup.pullRecommendedModel()

        XCTAssertTrue(setup.isPullingModel, "Ample free space must let the pull start.")
        setup.cancelPull()
    }

    func testSkipsCheckForRemoteOllama() {
        var settings = PeeknookSettings()
        settings.textModel = "gemma4:e4b"
        settings.ollamaBaseURL = "https://example.com:11434"   // remote — can't read its disk
        let setup = makeCoordinator(
            settings: settings, suite: "peeknook.tests.disk-remote", probe: StubProbe(available: 1)
        )

        setup.pullRecommendedModel()

        XCTAssertTrue(setup.isPullingModel, "Remote Ollama must skip the local disk check even with tiny free space.")
        setup.cancelPull()
    }

    func testSkipsCheckForUnknownModelSize() {
        var settings = PeeknookSettings()
        settings.textModel = "myorg/custom"   // not in the catalog → unknown size
        settings.ollamaBaseURL = "http://127.0.0.1:1"
        let setup = makeCoordinator(
            settings: settings, suite: "peeknook.tests.disk-unknown", probe: StubProbe(available: 1)
        )

        setup.pullRecommendedModel()

        XCTAssertTrue(setup.isPullingModel, "An unknown model size must skip the check — a false block is worse than no block.")
        setup.cancelPull()
    }

    func testUnresolvableProbeSkipsCheck() {
        var settings = PeeknookSettings()
        settings.textModel = "gemma4:e4b"
        settings.ollamaBaseURL = "http://127.0.0.1:1"
        let setup = makeCoordinator(
            settings: settings, suite: "peeknook.tests.disk-nil-probe", probe: StubProbe(available: nil)
        )

        setup.pullRecommendedModel()

        XCTAssertTrue(setup.isPullingModel, "A nil probe (can't tell) must skip rather than false-block.")
        setup.cancelPull()
    }
}
