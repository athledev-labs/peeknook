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
        let captureVisible = app.buttons["Capture"].waitForExistence(timeout: 2)
        XCTAssertTrue(setupVisible || captureVisible, "Expected Get ready or idle home")
    }
}
