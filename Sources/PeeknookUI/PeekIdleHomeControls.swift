// SPDX-License-Identifier: Apache-2.0

import AppKit
import NookApp
import PeeknookCore
import SwiftUI

// MARK: - Idle home (greeting only — config lives in the command bar)

struct PeekIdleHomeContent: View {
    @Environment(\.nookResolvedTheme) private var theme
    var orchestrator: SessionOrchestrator
    var onResume: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(PeekPersonalGreeting.headline)
                .font(.system(size: 15, weight: .light))
                .tracking(0.2)
                .foregroundStyle(theme.primaryLabel.opacity(0.92))

            if let resume = resumeSnippet, let onResume {
                Button(action: onResume) {
                    Text(resume)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(theme.secondaryLabel.opacity(0.85))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help("Resume this chat")
                .padding(.top, 2)
            }
        }
    }

    private var resumeSnippet: String? {
        guard orchestrator.hasConversation else { return nil }
        guard let capture = orchestrator.latestAnswerCapture else { return nil }
        guard let answer = orchestrator.conversation.last(where: \.isAssistant),
              case .assistant(let text) = answer.kind else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let snippet = trimmed
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(72)
        return "Last: \(capture.targetLabel) — \"\(snippet)\(trimmed.count > 72 ? "…" : "")\""
    }
}

enum PeekPersonalGreeting {
    static var headline: String {
        let name = firstName
        guard !name.isEmpty else { return timeWord }
        return "\(timeWord), \(name)"
    }

    private static var firstName: String {
        let full = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !full.isEmpty else { return "" }
        return full.split(separator: " ").first.map(String.init) ?? full
    }

    private static var timeWord: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Morning"
        case 12..<17: return "Afternoon"
        case 17..<22: return "Evening"
        default: return "Hey"
        }
    }
}

// MARK: - Idle command bar — preflight (left) + action (right)

struct PeekIdleCommandBar: View {
    var orchestrator: SessionOrchestrator
    var setup: SetupCoordinator
    var settings: PeekSettingsController
    /// Owned by `PeekHomeView` so the confirmation overlay can cover the whole home column,
    /// not just this short command row.
    @Binding var pendingDownload: InferenceModelOption?
    var onCapture: () -> Void
    var onResume: (() -> Void)?
    /// Present when the conversation archive has past chats to browse (persistence on, non-empty).
    var onShowArchive: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    modelMenu
                    depthMenu
                    scopeMenu
                }
            }
            Spacer(minLength: 4)
            if let onShowArchive {
                NookToolbarButton(
                    title: "History",
                    symbol: "clock.arrow.circlepath",
                    help: "Browse and resume past chats"
                ) {
                    onShowArchive()
                }
            }
            if let onResume {
                NookToolbarButton(
                    title: "Resume",
                    symbol: "arrow.uturn.backward",
                    help: "Return to your last answer"
                ) {
                    onResume()
                }
            }
            NookToolbarButton(
                title: "Capture",
                symbol: "camera.viewfinder",
                hotkey: orchestrator.settings.captureHotkey,
                help: "Instant capture from anywhere on your Mac",
                prominent: true,
                action: onCapture
            )
            .disabled(!setup.isReady)
        }
    }

    private var modelMenu: some View {
        ValueDropdownPill(
            symbol: "cpu",
            title: TextModelCatalog.displayName(for: orchestrator.settings.textModel),
            help: "Vision model for the next capture"
        ) { close in
            PeekPreflightMenuContent.visionModelHomeMenu(
                currentTag: orchestrator.settings.textModel,
                isInstalled: { setup.isModelInstalled($0) },
                onSelect: selectModel,
                close: close
            )
        }
    }

    private var depthMenu: some View {
        let depth = AnswerDepth(quickMode: orchestrator.settings.quickMode)
        return ValueDropdownPill(
            symbol: depth == .quick ? "hare" : "tortoise",
            title: depth.barLabel,
            help: "Answer depth for the next capture"
        ) { close in
            PeekPreflightMenuContent.answerDepthHomeMenu(
                current: depth,
                onSelect: { settings.setQuickMode($0) },
                close: close
            )
        }
    }

    private var scopeMenu: some View {
        let scope = orchestrator.settings.captureScope
        return ValueDropdownPill(
            symbol: scope == .window ? "macwindow" : "display",
            title: scope.barLabel,
            help: "Capture target for the next capture"
        ) { close in
            PeekPreflightMenuContent.captureScopeHomeMenu(
                current: scope,
                onSelect: { settings.setCaptureScope($0) },
                close: close
            )
        }
    }

    private func selectModel(_ option: InferenceModelOption) {
        switch settings.pickModel(option) {
        case .selected:
            break
        case .needsDownload(let pending):
            pendingDownload = pending
        }
    }
}
