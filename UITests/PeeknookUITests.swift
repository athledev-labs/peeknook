// SPDX-License-Identifier: Apache-2.0

import XCTest

final class PeeknookUITests: XCTestCase {
    private var app: XCUIApplication!

    private func control(withTestID id: String) -> XCUIElement {
        for query: XCUIElementQuery in [app.buttons, app.switches, app.toggles] {
            let match = query[id]
            if match.exists { return match }
        }
        return app.buttons[id]
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-PeeknookTestMode"]
        app.launch()
    }

    func testHomeShowsEnabledCaptureInTestMode() throws {
        let capture = app.buttons[PeekTestID.capture]
        XCTAssertTrue(capture.waitForExistence(timeout: 10))
        XCTAssertTrue(capture.isEnabled)
    }

    func testCaptureFlowReachesResultInTestMode() throws {
        let capture = app.buttons[PeekTestID.capture]
        XCTAssertTrue(capture.waitForExistence(timeout: 10))
        capture.tap()
        XCTAssertTrue(app.staticTexts["test answer"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons[PeekTestID.done].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons[PeekTestID.newChat].exists)
    }

    func testSettingsRoundTripInTestMode() throws {
        app.terminate()
        app.launchArguments = ["-PeeknookTestMode", "-PeeknookTestOpenSettings"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 15))
        let greeting = control(withTestID: PeekTestID.showGreeting)
        XCTAssertTrue(greeting.waitForExistence(timeout: 15))
        greeting.tap()

        app.buttons["Home"].tap()
        XCTAssertTrue(app.buttons[PeekTestID.capture].waitForExistence(timeout: 10))
    }

    func testStatsTopBarAvailableInTestMode() throws {
        let stats = app.buttons[PeekTestID.stats]
        XCTAssertTrue(stats.waitForExistence(timeout: 10))
        stats.tap()
        XCTAssertTrue(app.staticTexts["Stats"].waitForExistence(timeout: 5))
    }
}

/// Mirrors ``PeekTestID`` in PeeknookUI so the UI test bundle stays decoupled from app targets.
private enum PeekTestID {
    static let capture = "peeknook.capture"
    static let done = "peeknook.done"
    static let newChat = "peeknook.newChat"
    static let stats = "peeknook.stats"
    static let showGreeting = "peeknook.settings.showGreeting"
}
