// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// When Ollama is unreachable, the model row must stay honest: a previously-installed model is
/// "blocked, waiting on the server", NOT "download me". The last-known installed set is sticky
/// (kept in memory and persisted) so an outage — or even an app relaunch — never makes the row
/// claim the model vanished. Readiness still requires the server to actually be up.
///
/// REGRESSION SENTINELS: reverting `SetupCoordinator.refresh()`'s unreachable branch to the old
/// `modelStep = .pending` makes `testOfflineWithKnownInstalledModelReportsBlockedNotPending` fail on
/// the `.blocked` assertion (it short-circuits at the `guard` before the sticky-set check); the
/// companion revert to `installedModelNames = []` is caught by `testInstalledNamesStickyAcrossOfflineRefresh`
/// and `testInstalledSetPersistsAcrossRelaunchSoOfflineRowStaysBlocked`. Keep all three honest.
@MainActor
final class SetupCoordinatorOfflineModelTests: XCTestCase {
    /// A loopback port nothing listens on: the HTTPS gate exempts loopback, so the probe runs and
    /// fails fast with connection-refused (the established `SetupCoordinatorBackendTests` seam).
    private let deadURL = "http://127.0.0.1:1"

    private func makeCoordinator(
        settings: PeeknookSettings,
        suite: String,
        seedInstalled: [String]? = nil
    ) -> SetupCoordinator {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        if let seedInstalled {
            defaults.set(seedInstalled, forKey: SetupCoordinator.lastInstalledModelsKey)
        }
        return SetupCoordinator(
            settings: settings,
            defaults: defaults,
            permissionStatus: {
                CapturePermissionStatus(accessibilityTrusted: false, screenRecordingGranted: true)
            }
        )
    }

    // MARK: - A-1 the bug fix

    func testOfflineWithKnownInstalledModelReportsBlockedNotPending() async {
        var settings = PeeknookSettings()
        settings.textModel = "gemma4:e4b"
        settings.ollamaBaseURL = deadURL
        let setup = makeCoordinator(
            settings: settings,
            suite: "peeknook.tests.offline-blocked-a1",
            seedInstalled: ["gemma4:e4b"]
        )

        await setup.refresh()

        guard case .blocked = setup.modelStep else {
            return XCTFail("Offline with a known-installed model must be .blocked, got \(setup.modelStep).")
        }
        guard case .failed = setup.ollamaStep else {
            return XCTFail("Offline Ollama step must be .failed, got \(setup.ollamaStep).")
        }
        XCTAssertFalse(
            setup.installedModelNames.isEmpty,
            "The known-installed set must stay sticky offline — wiping it is what produced the bogus 'Download model'."
        )
    }

    // MARK: - A-2 first-run offline is genuinely pending (byte-identical download path)

    func testFirstRunOfflineStaysPendingAndForgetsNothing() async {
        var settings = PeeknookSettings()
        settings.textModel = "gemma4:e4b"
        settings.ollamaBaseURL = deadURL
        let setup = makeCoordinator(settings: settings, suite: "peeknook.tests.offline-firstrun-a2")

        await setup.refresh()

        XCTAssertEqual(setup.modelStep, .pending, "A genuine never-installed model keeps the first-run Download CTA.")
        XCTAssertTrue(setup.installedModelNames.isEmpty)
    }

    // MARK: - A-3 readiness invariant (offline never ready, even when remembered installed)

    func testBlockedModelStepKeepsReadinessFalse() async {
        var settings = PeeknookSettings()
        settings.textModel = "gemma4:e4b"
        settings.ollamaBaseURL = deadURL
        let setup = makeCoordinator(
            settings: settings,
            suite: "peeknook.tests.offline-ready-a3",
            seedInstalled: ["gemma4:e4b"]
        )

        await setup.refresh()

        XCTAssertFalse(
            setup.isReady,
            "Setup must never be ready while Ollama is down, even with the model known-installed."
        )
    }

    // MARK: - A-4 sticky set (the picker-flicker latent fix)

