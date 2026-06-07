// SPDX-License-Identifier: Apache-2.0

import AppKit
import NookApp
import PeeknookCore
import SwiftUI

// MARK: - Idle home: greeting only. Thread actions live in the command bar.

struct PeekIdleHomeContent: View {
    @Environment(\.nookResolvedTheme) private var theme
    var settings: PeeknookSettings

    var body: some View {
        if settings.showGreeting {
            Text(PeekPersonalGreeting.headline(settings: settings))
                .font(.system(size: 15, weight: .light))
                .tracking(0.2)
                .foregroundStyle(theme.primaryLabel.opacity(0.92))
        }
    }
}

enum PeekPersonalGreeting {
    static func headline(settings: PeeknookSettings) -> String {
        let name = resolvedName(settings: settings)
        guard !name.isEmpty else { return timeWord }
        return "\(timeWord), \(name)"
    }

    private static func resolvedName(settings: PeeknookSettings) -> String {
        let custom = settings.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard custom.isEmpty else { return custom }
        return systemFirstName
    }

    private static var systemFirstName: String {
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

// MARK: - Idle command bar: thread actions + preflight (left) · Capture (right)

struct PeekIdleCommandBar: View {
    var orchestrator: SessionOrchestrator
    var setup: SetupCoordinator
    var settings: PeekSettingsController
    @Binding var pendingDownload: InferenceModelOption?
    var onBrowseModels: () -> Void
    var onCapture: () -> Void
    var onResume: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if let preview = IdleResumePreview.from(orchestrator) {
                PeekResumeButton(preview: preview, onResume: onResume)
            }
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
                onBrowseModels: onBrowseModels,
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

/// Resume control, preview on hover via popover so the main panel never resizes (in-flow
/// expansion fights OpenNook's hover dismiss and causes a stutter loop).
private struct PeekResumeButton: View {
    @Environment(\.nookResolvedTheme) private var theme
    let preview: IdleResumePreview.Content
    let onResume: () -> Void

    @State private var isButtonHovered = false
    @State private var isPreviewHovered = false
    @State private var showsPreview = false
    @State private var hideTask: Task<Void, Never>?

    private var isPreviewVisible: Bool {
        isButtonHovered || isPreviewHovered
    }

    var body: some View {
        NookToolbarButton(
            title: "Resume",
            symbol: "arrow.uturn.backward",
            help: "\(preview.source). \(preview.answer)",
            onHoverChange: { hovering in
                isButtonHovered = hovering
                syncPreviewVisibility()
            },
            action: onResume
        )
        .popover(isPresented: $showsPreview, arrowEdge: .top) {
            previewBody
                .onHover { isPreviewHovered = $0; syncPreviewVisibility() }
        }
        .nookKeepsExpanded(while: $showsPreview)
        .onDisappear { hideTask?.cancel() }
    }

    private var previewBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(preview.source)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.secondaryLabel)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(preview.answer)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(theme.primaryLabel.opacity(0.92))
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(width: 340, alignment: .leading)
    }

    private func syncPreviewVisibility() {
        hideTask?.cancel()
        if isPreviewVisible {
            showsPreview = true
        } else {
            hideTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled, !isPreviewVisible else { return }
                showsPreview = false
            }
        }
    }
}

enum IdleResumePreview {
    struct Content: Equatable {
        var source: String
        var answer: String
    }

    @MainActor
    static func from(_ orchestrator: SessionOrchestrator) -> Content? {
        guard orchestrator.hasConversation else { return nil }
        guard let answer = orchestrator.conversation.last(where: \.isAssistant),
              case .assistant(let text) = answer.kind else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let source = orchestrator.latestAnswerCapture?.targetLabel
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Content(
            source: source.flatMap { $0.isEmpty ? nil : $0 } ?? "Last chat",
            answer: trimmed
        )
    }
}
