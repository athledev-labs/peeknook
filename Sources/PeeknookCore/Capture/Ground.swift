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
    /// A PDF/image the user opens from disk. Event-scoped (a command, never an active profile — a
    /// file-primary profile would dead-end ⌘⇧P the way a camera-primary one would). The open panel
    /// grants file access, so it requires no TCC permission.
    case file
    /// What is currently playing through the Mac (meeting, video, call) — heard via a SHORT,
    /// user-triggered ScreenCaptureKit system-audio window and transcribed on-device. Distinct from
    /// `voiceInput` (the user's microphone dictation): this ground hears the *screen's* output, not
    /// the user's voice. Produces a TEXT leg (the transcript), never an image.
    case systemAudio
    /// Text the user has copied to the clipboard. Inherently user-triggered (the copy is the consent)
    /// and fully local, so it requires no TCC permission. Produces a TEXT leg, never an image.
    case clipboard
    /// A structured, fully-local outline of the focused window's accessibility subtree (roles, labels,
    /// values, hierarchy) — read on a user trigger via the macOS accessibility API, NOT a screenshot.
    /// Secure/password fields keep their structure but drop their value, and any leftover secret in a
    /// plain value is redacted. Produces a TEXT leg, never an image. Off by default; gated on the
    /// `accessibilityTreeEnabled` opt-in at capture time.
    case accessibilityTree

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
        // ScreenCaptureKit system-audio capture needs Screen Recording; on-device transcription needs
        // Speech Recognition. No Microphone — this ground never opens the mic input.
        case .systemAudio:  return [.screenRecording, .speechRecognition]
        case .selectedText: return []
        case .agent:        return []
        case .file:         return []   // the open panel grants file access; no TCC gate
        case .clipboard:    return []   // the user's copy is the consent; no TCC gate
        // Reading the focused window's AX subtree is a hard Accessibility gate (the provider also
        // checks `AXIsProcessTrusted` at capture time). Unlike `selectedText`'s opportunistic AX
        // supplement, this ground's whole content IS the AX tree, so the permission is required.
        case .accessibilityTree: return [.accessibility]
        }
    }

    /// The grounds a multi-ground profile may hold — the ones the ⌘⇧P fan-out can one-shot capture
    /// and fold into a single question. `.camera`/`.file` are interactive (live preview / open panel)
    /// and drive their own flows, so the fan-out already excludes them; `.voiceInput` is the user's
    /// dictation (not a screen ground) and `.agent` is the reserved sidecar — neither is a capture leg.
    /// The profile editor offers only this set, and ``ProfileStore/setActiveGrounds(_:for:)`` sanitizes
    /// against it regardless of what a caller passes.
    public static let multiGroundEligible: Set<Ground> = [.screen, .selectedText, .systemAudio, .clipboard, .accessibilityTree]

    /// The grounds that contribute a TEXT leg rather than an image — an audio transcript or copied
    /// clipboard text. The single source of truth for "is this a text leg?", shared by the fan-out's
    /// modality resolution (``MediaPayload/Kind/resolved(for:)``) and the prompt builder's labelling,
    /// so the two can never disagree about whether a leg carries an image.
    public static let textOnlyLegs: Set<Ground> = [.systemAudio, .clipboard, .accessibilityTree]

    /// Intentional rank for ordering the non-primary legs of a multi-ground fan-out (lower captures
    /// first). The primary ground always leads regardless of rank; this only sequences the rest, so
    /// the leg order — and therefore the prompt's "Image 1, Image 2…" numbering downstream in
    /// ``PromptBuilder`` — is a deliberate choice, NOT a side effect of the `case` declaration order.
    /// Reordering the enum no longer reorders capture. Visual grounds (screen) lead, then the
    /// supplementary text leg (selectedText), then the transcript leg (systemAudio); the non-fan-out
    /// grounds keep ranks too so the rank is total and adding a ground stays a value, not a migration.
    public var captureLegOrder: Int {
        switch self {
        case .screen:       return 0
        case .camera:       return 1
        case .selectedText: return 2
        case .file:         return 3
        case .systemAudio:  return 4
        case .clipboard:    return 5
        case .accessibilityTree: return 6
        case .voiceInput:   return 7
        case .agent:        return 8
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
