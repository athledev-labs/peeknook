// SPDX-License-Identifier: Apache-2.0

import PeeknookCore
import PeeknookDesign
import SwiftUI

struct PeekSettingsCaptureSection: View {
    var orchestrator: SessionOrchestrator
    var setup: SetupCoordinator
    var settings: PeekSettingsController
    var onCaptureHotkeyChange: ((CaptureHotkey) -> Void)?
    var onBriefHotkeyChange: ((CaptureHotkey) -> Void)?
    var onCameraHotkeyChange: ((CaptureHotkey) -> Void)?

    @EnvironmentObject private var appState: AppState

    // Reading capture-permission TCC (CGPreflightScreenCaptureAccess et al.) is a syscall sweep, and
    // this section re-renders on every settings/probe change while the panel is open. Snapshot the
    // rows into @State and refresh them only on the 2s poll below, keeping the syscalls off the
    // render path so the open animation stays smooth.
    @State private var permissionRequirements: [PermissionRequirement] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PeekSettingsFormField(
                icon: "person.crop.circle",
                title: "Display name",
                text: displayNameBinding,
                placeholder: "Nickname (optional)"
            )
            PeekSettingsNote(text: "Used in the idle greeting on this Mac. Leave blank to use your account name.")

            PeekSettingsToggleRow(
                icon: orchestrator.settings.showGreeting ? "sun.horizon.fill" : "sun.horizon",
                title: "Show greeting",
                detail: "Morning/Afternoon headline on the idle home screen",
                testIdentifier: PeekTestID.showGreeting,
                isOn: showGreetingBinding
            )

            PeekShortcutRow.capture(hotkey: orchestrator.settings.captureHotkey) { newHotkey in
                settings.setCaptureHotkey(newHotkey)
                onCaptureHotkeyChange?(newHotkey)
            }

            PeekShortcutRow.brief(hotkey: orchestrator.settings.briefHotkey) { newHotkey in
                settings.setBriefHotkey(newHotkey)
                onBriefHotkeyChange?(newHotkey)
            }

            PeekShortcutRow.camera(hotkey: orchestrator.settings.cameraHotkey) { newHotkey in
                settings.setCameraHotkey(newHotkey)
                onCameraHotkeyChange?(newHotkey)
            }

            if !setup.skipsLiveProbes {
                permissionRows
            }

            captureScopeRow
            answerDepthRow
            captureQualityRow
            inferenceImageReplayRow

            PeekSettingsToggleRow(
                icon: orchestrator.settings.renderAnswerMarkdown ? "textformat" : "textformat.alt",
                title: "Render markdown in answers",
                detail: "Bold, code, and other inline formatting in answer text",
                isOn: renderAnswerMarkdownBinding
            )

            if PracticeMode.shipped.count > 1 {
                // Reserved for a future distinct practice mode, not exposed while only General ships.
            }

            PeekSettingsToggleRow(
                icon: orchestrator.settings.previewBeforeInfer ? "eye.fill" : "eye",
                title: "Confirm before analyzing",
                detail: "Preview capture target before sending",
                isOn: previewBeforeInferBinding
            )

            PeekSettingsNote(text: "Screenshots capture on-screen pixels. Avoid capturing windows that show passwords, tokens, or other sensitive content.")

            PeekSettingsToggleRow(
                icon: orchestrator.settings.suggestFollowUps ? "text.bubble.fill" : "text.bubble",
                title: "Suggest follow-ups",
                detail: "Propose next questions after each answer",
                isOn: suggestFollowUpsBinding
            )

            PeekSettingsToggleRow(
                icon: orchestrator.settings.webLookupEnabled ? "globe.americas.fill" : "globe",
                title: "Web lookup",
                detail: "Send a DuckDuckGo query from capture context (queries leave this Mac)",
                isOn: webLookupBinding
            )

            PeekSettingsToggleRow(
                icon: orchestrator.settings.persistConversation ? "tray.full.fill" : "tray",
                title: "Save conversations",
                detail: "Archive past chats and screenshots on this Mac (up to 25 chats / ~250 MB). Done keeps a chat; New chat deletes it. Turning this off deletes the whole archive.",
                isOn: persistConversationBinding
            )

