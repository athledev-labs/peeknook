// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Foundation
import XCTest
@testable import PeeknookCore

final class CaptureTargetSelectorTests: XCTestCase {
    // Two displays at different global origins (top-left origin space, matching SCWindow.frame).
    private let display1 = CaptureDisplayDescriptor(
        displayID: 1,
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900)
    )
    private let display2 = CaptureDisplayDescriptor(
        displayID: 2,
        frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080)
    )

    private let appOwnPID: pid_t = 99
    private let appFrontPID: pid_t = 10
    private let appOtherPID: pid_t = 20

    private func window(
        id: CGWindowID,
        frame: CGRect,
        owner: pid_t,
        layer: Int = 0
    ) -> CaptureWindowDescriptor {
        CaptureWindowDescriptor(windowID: id, frame: frame, ownerPID: owner, layer: layer)
    }

    // MARK: - Under-cursor priority

    func testUnderCursorWinsAcrossMonitors() {
        // Frontmost app has a big window on display1; cursor is over a smaller window on display2.
        let frontOnD1 = window(id: 1, frame: CGRect(x: 100, y: 100, width: 1000, height: 700), owner: appFrontPID)
        let otherOnD2 = window(id: 2, frame: CGRect(x: 1600, y: 200, width: 400, height: 300), owner: appOtherPID)

        let chosen = CaptureTargetSelector.selectWindow(
            windows: [frontOnD1, otherOnD2],
            cursor: CGPoint(x: 1700, y: 300), // inside otherOnD2 on display2
            ownerPID: appOwnPID,
            frontmostPID: appFrontPID
        )
        XCTAssertEqual(chosen?.windowID, 2)
    }

    func testFrontToBackFirstUsableUnderCursorWins() {
        // Two overlapping usable windows both contain the cursor; array is front-to-back.
        let top = window(id: 1, frame: CGRect(x: 0, y: 0, width: 800, height: 600), owner: appOtherPID)
        let bottom = window(id: 2, frame: CGRect(x: 0, y: 0, width: 800, height: 600), owner: appFrontPID)

        let chosen = CaptureTargetSelector.selectWindow(
            windows: [top, bottom], // first == topmost
            cursor: CGPoint(x: 100, y: 100),
            ownerPID: appOwnPID,
            frontmostPID: appFrontPID
        )
        XCTAssertEqual(chosen?.windowID, 1)
    }

    // MARK: - Usability filtering

    func testExcludesOwnPID() {
        // Cursor is over our own window; it must be skipped and fall through to selection.
        let own = window(id: 1, frame: CGRect(x: 0, y: 0, width: 800, height: 600), owner: appOwnPID)
        let other = window(id: 2, frame: CGRect(x: 2000, y: 200, width: 400, height: 300), owner: appOtherPID)

        let chosen = CaptureTargetSelector.selectWindow(
            windows: [own, other],
            cursor: CGPoint(x: 100, y: 100), // over our own window
            ownerPID: appOwnPID,
            frontmostPID: nil
        )
        XCTAssertEqual(chosen?.windowID, 2) // own excluded; largest remaining
    }

    func testExcludesNonZeroLayer() {
        let overlay = window(id: 1, frame: CGRect(x: 0, y: 0, width: 800, height: 600), owner: appOtherPID, layer: 25)
        let normal = window(id: 2, frame: CGRect(x: 0, y: 0, width: 400, height: 300), owner: appOtherPID, layer: 0)

        let chosen = CaptureTargetSelector.selectWindow(
            windows: [overlay, normal],
            cursor: CGPoint(x: 100, y: 100), // both contain cursor
            ownerPID: appOwnPID,
            frontmostPID: nil
        )
        XCTAssertEqual(chosen?.windowID, 2) // layer != 0 excluded
    }

    func testExcludesTinyWindows() {
        // width <= 80 or height <= 80 are unusable.
        let tooNarrow = window(id: 1, frame: CGRect(x: 0, y: 0, width: 80, height: 600), owner: appOtherPID)
        let tooShort = window(id: 2, frame: CGRect(x: 0, y: 0, width: 600, height: 80), owner: appOtherPID)
        let ok = window(id: 3, frame: CGRect(x: 0, y: 0, width: 200, height: 200), owner: appOtherPID)

        let chosen = CaptureTargetSelector.selectWindow(
            windows: [tooNarrow, tooShort, ok],
            cursor: nil,
            ownerPID: appOwnPID,
            frontmostPID: nil
        )
        XCTAssertEqual(chosen?.windowID, 3)
    }

    // MARK: - No cursor

    func testNoCursorChoosesFrontmostLargestWindow() {
        // Frontmost app has several windows; the largest of THAT app wins even if another app's
        // window is larger.
        let frontSmall = window(id: 1, frame: CGRect(x: 0, y: 0, width: 300, height: 300), owner: appFrontPID)
        let frontLarge = window(id: 2, frame: CGRect(x: 0, y: 0, width: 900, height: 700), owner: appFrontPID)
        let otherHuge = window(id: 3, frame: CGRect(x: 1440, y: 0, width: 1900, height: 1000), owner: appOtherPID)

        let chosen = CaptureTargetSelector.selectWindow(
            windows: [frontSmall, frontLarge, otherHuge],
            cursor: nil,
            ownerPID: appOwnPID,
            frontmostPID: appFrontPID
        )
        XCTAssertEqual(chosen?.windowID, 2)
    }

    func testNoCursorNoFrontmostChoosesLargestAnywhere() {
        let small = window(id: 1, frame: CGRect(x: 0, y: 0, width: 300, height: 300), owner: appOtherPID)
        let large = window(id: 2, frame: CGRect(x: 1440, y: 0, width: 1900, height: 1000), owner: appFrontPID)

        let chosen = CaptureTargetSelector.selectWindow(
            windows: [small, large],
            cursor: nil,
            ownerPID: appOwnPID,
            frontmostPID: nil // absent frontmost
        )
        XCTAssertEqual(chosen?.windowID, 2)
    }

    func testFrontmostWithNoUsableWindowsFallsBackToLargestAnywhere() {
        // Frontmost app present but all its windows are unusable → largest usable anywhere.
        let frontTiny = window(id: 1, frame: CGRect(x: 0, y: 0, width: 50, height: 50), owner: appFrontPID)
        let otherLarge = window(id: 2, frame: CGRect(x: 1440, y: 0, width: 1800, height: 1000), owner: appOtherPID)

        let chosen = CaptureTargetSelector.selectWindow(
            windows: [frontTiny, otherLarge],
            cursor: nil,
            ownerPID: appOwnPID,
            frontmostPID: appFrontPID
        )
        XCTAssertEqual(chosen?.windowID, 2)
    }

    // MARK: - Empty / unusable

    func testEmptyInputReturnsNil() {
        let chosen = CaptureTargetSelector.selectWindow(
            windows: [],
            cursor: CGPoint(x: 0, y: 0),
            ownerPID: appOwnPID,
            frontmostPID: appFrontPID
        )
        XCTAssertNil(chosen)
    }

    func testAllUnusableInputReturnsNil() {
        let own = window(id: 1, frame: CGRect(x: 0, y: 0, width: 800, height: 600), owner: appOwnPID)
        let overlay = window(id: 2, frame: CGRect(x: 0, y: 0, width: 800, height: 600), owner: appOtherPID, layer: 3)
        let tiny = window(id: 3, frame: CGRect(x: 0, y: 0, width: 40, height: 40), owner: appOtherPID)

        let chosen = CaptureTargetSelector.selectWindow(
            windows: [own, overlay, tiny],
            cursor: nil,
            ownerPID: appOwnPID,
            frontmostPID: appFrontPID
        )
        XCTAssertNil(chosen)
    }

    // MARK: - Display selection

    func testSelectDisplayCursorOnSecondDisplay() {
        let chosen = CaptureTargetSelector.selectDisplay(
            displays: [display1, display2],
            cursor: CGPoint(x: 2000, y: 500) // inside display2
        )
        XCTAssertEqual(chosen?.displayID, 2)
    }

    func testSelectDisplayCursorOutsideAllFallsBackToFirst() {
        let chosen = CaptureTargetSelector.selectDisplay(
            displays: [display1, display2],
            cursor: CGPoint(x: 5000, y: 5000) // off all displays
        )
        XCTAssertEqual(chosen?.displayID, 1)
    }

    func testSelectDisplayNilCursorChoosesFirst() {
        let chosen = CaptureTargetSelector.selectDisplay(
            displays: [display1, display2],
            cursor: nil
        )
        XCTAssertEqual(chosen?.displayID, 1)
    }

    func testSelectDisplayEmptyReturnsNil() {
        let chosen = CaptureTargetSelector.selectDisplay(displays: [], cursor: nil)
        XCTAssertNil(chosen)
    }
}
