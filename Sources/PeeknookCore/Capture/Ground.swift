// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A perception surface the user can capture from. `screen` is the only shipped ground today;
/// `camera` lands with camera v1, `agent` is reserved for the Phase 5 sidecar. The enum is completed
/// at endgame shape so adding a ground is a value, not a schema migration.
public enum Ground: String, Codable, Sendable, CaseIterable, Hashable {
    case screen
    case camera
    case selectedText
    case voiceInput
    case agent

    /// Permissions that must be granted before this ground can capture. Drives the per-profile
    /// readiness matrix. `selectedText` deliberately returns an empty set: Accessibility is a
    /// *supplement* the capture provider requests opportunistically (it skips secure fields and
    /// degrades silently), never a hard gate — so it must not appear in a profile's
    /// `requiredPermissions`. `agent` (sidecar) gates on nothing here.
    public var requiredPermissions: Set<CapturePermission> {
        switch self {
        case .screen:       return [.screenRecording]
        case .camera:       return [.camera]
        case .voiceInput:   return [.microphone, .speechRecognition]
        case .selectedText: return []
        case .agent:        return []
        }
    }
}

/// A macOS TCC permission a ground may require. Completed at endgame shape so the readiness matrix
/// can reason about every ground without per-ground special-casing. `accessibility` exists for the
/// matrix even though no shipped ground hard-requires it (AX is supplementary — see
/// ``Ground/requiredPermissions``).
public enum CapturePermission: String, Codable, Sendable, CaseIterable, Hashable {
    case screenRecording
    case camera
    case microphone
    case speechRecognition
    case accessibility

    /// Full name for failure copy and the Privacy pane the user must visit. (English key; the UI
    /// localizes via `Text(peek:)`.)
    public var displayName: String {
        switch self {
        case .screenRecording:  return "Screen Recording"
        case .camera:           return "Camera"
        case .microphone:       return "Microphone"
        case .speechRecognition: return "Speech Recognition"
        case .accessibility:    return "Accessibility"
        }
    }

    /// Short label for the setup checklist chip. `.screenRecording` keeps the existing "Recording"
    /// wording so the screen-default checklist is visually unchanged.
    public var setupChipTitle: String {
        switch self {
        case .screenRecording:  return "Recording"
        case .camera:           return "Camera"
        case .microphone:       return "Microphone"
        case .speechRecognition: return "Speech"
        case .accessibility:    return "Accessibility"
        }
    }
}

/// One required permission and its live granted state, for the profile-conditional setup checklist.
public struct PermissionRequirement: Sendable, Equatable, Identifiable {
    public let permission: CapturePermission
    public let isGranted: Bool
    public var id: CapturePermission { permission }

    public init(permission: CapturePermission, isGranted: Bool) {
        self.permission = permission
        self.isGranted = isGranted
    }
}
