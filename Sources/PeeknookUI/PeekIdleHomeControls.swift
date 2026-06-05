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
    var moduleDefaults: UserDefaults
    var onCapture: () -> Void
    var onResume: (() -> Void)?
    var onOpenSetup: () -> Void

    @State private var pendingDownload: InferenceModelOption?

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
        .confirmationDialog(
            downloadConfirmationTitle,
            isPresented: downloadConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Download") {
                if let pendingDownload {
                    beginModelDownload(pendingDownload)
                }
                pendingDownload = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDownload = nil
            }
        } message: {
            if let pendingDownload {
                Text(downloadConfirmationMessage(for: pendingDownload))
            }
        }
    }

    private var downloadConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingDownload != nil },
            set: { if !$0 { pendingDownload = nil } }
        )
    }

    private var downloadConfirmationTitle: String {
        guard let pendingDownload else { return "Download model?" }
        return "Download \(pendingDownload.displayName)?"
    }

    private func downloadConfirmationMessage(for option: InferenceModelOption) -> String {
        let size = option.downloadHint ?? "a large download"
        return "\(size) via Ollama. Peek won't capture until this model is on your Mac."
    }

    private var modelMenu: some View {
        ValueDropdownPill(
            symbol: "cpu",
            title: TextModelCatalog.displayName(for: orchestrator.settings.textModel),
            help: "Vision model for the next capture"
        ) { close in
            ForEach(TextModelCatalog.offered) { option in
                Button {
                    selectModel(option)
                    close()
                } label: {
                    ValueMenuRow(
                        title: option.displayName,
                        selected: isSelectedModel(option),
                        needsDownload: !setup.isModelInstalled(option.tag)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var depthMenu: some View {
        let depth = AnswerDepth(quickMode: orchestrator.settings.quickMode)
        return ValueDropdownPill(
            symbol: depth == .quick ? "hare" : "tortoise",
            title: depth.barLabel,
            help: "Answer depth for the next capture"
        ) { close in
            ForEach(AnswerDepth.allCases, id: \.rawValue) { option in
                Button {
                    setQuickMode(option.quickMode)
                    close()
                } label: {
                    ValueMenuRow(
                        title: option.barLabel,
                        selected: depth == option
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var scopeMenu: some View {
        let scope = orchestrator.settings.captureScope
        return ValueDropdownPill(
            symbol: scope == .window ? "macwindow" : "display",
            title: scope.barLabel,
            help: "Capture target for the next capture"
        ) { close in
            ForEach(CaptureScope.allCases) { option in
                Button {
                    setCaptureScope(option)
                    close()
                } label: {
                    ValueMenuRow(
                        title: option.barLabel,
                        selected: scope == option
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func isSelectedModel(_ option: InferenceModelOption) -> Bool {
        OllamaSetupClient.matchesModel(
            installedNames: [orchestrator.settings.textModel],
            wanted: option.tag
        )
    }

    private func selectModel(_ option: InferenceModelOption) {
        if setup.isModelInstalled(option.tag) {
            setup.selectTextModel(option.tag)
            return
        }
        pendingDownload = option
    }

    private func beginModelDownload(_ option: InferenceModelOption) {
        setup.settings.textModel = option.tag
        setup.persistSettings()
        orchestrator.settings.textModel = option.tag
        orchestrator.persistSettings(to: moduleDefaults)
        setup.pullRecommendedModel()
        onOpenSetup()
    }

    private func setQuickMode(_ quick: Bool) {
        guard orchestrator.settings.quickMode != quick else { return }
        updateSetting { $0.quickMode = quick }
    }

    private func setCaptureScope(_ scope: CaptureScope) {
        guard orchestrator.settings.captureScope != scope else { return }
        updateSetting { $0.captureScope = scope }
    }

    private func updateSetting(_ mutate: (inout PeeknookSettings) -> Void) {
        mutate(&orchestrator.settings)
        orchestrator.persistSettings(to: moduleDefaults)
        setup.settings = orchestrator.settings
        setup.persistSettings()
    }
}
