// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// The a11y-first / OCR-escalation arbitration, driven by stub readers so it is exercised without a
/// window server.
final class CompositeScreenTextReaderTests: XCTestCase {

    private let target = ScreenTextTarget(windowID: 1, pid: 42, appName: "Player", windowTitle: "Show")

    private func ocrLine(_ text: String) -> ScreenTextLine {
        ScreenTextLine(text: text, confidence: 0.95, rect: ScreenTextRect(x: 0.2, y: 0.85, width: 0.6, height: 0.06))
    }

    func testTrustsAccessibilityWhenItHasARealCaption() async throws {
        let a11y = StubScreenTextReader(scripted: [ScreenTextSnapshot(
            lines: [ScreenTextLine(text: "I never expected to see you here")], source: .accessibility
        )])
        let ocr = StubScreenTextReader(scripted: [ScreenTextSnapshot(lines: [ocrLine("should not be used")], source: .opticalCharacterRecognition)])
        let composite = CompositeScreenTextReader(accessibility: a11y, ocr: ocr)

        let snapshot = try await composite.readText(target: target)
        XCTAssertEqual(snapshot.source, .accessibility)
        XCTAssertEqual(ocr.readCount, 0, "OCR must not run when accessibility already has the caption")
    }

    func testEscalatesToOCRWhenAccessibilityIsOnlyChrome() async throws {
        // Accessibility sees only short chrome labels -> no caption -> escalate.
        let a11y = StubScreenTextReader(scripted: [ScreenTextSnapshot(
            lines: [ScreenTextLine(text: "Play"), ScreenTextLine(text: "Pause")], source: .accessibility
        )])
        let ocr = StubScreenTextReader(scripted: [ScreenTextSnapshot(
            lines: [ocrLine("We have to leave now")], source: .opticalCharacterRecognition
        )])
        let composite = CompositeScreenTextReader(accessibility: a11y, ocr: ocr)

        let snapshot = try await composite.readText(target: target)
        XCTAssertEqual(snapshot.source, .opticalCharacterRecognition)
        XCTAssertEqual(OnScreenLineExtractor.caption(from: snapshot), "We have to leave now")
        XCTAssertEqual(ocr.readCount, 1)
    }

    func testFallsBackToEmptyWhenNeitherHasText() async throws {
        let a11y = StubScreenTextReader(error: CaptureError.failed("untrusted"))
        let ocr = StubScreenTextReader(scripted: [ScreenTextSnapshot.empty(source: .opticalCharacterRecognition)])
        let composite = CompositeScreenTextReader(accessibility: a11y, ocr: ocr)

        let snapshot = try await composite.readText(target: target)
        XCTAssertTrue(snapshot.lines.isEmpty)
    }
}
