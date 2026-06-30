// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// The pure spatial extractor: which on-screen text is the live caption. Pins the geometry strategy
/// (subtitles are large, low, centered), the structural fallback (longest confident line), the noise
/// floor, and the "never fabricate" contract.
final class OnScreenLineExtractorTests: XCTestCase {

    private func line(_ text: String, confidence: Float = 1, x: Float = 0, y: Float = 0, w: Float = 0.5, h: Float = 0.05) -> ScreenTextLine {
        ScreenTextLine(text: text, confidence: confidence, rect: ScreenTextRect(x: x, y: y, width: w, height: h))
    }

    func testEmptySnapshotYieldsNil() {
        let snapshot = ScreenTextSnapshot.empty(source: .opticalCharacterRecognition)
        XCTAssertNil(OnScreenLineExtractor.caption(from: snapshot))
    }

    func testWhitespaceOnlyLinesYieldNil() {
        let snapshot = ScreenTextSnapshot(lines: [line("   "), line("\n")], source: .opticalCharacterRecognition)
        XCTAssertNil(OnScreenLineExtractor.caption(from: snapshot))
    }

    func testPrefersLowerLargerTextOverSmallChrome() {
        // A small clock at the top vs a large subtitle low and centered.
        let snapshot = ScreenTextSnapshot(lines: [
            line("12:04", confidence: 1, x: 0.0, y: 0.02, w: 0.08, h: 0.02),       // chrome: small, top
            line("We have to leave now", confidence: 0.95, x: 0.2, y: 0.85, w: 0.6, h: 0.06), // subtitle: large, low
        ], source: .opticalCharacterRecognition)
        XCTAssertEqual(OnScreenLineExtractor.caption(from: snapshot), "We have to leave now")
    }

    func testDropsLowConfidenceNoise() {
        let snapshot = ScreenTextSnapshot(lines: [
            line("garbled", confidence: 0.1, x: 0.2, y: 0.85, w: 0.6, h: 0.06),
        ], source: .opticalCharacterRecognition)
        XCTAssertNil(OnScreenLineExtractor.caption(from: snapshot))
    }

    func testJoinsMultiLineSubtitleInReadingOrder() {
        // A two-line subtitle: the lower line must not be emitted before the upper one.
        let snapshot = ScreenTextSnapshot(lines: [
            line("and then she said", confidence: 0.95, x: 0.2, y: 0.82, w: 0.6, h: 0.05),
            line("we should go home", confidence: 0.95, x: 0.2, y: 0.88, w: 0.6, h: 0.05),
        ], source: .opticalCharacterRecognition)
        XCTAssertEqual(OnScreenLineExtractor.caption(from: snapshot), "and then she said we should go home")
    }

    func testCapsAtMaxLines() {
        let lines = (0..<6).map { i in
            line("line \(i)", confidence: 0.95, x: 0.2, y: 0.8, w: 0.6, h: 0.05)
        }
        let snapshot = ScreenTextSnapshot(lines: lines, source: .opticalCharacterRecognition)
        let caption = OnScreenLineExtractor.caption(from: snapshot)
        XCTAssertNotNil(caption)
        XCTAssertLessThanOrEqual(caption!.components(separatedBy: "line ").count - 1, OnScreenLineExtractor.maxLines)
    }

    func testStructuralFallbackPrefersLongestLine() {
        // No geometry (accessibility): the sentence beats the short label.
        let snapshot = ScreenTextSnapshot(lines: [
            ScreenTextLine(text: "Play"),
            ScreenTextLine(text: "I never expected to see you here again"),
            ScreenTextLine(text: "Pause"),
        ], source: .accessibility)
        XCTAssertEqual(OnScreenLineExtractor.caption(from: snapshot), "I never expected to see you here again")
    }
}
