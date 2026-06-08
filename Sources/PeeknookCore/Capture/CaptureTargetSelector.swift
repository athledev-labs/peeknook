// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Foundation

/// A candidate window for capture, decoupled from ScreenCaptureKit so the selection logic
/// can be unit-tested with multi-monitor fixtures. `MacCaptureProvider` maps `SCWindow` into
/// this and the chosen descriptor back to its `SCWindow` for the screenshot I/O.
public struct CaptureWindowDescriptor: Sendable, Equatable {
    public var windowID: CGWindowID
    public var frame: CGRect
    public var ownerPID: pid_t
    public var layer: Int
    public var appName: String?
    public var title: String?

    public init(
        windowID: CGWindowID,
        frame: CGRect,
        ownerPID: pid_t,
        layer: Int,
        appName: String? = nil,
        title: String? = nil
    ) {
        self.windowID = windowID
        self.frame = frame
        self.ownerPID = ownerPID
        self.layer = layer
        self.appName = appName
        self.title = title
    }
}

/// A candidate display for full-screen capture, in the same global (top-left origin) coordinate
/// space as the cursor and window frames.
public struct CaptureDisplayDescriptor: Sendable, Equatable {
    public var displayID: CGDirectDisplayID
    public var frame: CGRect

    public init(displayID: CGDirectDisplayID, frame: CGRect) {
        self.displayID = displayID
        self.frame = frame
    }
}

/// Pure window/display selection. No ScreenCaptureKit, no I/O, so it can be exercised directly
/// with fixtures. The provider does the ScreenCaptureKit mapping and the screenshot calls.
public enum CaptureTargetSelector: Sendable {
    /// Window to capture, multi-monitor aware, in priority order:
    /// 1. the window directly **under the cursor** (what the user is pointing at, fixes
    ///    "it grabbed the wrong screen" when the focused app lives on another display),
    /// 2. else the frontmost app's largest window,
    /// 3. else the largest window anywhere.
    ///
    /// `windows` is front-to-back (the first hit under the cursor is the topmost there).
    public static func selectWindow(
        windows: [CaptureWindowDescriptor],
        cursor: CGPoint?,
        ownerPID: pid_t,
        frontmostPID: pid_t?
    ) -> CaptureWindowDescriptor? {
        // Real, on-screen app window that isn't our own notch HUD.
        func usable(_ window: CaptureWindowDescriptor) -> Bool {
            window.ownerPID != ownerPID
                && window.layer == 0
                && window.frame.width > 80 && window.frame.height > 80
        }

        // Cursor + frame share the global top-left coordinate space.
        if let cursor,
           let under = windows.first(where: { usable($0) && $0.frame.contains(cursor) }) {
            return under
        }

        if let frontmostPID,
           let largestFront = windows
               .filter({ usable($0) && $0.ownerPID == frontmostPID })
               .max(by: { area($0.frame) < area($1.frame) }) {
            return largestFront
        }

        return windows
            .filter(usable)
            .max(by: { area($0.frame) < area($1.frame) })
    }

    /// The display the cursor is on (else the first/main display).
    public static func selectDisplay(
        displays: [CaptureDisplayDescriptor],
        cursor: CGPoint?
    ) -> CaptureDisplayDescriptor? {
        if let cursor, let hit = displays.first(where: { $0.frame.contains(cursor) }) {
            return hit
        }
        return displays.first
    }

    static func area(_ rect: CGRect) -> CGFloat { rect.width * rect.height }
}
