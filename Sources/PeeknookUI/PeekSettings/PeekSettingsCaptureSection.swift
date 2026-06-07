// SPDX-License-Identifier: Apache-2.0

import PeeknookCore
import SwiftUI

struct PeekSettingsCaptureSection: View {
    var orchestrator: SessionOrchestrator
    var settings: PeekSettingsController
    var onCaptureHotkeyChange: ((CaptureHotkey) -> Void)?

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
                isOn: showGreetingBinding
            )

            PeekCaptureShortcutRow(hotkey: orchestrator.settings.captureHotkey) { newHotkey in
                settings.setCaptureHotkey(newHotkey)
                onCaptureHotkeyChange?(newHotkey)
            }

            captureScopeRow
            answerDepthRow

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

            PeekSettingsToggleRow(
                icon: orchestrator.settings.suggestFollowUps ? "text.bubble.fill" : "text.bubble",
                title: "Suggest follow-ups",
                detail: "Propose next questions after each answer",
                isOn: suggestFollowUpsBinding
            )

            PeekSettingsToggleRow(
                icon: orchestrator.settings.webLookupEnabled ? "globe.americas.fill" : "globe",
                title: "Web lookup",
                detail: "Search the web from capture context and show results with the answer",
                isOn: webLookupBinding
            )

            PeekSettingsToggleRow(
                icon: orchestrator.settings.persistConversation ? "tray.full.fill" : "tray",
                title: "Save conversations",
                detail: "Archive past chats and their screenshots on this Mac. Turning this off deletes the archive.",
                isOn: persistConversationBinding
            )
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
