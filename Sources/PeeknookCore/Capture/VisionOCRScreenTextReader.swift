// SPDX-License-Identifier: Apache-2.0

import Foundation

#if canImport(Vision) && canImport(ScreenCaptureKit)
import Vision
import ScreenCaptureKit
import CoreGraphics

/// Reads the on-screen TEXT of the frozen caption target by screenshotting that one window and running
/// on-device optical character recognition over it. The workhorse for video shows: it sees RENDERED
/// subtitles and canvas-drawn lyrics the accessibility tree cannot, and it carries geometry so
/// ``OnScreenLineExtractor`` can tell a low, large, centered subtitle from edge chrome.
///
/// On-device, fail-soft: `VNRecognizeTextRequest` runs locally (no network, ever), and a window that is
/// gone, a DRM-protected frame that captures as black, or a frame with no legible text all return an
/// EMPTY snapshot — never an error and never a guess — so the source rides audio rather than stalling.
/// The lone untestable device glue in the OCR path (screenshot + Vision); the salience/segment DECISIONS
/// it feeds are pure and unit-tested.
struct VisionOCRScreenTextReader: OnScreenTextReading {
    private let recognitionLanguages: [String]
    /// Cap the screenshot's longest side so a 5K window doesn't make each Vision pass crawl; still ample
    /// to read subtitles. A device-glue knob, not a decision.
    private static let maxPixel = 1920

    init(recognitionLanguages: [String] = []) {
        self.recognitionLanguages = recognitionLanguages
    }

    func readText(target: ScreenTextTarget) async throws -> ScreenTextSnapshot {
        guard let image = try await screenshot(of: target) else {
            return .empty(source: .opticalCharacterRecognition, appName: target.appName, windowTitle: target.windowTitle)
        }
        let lines = recognizeText(in: image)
        return ScreenTextSnapshot(
            appName: target.appName,
            windowTitle: target.windowTitle,
            lines: lines,
            source: .opticalCharacterRecognition
        )
    }

    /// Re-resolve the live `SCWindow` from the frozen id and capture it. A closed/minimized target yields
    /// nil (empty read), not a throw, so a vanished window ends the surface via the silence bound rather
    /// than a recovery card.
    private func screenshot(of target: ScreenTextTarget) async throws -> CGImage? {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == target.windowID }),
              window.frame.width > 1, window.frame.height > 1 else {
            return nil
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = 2
        config.width = min(Int(window.frame.width) * scale, Self.maxPixel)
        config.height = min(Int(window.frame.height) * scale, Self.maxPixel)
        config.scalesToFit = true
        config.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Run on-device text recognition and map each observation into a line with its top candidate's
    /// confidence and a top-left normalized bounding box (Vision reports bottom-left, so flip Y).
    private func recognizeText(in image: CGImage) -> [ScreenTextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if !recognitionLanguages.isEmpty {
            request.recognitionLanguages = recognitionLanguages
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observations = request.results else {
            return []
        }
        return observations.compactMap { observation -> ScreenTextLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let box = observation.boundingBox   // normalized, bottom-left origin
            let rect = ScreenTextRect(
                x: Float(box.origin.x),
                y: Float(1 - (box.origin.y + box.height)),   // flip to top-left origin
                width: Float(box.width),
                height: Float(box.height)
            )
            return ScreenTextLine(text: text, confidence: candidate.confidence, rect: rect)
        }
    }
}

#endif
