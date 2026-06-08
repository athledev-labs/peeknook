// SPDX-License-Identifier: Apache-2.0

import XCTest

final class PeeknookUITests: XCTestCase {
    private var app: XCUIApplication!

    private func settingsControl(matching label: String) -> XCUIElement {
        let predicate = NSPredicate(format: "label == %@", label)
        for query: XCUIElementQuery in [app.switches, app.buttons, app.toggles] {
            let match = query.matching(predicate).firstMatch
            if match.exists { return match }
        }
        return app.switches[label]
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-PeeknookTestMode"]
        app.launch()
    }

    func testHomeShowsEnabledCaptureInTestMode() throws {
        let capture = app.buttons["peeknook.capture"]
        XCTAssertTrue(capture.waitForExistence(timeout: 10))
        XCTAssertTrue(capture.isEnabled)
    }

    func testCaptureFlowReachesResultInTestMode() throws {
        let capture = app.buttons["peeknook.capture"]
        XCTAssertTrue(capture.waitForExistence(timeout: 10))
        capture.tap()
        XCTAssertTrue(app.staticTexts["test answer"].waitForExistence(timeout: 15))
    }

    func testSettingsRoundTripInTestMode() throws {
        app.terminate()
        app.launchArguments = ["-PeeknookTestMode", "-PeeknookTestOpenSettings"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 15))
        let greeting = settingsControl(matching: "Show greeting")
        XCTAssertTrue(greeting.waitForExistence(timeout: 15))
        greeting.tap()

        app.buttons["Home"].tap()
        XCTAssertTrue(app.buttons["peeknook.capture"].waitForExistence(timeout: 10))
    }

    func testStatsTopBarAvailableInTestMode() throws {
        let stats = app.buttons["Stats"]
        XCTAssertTrue(stats.waitForExistence(timeout: 10))
        stats.tap()
        XCTAssertTrue(app.staticTexts["Stats"].waitForExistence(timeout: 5))
    }
}
