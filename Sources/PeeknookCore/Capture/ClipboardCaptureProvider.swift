// SPDX-License-Identifier: Apache-2.0

import Foundation

#if canImport(AppKit)
import AppKit
#endif

/// The read arm of the clipboard ground: hand back whatever text the user has copied. Isolated behind
/// this protocol so the provider's POLICY (build a text leg, label it, never claim vision) is
/// unit-testable with a stub while the real `NSPasteboard` read lives behind the production conformer.
/// Returns the raw clipboard string (or `nil` when empty/non-text); turning it into a `CaptureResult`
/// is the provider's job, kept out of the platform path so the seam stays trivially fakeable.
public protocol ClipboardReading: Sendable {
    /// The current plain-text contents of the clipboard, or `nil` when it holds no string.
    func readString() -> String?
}

/// Clipboard ground provider: a one-shot `CaptureProviding`. Reading the clipboard is inherently
/// user-triggered (the user already copied the text — that copy IS the consent) and fully local, so it
/// rides the registry's untouched capture seam exactly like a screenshot leg, with NO TCC permission.
/// The platform read lives behind ``ClipboardReading``; this type only shapes the `CaptureResult`
/// (`ground == .clipboard`, copied text in `text`, NO image, so the vision gate never trips).
public struct ClipboardCaptureProvider: CaptureProviding, Sendable {
    private let reader: any ClipboardReading

    public init(reader: any ClipboardReading = ClipboardCaptureProvider.makeProductionReader()) {
        self.reader = reader
    }

    /// Registry arm: scope/quick/encoding are screen-image concepts the clipboard ground ignores. Reads
    /// the copied text and returns it as a text-only `CaptureResult`.
    public func capture(
        scope: CaptureScope,
        quick: Bool,
        encoding: CaptureEncodingParams
    ) async throws -> CaptureResult {
        _ = (scope, quick, encoding)   // image concepts; the clipboard ground ignores all three
        let text = reader.readString() ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CaptureError.noContent
        }
        return CaptureResult(
            text: trimmed,
            sourceLabel: "Clipboard",
            screenshotBase64: nil,   // copied text carries no image — keep hasVision false
            ground: .clipboard
        )
    }

    /// The production reader (real `NSPasteboard` on Apple platforms; a clearly-failing stand-in
    /// elsewhere so non-mac builds compile). Wired in `PeeknookDependencies.production()`.
    public static func makeProductionReader() -> any ClipboardReading {
        #if canImport(AppKit)
        return PasteboardClipboardReader()
        #else
        return UnavailableClipboardReader()
        #endif
    }
}

// MARK: - Production read (isolated; the only platform-coupled code)

#if canImport(AppKit)

/// Reads the system clipboard's plain-text contents via `NSPasteboard`. The ONLY platform-coupled type
/// in this ground. No hardware, no permission — but kept behind ``ClipboardReading`` so the provider
/// policy above is covered by stub-driven tests rather than depending on a live pasteboard.
struct PasteboardClipboardReader: ClipboardReading {
    func readString() -> String? {
        NSPasteboard.general.string(forType: .string)
    }
}

#endif

/// Stand-in for platforms without AppKit (so the package compiles everywhere). Always returns `nil` —
/// the ground simply has no clipboard to read on those targets, so the provider throws `.noContent`.
struct UnavailableClipboardReader: ClipboardReading {
    func readString() -> String? { nil }
}

// MARK: - Test-only stub

/// Deterministic clipboard double for unit tests and the UI test host. Returns a scripted string (or
/// `nil`) without touching the system pasteboard, mirroring ``StubSystemAudioTranscriber``.
public struct StubClipboardReader: ClipboardReading {
    public var scriptedString: String?

    public init(scriptedString: String? = "Meet at the cafe at 3pm.") {
        self.scriptedString = scriptedString
    }

    public func readString() -> String? { scriptedString }
}
