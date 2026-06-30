// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

final class ScreenTextBaselineTests: XCTestCase {
    private func line(_ text: String) -> ScreenTextLine {
        ScreenTextLine(text: text, confidence: 1, rect: nil)
    }

    func testSignatureNormalizesCaseAndWhitespace() {
        let signature = ScreenTextBaseline.signature(of: [
            line("  Kim   Se Jeong  "),
            line("Share")
        ])
        XCTAssertTrue(signature.contains("kim se jeong"))
        XCTAssertTrue(signature.contains("share"))
        XCTAssertEqual(signature.count, 2)
    }

    func testSignatureDropsBlankLines() {
        let signature = ScreenTextBaseline.signature(of: [line("   "), line("")])
        XCTAssertTrue(signature.isEmpty)
    }

    func testFilteredRemovesBaselineChrome() {
        let baseline = ScreenTextBaseline.signature(of: [
            line("Kim Se Jeong - \"Twenty Five, Twenty One\" Cover"),
            line("Share")
        ])
        let read = [
            line("Kim Se Jeong - \"Twenty Five, Twenty One\" Cover"),  // static title — drop
            line("Share"),                                              // static button — drop
            line("It felt like you were holding my hand")               // new subtitle — keep
        ]
        let kept = ScreenTextBaseline.filtered(read, excluding: baseline)
        XCTAssertEqual(kept.map(\.text), ["It felt like you were holding my hand"])
    }

    func testFilteredMatchesIgnoringCaseAndSpacing() {
        let baseline = ScreenTextBaseline.signature(of: [line("Up Next")])
        let kept = ScreenTextBaseline.filtered([line("  up   next ")], excluding: baseline)
        XCTAssertTrue(kept.isEmpty, "Chrome must be rejected despite OCR re-spacing/case wobble")
    }

    func testEmptyBaselineIsPassthrough() {
        let read = [line("anything")]
        XCTAssertEqual(ScreenTextBaseline.filtered(read, excluding: []).map(\.text), ["anything"])
    }

    func testNewLineThatWasNotPresentAtArmPasses() {
        let baseline = ScreenTextBaseline.signature(of: [line("Title"), line("Subscribe")])
        let kept = ScreenTextBaseline.filtered([line("A brand new lyric line")], excluding: baseline)
        XCTAssertEqual(kept.map(\.text), ["A brand new lyric line"])
    }
}
