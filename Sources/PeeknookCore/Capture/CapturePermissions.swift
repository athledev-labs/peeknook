// SPDX-License-Identifier: Apache-2.0

import ApplicationServices
import CoreGraphics
import Foundation
#if canImport(AppKit)
import AppKit
#endif

public struct CapturePermissionStatus: Sendable, Equatable {
    public var accessibilityTrusted: Bool
    public var screenRecordingGranted: Bool

    public var canCapture: Bool {
        accessibilityTrusted || screenRecordingGranted
    }

    public static func current() -> CapturePermissionStatus {
        CapturePermissionStatus(
            accessibilityTrusted: AXIsProcessTrusted(),
            screenRecordingGranted: CGPreflightScreenCaptureAccess()
        )
    }

    /// Opens the Accessibility pane and prompts if not yet trusted.
    @MainActor
    public static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        openPrivacySettings(anchor: "Privacy_Accessibility")
    }

    /// Triggers the Screen Recording consent flow when possible.
    @MainActor
    public static func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        openPrivacySettings(anchor: "Privacy_ScreenCapture")
    }

    @MainActor
    public static func openPrivacySettings(anchor: String) {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        guard let url = URL(string: urlString) else { return }
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }
}
