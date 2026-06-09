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

    /// Real capture requires Screen Recording (``MacCaptureProvider`` preflights it). Accessibility
    /// is only a supplement (selected text) and is never sufficient on its own — so this is Screen
    /// Recording alone, not an OR with Accessibility.
    public var canCapture: Bool {
        screenRecordingGranted
    }

    /// Whether a specific permission is granted, for the per-profile readiness matrix. Camera /
    /// Microphone / Speech Recognition are not tracked here yet (they land with their grounds in the
    /// camera PR) and report `false` for now — no shipped profile requires them.
    public func grants(_ permission: CapturePermission) -> Bool {
        switch permission {
        case .screenRecording:  return screenRecordingGranted
        case .accessibility:    return accessibilityTrusted
        case .camera, .microphone, .speechRecognition: return false
        }
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
