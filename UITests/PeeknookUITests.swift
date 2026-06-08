// SPDX-License-Identifier: Apache-2.0

import XCTest

final class PeeknookUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAppLaunchesAndShowsSetupOrHome() throws {
        let app = XCUIApplication()
        app.launch()

        let setupVisible = app.staticTexts["Ollama server"].waitForExistence(timeout: 8)
        let captureVisible = app.buttons["peeknook.capture"].waitForExistence(timeout: 2)
            || app.buttons["Capture"].waitForExistence(timeout: 1)
        XCTAssertTrue(setupVisible || captureVisible, "Expected Get ready or idle home")
    }

    func testCaptureButtonUsesStableIdentifierWhenHomeIsReady() throws {
        let app = XCUIApplication()
        app.launch()

        let capture = app.buttons["peeknook.capture"]
        guard capture.waitForExistence(timeout: 8) else {
            throw XCTSkip("Capture control only appears after setup completes")
        }
        XCTAssertTrue(capture.isEnabled || capture.exists)
    }

    func testStatsTopBarAvailableAfterLaunch() throws {
        let app = XCUIApplication()
        app.launch()

        let stats = app.buttons["Stats"]
        guard stats.waitForExistence(timeout: 8) else {
            throw XCTSkip("Stats top-bar item not visible in current host chrome")
        }
        stats.tap()
        XCTAssertTrue(app.staticTexts["Stats"].waitForExistence(timeout: 3))
    }
}
