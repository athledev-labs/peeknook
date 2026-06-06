// SPDX-License-Identifier: Apache-2.0

import PeeknookCore
import SwiftUI

struct PeekSettingsCaptureSection: View {
    var orchestrator: SessionOrchestrator
    var settings: PeekSettingsController
    var onCaptureHotkeyChange: ((CaptureHotkey) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PeekCaptureShortcutRow(hotkey: orchestrator.settings.captureHotkey) { newHotkey in
                settings.setCaptureHotkey(newHotkey)
                onCaptureHotkeyChange?(newHotkey)
            }

            captureScopeRow
            answerDepthRow

            if PracticeMode.shipped.count > 1 {
                // Reserved for a future distinct practice mode — not exposed while only General ships.
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

    private var persistConversationBinding: Binding<Bool> {
        Binding(
            get: { orchestrator.settings.persistConversation },
            set: { settings.setPersistConversation($0) }
        )
    }
}