            PeekSettingsToggleRow(
                icon: orchestrator.settings.compositeCaptureEnabled ? "photo.on.rectangle.angled" : "rectangle.on.rectangle",
                title: "Screen + camera capture",
                detail: "Adds a command that captures your screen and a camera photo, then asks about both as one question. Needs Camera access.",
                isOn: compositeCaptureBinding
            )

            PeekSettingsToggleRow(
                icon: orchestrator.settings.liveEnabled ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash",
                title: "Live session",
                detail: "Adds a Go live command to an answered chat so it stays armed and keeps context across captures. You stay in control: a clear Live indicator with a Stop, and capture stays user-triggered.",
                isOn: liveEnabledBinding
            )

            if orchestrator.settings.liveEnabled {
                liveRefreshTriggerRow
                if orchestrator.settings.liveRefreshTrigger == .timer {
                    liveTimerIntervalRow
                }
            }
        }
        .task(id: appState.isNookVisible) {
            guard !setup.skipsLiveProbes, appState.isNookVisible else { return }
            while !Task.isCancelled {
                setup.refreshCapturePermission()
                permissionRequirements = capturePermissionRequirements
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    @ViewBuilder
    private var permissionRows: some View {
        ForEach(permissionRequirements) { requirement in
            PeekSettingsCommandRow(
                icon: permissionIcon(requirement.permission),
                title: requirement.permission.displayName,
                subtitle: permissionSubtitle(requirement),
                trailing: requirement.isGranted ? .chevron : .button("Open settings"),
                action: { repairPermission(requirement.permission) }
            )
            .peekAction(
                label: requirement.permission.displayName,
                hint: requirement.isGranted
                    ? PeekLocalized("Allowed in System Settings")
                    : PeekLocalized("Open System Settings to allow this permission")
            )
            .disabled(requirement.isGranted)
        }
    }

    /// Active-profile permissions plus camera (⌘⇧C), deduplicated — camera is event-scoped, not
    /// tied to which profile is active.
    private var capturePermissionRequirements: [PermissionRequirement] {
        var seen = Set<CapturePermission>()
        var rows: [PermissionRequirement] = []
        for requirement in setup.permissionChecklist {
            if seen.insert(requirement.permission).inserted {
                rows.append(requirement)
            }
        }
        for requirement in setup.permissionChecklist(for: .cameraStudy) {
            if seen.insert(requirement.permission).inserted {
                rows.append(requirement)
            }
        }
        return rows
    }

    private func permissionIcon(_ permission: CapturePermission) -> String {
        switch permission {
        case .screenRecording: return "rectangle.inset.filled.and.person.filled"
        case .camera: return "camera.fill"
        case .accessibility: return "accessibility"
        case .microphone: return "mic.fill"
        case .speechRecognition: return "waveform"
        }
    }

    private func permissionSubtitle(_ requirement: PermissionRequirement) -> String {
        if requirement.isGranted {
            return PeekLocalized("Allowed in System Settings")
        }
        switch requirement.permission {
        case .screenRecording:
            return PeekLocalized("Required for screen capture")
        case .camera:
            return PeekLocalized("Required for camera capture")
        default:
            return PeekLocalized("Required for capture")
        }
    }

    private func repairPermission(_ permission: CapturePermission) {
        switch permission.recoveryAction {
        case .openScreenRecordingSettings:
            CapturePermissionStatus.requestScreenRecording()
        case .openAccessibilitySettings:
            CapturePermissionStatus.requestAccessibility()
        case .openCameraSettings:
            CapturePermissionStatus.requestCamera()
        default:
            break
        }
    }

    private var captureScopeRow: some View {
        let scope = orchestrator.settings.captureScope
        return PeekSettingsMenuRow(
            icon: scope.settingsIcon,
            title: "Capture area",
            detail: scope.displayName,
            value: scope.barLabel
        ) { close in
            PeekPreflightMenuContent.captureScopeHomeMenu(
                current: scope,
                onSelect: { settings.setCaptureScope($0) },
                close: close
            )
        }
    }

    private var answerDepthRow: some View {
        let depth = AnswerDepth(quickMode: orchestrator.settings.quickMode)
        return PeekSettingsMenuRow(
            icon: depth.settingsIcon,
            title: "Answer depth",
            detail: depth.menuDetail,
            value: depth.barLabel
        ) { close in
            PeekPreflightMenuContent.answerDepthHomeMenu(
                current: depth,
                onSelect: { settings.setQuickMode($0) },
                close: close
            )
        }
    }

    private var captureQualityRow: some View {
        let quality = orchestrator.settings.captureQuality
        return PeekSettingsMenuRow(
            icon: quality.settingsIcon,
            title: "Capture quality",
            detail: quality.menuDetail,
            value: quality.barLabel
        ) { close in
            PeekPreflightMenuContent.captureQualityHomeMenu(
                current: quality,
                onSelect: { settings.setCaptureQuality($0) },
                close: close
            )
        }
    }

    private var inferenceImageReplayRow: some View {
        let replay = orchestrator.settings.inferenceImageReplay
        return PeekSettingsMenuRow(
            icon: replay.settingsIcon,
            title: "Images sent to model",
            detail: replay.menuDetail,
            value: replay.barLabel
        ) { close in
            PeekPreflightMenuContent.inferenceImageReplayHomeMenu(
                current: replay,
                onSelect: { settings.setInferenceImageReplay($0) },
                close: close
            )
        }
    }

    /// How an armed live session grabs a fresh frame — Manual (only on Refresh) or Timer (fixed interval).
    /// Shown only when the Live session feature is enabled (byte-identical when off, behind the `if`).
    private var liveRefreshTriggerRow: some View {
        let trigger = orchestrator.settings.liveRefreshTrigger
        return PeekSettingsMenuRow(
            icon: "arrow.clockwise",
            title: "Live refresh",
            detail: LiveRefreshLabels.detail(trigger),
            value: LiveRefreshLabels.title(trigger)
        ) { close in
            PeekPreflightMenuContent.liveRefreshTriggerHomeMenu(
                current: trigger,
                onSelect: { settings.setLiveRefreshTrigger($0) },
                close: close
            )
        }
    }

    private var liveTimerIntervalRow: some View {
        let seconds = orchestrator.settings.liveTimerIntervalSeconds
        return PeekSettingsMenuRow(
            icon: "timer",
            title: "Refresh every",
            detail: "How often Live grabs the latest screen",
            value: LiveRefreshLabels.intervalPillLabel(seconds)
        ) { close in
            PeekPreflightMenuContent.liveTimerIntervalHomeMenu(
                current: seconds,
                onSelect: { settings.setLiveTimerInterval($0) },
                close: close
            )
        }
    }

    private var displayNameBinding: Binding<String> {
        Binding(
            get: { orchestrator.settings.displayName },
            set: { settings.setDisplayName($0) }
        )
    }

    private var showGreetingBinding: Binding<Bool> {
        Binding(
            get: { orchestrator.settings.showGreeting },
            set: { settings.setShowGreeting($0) }
        )
    }

    private var renderAnswerMarkdownBinding: Binding<Bool> {
        Binding(
            get: { orchestrator.settings.renderAnswerMarkdown },
            set: { settings.setRenderAnswerMarkdown($0) }
        )
    }

    private var previewBeforeInferBinding: Binding<Bool> {
        Binding(
            get: { orchestrator.settings.previewBeforeInfer },
            set: { settings.setPreviewBeforeInfer($0) }
        )
    }

    private var compositeCaptureBinding: Binding<Bool> {
        Binding(
            get: { orchestrator.settings.compositeCaptureEnabled },
            set: { settings.setCompositeCaptureEnabled($0) }
        )
    }

    private var liveEnabledBinding: Binding<Bool> {
        Binding(
            get: { orchestrator.settings.liveEnabled },
            set: { settings.setLiveEnabled($0) }
        )
    }

    private var suggestFollowUpsBinding: Binding<Bool> {
        Binding(
            get: { orchestrator.settings.suggestFollowUps },
            set: { settings.setSuggestFollowUps($0) }
        )
    }

    private var webLookupBinding: Binding<Bool> {
        Binding(
            get: { orchestrator.settings.webLookupEnabled },
            set: { settings.setWebLookupEnabled($0) }
        )
    }

    private var persistConversationBinding: Binding<Bool> {
        Binding(
            get: { orchestrator.settings.persistConversation },
            set: { settings.setPersistConversation($0) }
        )
    }
}
