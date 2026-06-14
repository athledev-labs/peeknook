// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

@MainActor
final class SetupCoordinatorWelcomeTests: XCTestCase {
    private func makeCoordinator(suite: String) -> (SetupCoordinator, UserDefaults) {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (SetupCoordinator(settings: .default, defaults: defaults), defaults)
    }

    func testWelcomeSeenIsFalseOnFreshInstallAndTrueAfterMarking() {
        let (setup, _) = makeCoordinator(suite: "peeknook.tests.welcome-fresh")
        XCTAssertFalse(setup.welcomeSeen, "A fresh install must show the welcome once.")
        setup.markWelcomeSeen()
        XCTAssertTrue(setup.welcomeSeen)
    }

    func testWelcomeSeenPersistsAcrossCoordinatorsOnTheSameDefaults() {
        let suite = "peeknook.tests.welcome-persist"
        let (setup, defaults) = makeCoordinator(suite: suite)
        setup.markWelcomeSeen()
        // A brand-new coordinator on the same defaults must remember it (no re-show after relaunch).
        let reborn = SetupCoordinator(settings: .default, defaults: defaults)
        XCTAssertTrue(reborn.welcomeSeen)
    }

    func testWelcomeSeenKeyIsInThePeeknookNamespace() {
        XCTAssertEqual(SetupCoordinator.welcomeSeenKey, "peeknook.setup.welcomeSeen.v1")
    }

    func testApplyTestBypassMarksWelcomeSeen() {
        let (setup, _) = makeCoordinator(suite: "peeknook.tests.welcome-bypass")
        setup.applyTestBypass()
        XCTAssertTrue(setup.welcomeSeen, "Deterministic UI/unit tests must skip the welcome screen.")
    }

    func testWelcomeSeenSurvivesASettingsSave() {
        // welcomeSeen is a standalone default, not a Codable PeeknookSettings field (invariant #3):
        // persisting settings on the same defaults must not disturb it.
        let suite = "peeknook.tests.welcome-decode-independent"
        let (setup, defaults) = makeCoordinator(suite: suite)
        setup.markWelcomeSeen()
        var settings = PeeknookSettings.default
        settings.save(to: defaults)
        let reborn = SetupCoordinator(settings: .default, defaults: defaults)
        XCTAssertTrue(reborn.welcomeSeen)
    }
}
