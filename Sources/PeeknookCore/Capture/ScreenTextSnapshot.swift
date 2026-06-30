// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Which reader produced a ``ScreenTextSnapshot`` — kept on the snapshot so the extractor can pick the
/// right salience strategy (geometry for OCR, structure for accessibility) and so diagnostics stay
/// honest about HOW the on-screen text was read.
public enum ScreenTextReaderKind: Sendable, Equatable {
    /// Read from the focused window's accessibility tree (structural; on-device; no pixels).
    case accessibility
    /// Read by on-device optical character recognition of a window screenshot (carries geometry).
    case opticalCharacterRecognition
}

/// A normalized text rectangle in 0...1, top-left origin — the geometry an OCR observation carries and
/// the extractor scores for "is this a subtitle" (size + screen position). Deliberately NOT `CGRect`:
/// keeping it a plain value of `Float`s keeps the pure extractor policy free of CoreGraphics so it
/// compiles and unit-tests everywhere, and the OCR reader maps Vision's bounding box into it.
public struct ScreenTextRect: Sendable, Equatable {
    public let x: Float
    public let y: Float
    public let width: Float
    public let height: Float

    public init(x: Float, y: Float, width: Float, height: Float) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Vertical center (0 = top, 1 = bottom).
    public var midY: Float { y + height / 2 }
    /// Horizontal center (0 = left, 1 = right).
    public var midX: Float { x + width / 2 }
}

/// One line of text read off the screen: the string, a 0...1 confidence (OCR reports its own; a
/// structural source reports 1), and an optional normalized bounding box (present for OCR, nil for the
/// geometry-free accessibility tree). A pure `Sendable` value so a whole snapshot crosses the reader's
/// concurrency boundary and is trivially constructible in tests.
public struct ScreenTextLine: Sendable, Equatable {
    public let text: String
    public let confidence: Float
    public let rect: ScreenTextRect?

    public init(text: String, confidence: Float = 1, rect: ScreenTextRect? = nil) {
        self.text = text
        self.confidence = confidence
        self.rect = rect
    }
}

/// A single read of the on-screen text of the caption target window: its owning app/window identity, the
/// lines found, and which reader produced them. The pure value the ``OnScreenTextReading`` seam returns
/// and the ``OnScreenLineExtractor`` consumes — never an image, never an `AXUIElement`, so it crosses
/// actors freely and the extraction DECISION is unit-testable apart from the device-only read.
public struct ScreenTextSnapshot: Sendable, Equatable {
    public let appName: String?
    public let windowTitle: String?
    public let lines: [ScreenTextLine]
    public let source: ScreenTextReaderKind

    public init(
        appName: String? = nil,
        windowTitle: String? = nil,
        lines: [ScreenTextLine],
        source: ScreenTextReaderKind
    ) {
        self.appName = appName
        self.windowTitle = windowTitle
        self.lines = lines
        self.source = source
    }

    /// An empty read (no text found) — the honest "the window had nothing to read" result, distinct from
    /// a reader that could not run at all (which throws).
    public static func empty(source: ScreenTextReaderKind, appName: String? = nil, windowTitle: String? = nil) -> ScreenTextSnapshot {
        ScreenTextSnapshot(appName: appName, windowTitle: windowTitle, lines: [], source: source)
    }
}
