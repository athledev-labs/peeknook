// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Arbitrates the two screen readers: try the cheap accessibility read first, and escalate to the
/// heavier on-device OCR pass only when accessibility did not yield a real caption (the common case for
/// video shows, whose subtitles are rendered pixels). The escalation DECISION is the pure, tested
/// ``ScreenTextReaderPolicy``; this type only owns the "ask one, maybe ask the other" glue, so it
/// composes `any OnScreenTextReading` and is itself unit-testable with stub readers.
///
/// Fail-soft like its members: a reader that throws is treated as "nothing here" so one backend failing
/// (accessibility untrusted, OCR framework missing) degrades to the other rather than ending the
/// caption. When neither yields text the result is an empty snapshot and the source rides audio.
///
/// NOT yet production-wired: it composes ``AccessibilityScreenTextReader``, which cannot pin the frozen
/// `windowID` (see that type), so production reads with OCR alone for now. This stays tested and ready
/// for when accessibility can be tied to the armed window.
struct CompositeScreenTextReader: OnScreenTextReading {
    private let accessibility: any OnScreenTextReading
    private let ocr: any OnScreenTextReading

    init(accessibility: any OnScreenTextReading, ocr: any OnScreenTextReading) {
        self.accessibility = accessibility
        self.ocr = ocr
    }

    func readText(target: ScreenTextTarget) async throws -> ScreenTextSnapshot {
        let accessibilitySnapshot = try? await accessibility.readText(target: target)
        let accessibilityCandidate = accessibilitySnapshot.flatMap { OnScreenLineExtractor.caption(from: $0) }

        if !ScreenTextReaderPolicy.shouldEscalateToOCR(accessibilityCandidate: accessibilityCandidate),
           let accessibilitySnapshot {
            return accessibilitySnapshot
        }

        let ocrSnapshot = try? await ocr.readText(target: target)
        if let ocrSnapshot, !ocrSnapshot.lines.isEmpty {
            return ocrSnapshot
        }

        // OCR saw nothing (DRM-black frame, no rendered text, framework missing): keep the accessibility
        // read if we had one, else an honest empty result.
        return accessibilitySnapshot
            ?? .empty(source: .opticalCharacterRecognition, appName: target.appName, windowTitle: target.windowTitle)
    }
}
