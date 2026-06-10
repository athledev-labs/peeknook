// SPDX-License-Identifier: Apache-2.0

import AppKit
import ApplicationServices
import Foundation
import ScreenCaptureKit

/// Capture: **screenshot for vision** (window under cursor or whole display) + optional
/// selected text (Accessibility).
public struct MacCaptureProvider: CaptureProviding, Sendable {
    public init() {}

    public func capture(
        scope: CaptureScope,
        quick: Bool,
        encoding: CaptureEncodingParams
    ) async throws -> CaptureResult {
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureError.permissionRequired("Screen Recording")
        }

        let target = try await Self.captureTarget(scope: scope)

        // Vision is the product. Fail loud rather than silently shipping a text-only
        // capture that the UI would still label "vision".
        guard let screenshotBase64 = CaptureImageEncoder.jpegBase64(
            from: target.image,
            maxPixel: encoding.maxPixel,
            quality: encoding.jpegQuality
        ),
              !screenshotBase64.isEmpty else {
            let noun = scope == .display ? "screen" : "window"
            throw CaptureError.failed("Captured the \(noun) but couldn't encode the screenshot. Try again.")
        }

        // Gemma 4 reads the screenshot directly. The only text worth adding is the user's
        // *exact* selection (Accessibility), full-frame OCR just produced noisy fragments
        // that cluttered the preview and misled the model, so it's gone.
        let selected = await MainActor.run { Self.captureSelectedText() }

        let base = scope == .display ? "Whole screen (vision)" : "Front window (vision)"
        let label = selected != nil ? "Vision + selected text" : base

        return CaptureResult(
            text: selected,
            sourceLabel: label,
            appName: target.appName,
            windowTitle: target.windowTitle,
            screenshotBase64: screenshotBase64
        )
    }

    // MARK: - Accessibility

    @MainActor
    private static func captureSelectedText() -> String? {
        guard AXIsProcessTrusted() else { return nil }

        let system = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
            let focusedValue,
            CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
        else { return nil }

        let focused = focusedValue as! AXUIElement

        if isSecureAccessibilityElement(focused) { return nil }

        if let selected = copyAttributeString(focused, kAXSelectedTextAttribute as CFString),
           !selected.isEmpty {
            return selected
        }

        // Skip reading focused field values — passwords and tokens live here without selection.
        return nil
    }

    @MainActor
    private static func isSecureAccessibilityElement(_ element: AXUIElement) -> Bool {
        let subrole = copyAttributeString(element, kAXSubroleAttribute as CFString)
        let roleDescription = copyAttributeString(element, kAXRoleDescriptionAttribute as CFString)
        return CaptureAccessibilityPolicy.shouldSkipAccessibilityText(
            subrole: subrole,
            roleDescription: roleDescription
        )
    }

    @MainActor
    private static func copyAttributeString(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              let string = value as? String
        else { return nil }
        return string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - ScreenCaptureKit

    /// What the model will see, plus its identity for the preview trust line.
    private struct CaptureTarget {
        let image: CGImage
        let appName: String?
        let windowTitle: String?
    }

    private static func captureTarget(scope: CaptureScope) async throws -> CaptureTarget {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let cursor = Self.cursorLocation()
        switch scope {
        case .window:
            return try await Self.windowTarget(content: content, cursor: cursor)
        case .display:
            return try await Self.displayTarget(content: content, cursor: cursor)
        }
    }

    /// Window to capture, multi-monitor aware, in priority order:
    /// 1. the window directly **under the cursor** (what the user is pointing at, fixes
    ///    "it grabbed the wrong screen" when the focused app lives on another display),
    /// 2. else the frontmost app's largest window,
    /// 3. else the largest window anywhere.
    private static func windowTarget(content: SCShareableContent, cursor: CGPoint?) async throws -> CaptureTarget {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frontPID = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        }

        // Pure selection over plain descriptors (front-to-back order preserved); map the chosen
        // descriptor back to its SCWindow for the screenshot I/O below.
        let descriptors = content.windows.map(Self.descriptor(for:))
        guard let chosen = CaptureTargetSelector.selectWindow(
            windows: descriptors,
            cursor: cursor,
            ownerPID: ownPID,
            frontmostPID: frontPID
        ),
            let window = content.windows.first(where: { $0.windowID == chosen.windowID }) else {
            throw CaptureError.failed("No capturable window under the cursor or front app. Click the window you want, then try again.")
        }
        return try await Self.screenshot(of: window)
    }

    /// The whole display the cursor is on (else the first/main display).
    private static func displayTarget(content: SCShareableContent, cursor: CGPoint?) async throws -> CaptureTarget {
        let displays = content.displays
        let descriptors = displays.map { CaptureDisplayDescriptor(displayID: $0.displayID, frame: $0.frame) }
        guard let chosen = CaptureTargetSelector.selectDisplay(displays: descriptors, cursor: cursor),
              let display = displays.first(where: { $0.displayID == chosen.displayID }) else {
            throw CaptureError.failed("No display available to capture.")
        }

        // Capture everything on the display (windows + desktop) EXCEPT our own notch HUD,
        // which is on screen during capture and must not appear in the shot.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == ownPID }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        let config = SCStreamConfiguration()
        config.width = min(display.width * 2, 3200)
        config.height = min(display.height * 2, 2000)
        config.scalesToFit = true
        config.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let label = displays.count > 1
            ? "Display \((displays.firstIndex(where: { $0.displayID == display.displayID }) ?? 0) + 1)"
            : nil
        return CaptureTarget(image: image, appName: "Whole screen", windowTitle: label)
    }

    /// Cursor position in the same global display space `SCWindow.frame` uses (top-left origin).
    private static func cursorLocation() -> CGPoint? {
        CGEvent(source: nil)?.location
    }

    /// Plain, testable view of an `SCWindow` for `CaptureTargetSelector`.
    private static func descriptor(for window: SCWindow) -> CaptureWindowDescriptor {
        CaptureWindowDescriptor(
            windowID: window.windowID,
            frame: window.frame,
            ownerPID: window.owningApplication?.processID ?? -1,
            layer: window.windowLayer,
            appName: window.owningApplication?.applicationName,
            title: window.title
        )
    }

    private static func screenshot(of window: SCWindow) async throws -> CaptureTarget {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = min(Int(window.frame.width) * 2, 1920)
        config.height = min(Int(window.frame.height) * 2, 1200)
        config.scalesToFit = true
        config.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return CaptureTarget(
            image: image,
            appName: window.owningApplication?.applicationName,
            windowTitle: window.title
        )
    }
}
