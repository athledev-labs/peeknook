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
    @State private var isResumeHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(PeekPersonalGreeting.headline)
                .font(.system(size: 15, weight: .light))
                .tracking(0.2)
                .foregroundStyle(theme.primaryLabel.opacity(0.92))

            if let resume = resumeSnippet, let onResume {
                resumeCard(resume, action: onResume)
            }
        }
    }

    private func resumeCard(_ snippet: ResumeSnippet, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(theme.accent)
                    .peekDecorative()
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text("Resume last chat")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(theme.secondaryLabel)
                        Text("·")
                            .foregroundStyle(theme.quaternaryLabel)
                        Text(snippet.source)
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(theme.tertiaryLabel)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text(snippet.preview)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(theme.tertiaryLabel.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.tertiaryLabel)
                    .peekDecorative()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .peekGlass(cornerRadius: 9, isHovered: isResumeHovered)
        }
        .buttonStyle(.plain)
        .onHover { isResumeHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isResumeHovered)
        .help("Resume your last chat")
        .peekAction(label: "Resume last chat from \(snippet.source)", hint: snippet.preview)
    }

    private struct ResumeSnippet {
        var source: String
        var preview: String
    }

    private var resumeSnippet: ResumeSnippet? {
        guard orchestrator.hasConversation else { return nil }
        guard let capture = orchestrator.latestAnswerCapture else { return nil }
        guard let answer = orchestrator.conversation.last(where: \.isAssistant),
              case .assistant(let text) = answer.kind else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let preview = trimmed
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(80)
        return ResumeSnippet(
            source: capture.targetLabel,
            preview: "“\(preview)\(trimmed.count > 80 ? "…" : "")”"
        )
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
    /// Owned by `PeekHomeView` so the add-model overlay can cover the whole home column.
    @Binding var showAddModel: Bool
    var onCapture: () -> Void

    var body: some View {
        // Bottom bar = contextual, per-next-capture config (model / depth / scope) in one scroll;
        // the primary Capture action stays pinned on the right so it (and its hotkey) is always
        // visible. Global actions like "Past chats" live in the top bar (PeekGlobalTopBarItems),
        // not here. Resume lives in the greeting card above, so it isn't duplicated here.
        HStack(alignment: .center, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    modelMenu
                    depthMenu
                    scopeMenu
                }
                .padding(.trailing, 2)
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
            .fixedSize()
        }
    }

    private var modelMenu: some View {
        ValueDropdownPill(
            symbol: "cpu",
            title: TextModelCatalog.displayName(for: orchestrator.settings.textModel, custom: settings.customModels),
            help: "Vision model for the next capture"
        ) { close in
            PeekPreflightMenuContent.visionModelHomeMenu(
                currentTag: orchestrator.settings.textModel,
                models: settings.availableModels,
                isInstalled: { setup.isModelInstalled($0) },
                onSelect: selectModel,
                onAddCustom: { showAddModel = true },
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