    func testInstalledNamesStickyAcrossOfflineRefresh() async {
        var settings = PeeknookSettings()
        settings.textModel = "gemma4:e4b"
        settings.ollamaBaseURL = deadURL
        let setup = makeCoordinator(
            settings: settings,
            suite: "peeknook.tests.offline-sticky-a4",
            seedInstalled: ["gemma4:e4b"]
        )

        await setup.refresh()

        XCTAssertTrue(
            setup.isModelInstalled("gemma4:e4b"),
            "An offline refresh must not wipe the installed set (pickers elsewhere read it too)."
        )
    }

    // MARK: - A-5 non-Ollama backend untouched by the edited branch

    func testOpenAICompatibleStillShortCircuits() async {
        var settings = PeeknookSettings()
        settings.answerBackend = .openAICompatible
        settings.ollamaBaseURL = deadURL
        let setup = makeCoordinator(settings: settings, suite: "peeknook.tests.offline-openai-a5")

        await setup.refresh()

        XCTAssertEqual(setup.ollamaStep, .complete)
        XCTAssertEqual(setup.modelStep, .complete)
    }

    // MARK: - Persistence: survives relaunch

    func testInstalledSetPersistsAcrossRelaunchSoOfflineRowStaysBlocked() async {
        let suite = "peeknook.tests.offline-persist"
        var settings = PeeknookSettings()
        settings.textModel = "gemma4:e4b"
        settings.ollamaBaseURL = deadURL

        // First "launch": a reachable probe recorded the installed set (via the persist seam).
        let first = makeCoordinator(settings: settings, suite: suite)
        first.rememberInstalledModels(["gemma4:e4b", "llama3:8b"])

        // Second "launch": same defaults suite, Ollama offline. Init must reload the set from disk —
        // do NOT clear the domain here.
        let second = SetupCoordinator(
            settings: settings,
            defaults: UserDefaults(suiteName: suite)!,
            permissionStatus: {
                CapturePermissionStatus(accessibilityTrusted: false, screenRecordingGranted: true)
            }
        )
        XCTAssertTrue(
            second.isModelInstalled("gemma4:e4b"),
            "A relaunch must reload the persisted installed set so the offline row knows what's there."
        )

        await second.refresh()

        guard case .blocked = second.modelStep else {
            return XCTFail("Relaunch-while-offline must report .blocked, got \(second.modelStep).")
        }
    }

    // MARK: - Stress guard B: a switched-to-uninstalled tag must not be falsely satisfied

    func testSwitchingToAnUninstalledTagWhileOfflineStaysPending() async {
        var settings = PeeknookSettings()
        settings.textModel = "gemma4:26b"          // requested tag is NOT in the known set
        settings.ollamaBaseURL = deadURL
        let setup = makeCoordinator(
            settings: settings,
            suite: "peeknook.tests.offline-tagswitch",
            seedInstalled: ["gemma4:e4b"]          // a different tag was installed
        )

        await setup.refresh()

        XCTAssertEqual(
            setup.modelStep, .pending,
            "The sticky set holds e4b, not 26b — a tag-aware miss must stay .pending, never falsely .blocked."
        )
    }

    // MARK: - Stress guard C: a failed offline pull must not leave the row stuck mid-download

    func testPullFailingWhileOfflineEndsActionableNotStuckInProgress() async {
        var settings = PeeknookSettings()
        settings.textModel = "gemma4:e4b"
        settings.ollamaBaseURL = deadURL
        let setup = makeCoordinator(settings: settings, suite: "peeknook.tests.offline-pullfail")

        setup.pullRecommendedModel()

        // The pull streams to a dead port (immediate connection-refused), fails, and the post-pull
        // refresh runs. Poll until it settles rather than guessing a fixed delay.
        let deadline = Date().addingTimeInterval(10)
        while setup.isPullingModel, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertFalse(setup.isPullingModel, "The failed pull should have finished.")
        // The catch sets `.failed`, then the post-pull refresh runs against the still-dead URL and
        // settles a never-installed model to the actionable Download CTA. Assert that settled end state
        // positively — merely excluding `.inProgress` would also wrongly accept `.complete`/`.blocked`.
        XCTAssertEqual(
            setup.modelStep, .pending,
            "A failed offline pull on a never-installed model must settle to .pending (Download), never stick at .inProgress."
        )
    }
}
