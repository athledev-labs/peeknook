// SPDX-License-Identifier: Apache-2.0

import AppKit
import NookApp
import PeeknookCore
import SwiftUI

private enum PeekSettingsSection {
    static let setup = "Setup"
    static let capture = "Capture"
    static let visionModel = "Vision model"
    static let usage = "Usage"
    static let about = "About"
}

public struct PeekSettingsView: View {
    public var orchestrator: SessionOrchestrator
    public var setup: SetupCoordinator
    public var usage: UsageStore
    public var moduleDefaults: UserDefaults
    public var onCaptureHotkeyChange: ((CaptureHotkey) -> Void)?

    @Environment(\.nookResolvedTheme) private var theme
    @Environment(\.nookContentInsets) private var contentInsets
    @EnvironmentObject private var appState: AppState
    @State private var ollamaStatusLabel = "Checking"
    @State private var ollamaStatusDetail: String?
    @State private var ollamaStatusTone: PeekSettingsStatusTone = .loading
    @State private var expandedSections: Set<String> = [PeekSettingsSection.capture]
    @State private var didApplyDefaultExpansion = false
    @State private var visionModelAdvancedExpanded = false
    @State private var pendingDownload: InferenceModelOption?
    /// Set when the user expands a section — triggers a one-shot scroll (not on collapse or auto-expand).
    @State private var scrollToSectionID: String?

    public init(
        orchestrator: SessionOrchestrator,
        setup: SetupCoordinator,
        usage: UsageStore,
        moduleDefaults: UserDefaults,
        onCaptureHotkeyChange: ((CaptureHotkey) -> Void)? = nil
    ) {
        self.orchestrator = orchestrator
        self.setup = setup
        self.usage = usage
        self.moduleDefaults = moduleDefaults
        self.onCaptureHotkeyChange = onCaptureHotkeyChange
    }

    public var body: some View {
        let profile = SystemProfile.current()
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 16) {
                    section(PeekSettingsSection.setup) {
                        setupSection
                    }

                    section(PeekSettingsSection.capture) {
                        captureSection
                    }

                    section(PeekSettingsSection.visionModel) {
                        visionModelSection
                    }

                    section(PeekSettingsSection.usage) {
                        usageSection(stats: usage.stats)
                    }

                    section(PeekSettingsSection.about) {
                        aboutSection(profile: profile)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, contentInsets.leading)
                .padding(.trailing, contentInsets.trailing)
                .padding(.bottom, 14)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .onChange(of: scrollToSectionID) { _, sectionID in
                guard let sectionID else { return }
                // Let the disclosure animation lay out before scrolling.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    withAnimation(.easeOut(duration: 0.22)) {
                        proxy.scrollTo(sectionID, anchor: .top)
                    }
                    scrollToSectionID = nil
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: PeekPanelLayout.settingsMaxHeight, alignment: .leading)
        .task(id: inferenceCheckKey) {
            await refreshOllamaStatus()
            if !didApplyDefaultExpansion {
                applyDefaultExpandedSections()
                didApplyDefaultExpansion = true
            }
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
                Text(pendingDownload.downloadConfirmationMessage)
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: setup.isReady ? "checkmark.seal.fill" : "exclamationmark.triangle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(setup.isReady ? Color.green : Color.orange)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(setup.isReady ? "Ready to capture" : "Setup incomplete")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.primaryLabel.opacity(0.95))
                    Text(setupSummaryDetail)
                        .font(.system(size: 9, weight: .regular))
                        .foregroundStyle(theme.tertiaryLabel)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)

            HStack(spacing: 6) {
                PeekSettingsSetupChip(
                    title: "Ollama",
                    status: PeekSettingsSetupChipSupport.statusLabel(for: setup.ollamaStep),
                    tone: PeekSettingsSetupChipSupport.tone(for: setup.ollamaStep),
                    action: openSetup
                )
                PeekSettingsSetupChip(
                    title: "Model",
                    status: PeekSettingsSetupChipSupport.statusLabel(for: setup.modelStep),
                    tone: PeekSettingsSetupChipSupport.tone(for: setup.modelStep),
                    action: openSetup
                )
                PeekSettingsSetupChip(
                    title: "Recording",
                    status: PeekSettingsSetupChipSupport.statusLabel(for: setup.captureStep),
                    tone: PeekSettingsSetupChipSupport.tone(for: setup.captureStep),
                    action: openSetup
                )
            }

            PeekSettingsCommandRow(
                icon: "arrow.right.circle",
                title: "Get ready",
                subtitle: "Install, permissions, and a test capture",
                action: openSetup
            )
        }
    }

    @ViewBuilder
    private var captureSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            PeekCaptureShortcutRow(hotkey: orchestrator.settings.captureHotkey) { newHotkey in
                orchestrator.settings.captureHotkey = newHotkey
                orchestrator.persistSettings(to: moduleDefaults)
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
        }
    }

    private var captureScopeRow: some View {
        let scope = orchestrator.settings.captureScope
        return PeekSettingsMenuRow(
            icon: scope.settingsIcon,
            title: "Capture area",
            detail: scope.displayName,
            value: scope.barLabel
        ) {
            ForEach(CaptureScope.allCases) { option in
                Button {
                    setCaptureScope(option)
                } label: {
                    Label {
                        Text(option.displayName)
                    } icon: {
                        if option == scope {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
    }

    private var answerDepthRow: some View {
        let depth = AnswerDepth(quickMode: orchestrator.settings.quickMode)
        return PeekSettingsMenuRow(
            icon: depth.settingsIcon,
            title: "Answer depth",
            detail: depth.menuDetail,
            value: depth.barLabel
        ) {
            ForEach(AnswerDepth.allCases, id: \.rawValue) { option in
                Button {
                    setQuickMode(option.quickMode)
                } label: {
                    Label {
                        Text("\(option.barLabel) — \(option.menuDetail)")
                    } icon: {
                        if option == depth {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var visionModelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.green)
                    .frame(width: 18)
                Text("100% local — nothing leaves this Mac")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.secondaryLabel)
            }
            .padding(.vertical, 2)

            PeekSettingsStatusRow(
                icon: ollamaStatusTone.icon,
                title: "Ollama server",
                detail: ollamaServerDetail,
                status: ollamaStatusLabel,
                tone: ollamaStatusTone
            )

            PeekSettingsModelPickerRow(
                currentTag: orchestrator.settings.textModel,
                recommendedTag: SystemProfile.current().suggestedTextModel,
                isInstalled: { setup.isModelInstalled($0) },
                onSelect: selectModel
            )

            if selectedModelNeedsDownload || setup.isPullingModel {
                PeekSettingsCommandRow(
                    icon: "arrow.down.circle",
                    title: downloadRowTitle,
                    subtitle: downloadRowSubtitle,
                    trailing: .button(setup.isPullingModel ? "Downloading…" : "Download"),
                    action: { beginModelDownloadForCurrentSelection() }
                )
                .disabled(setup.isPullingModel)
                .opacity(setup.isPullingModel ? 0.55 : 1)
            }

            if let pullStatusLine = setup.pullStatusLine, setup.isPullingModel {
                Text(pullStatusLine)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(theme.tertiaryLabel)
                    .lineLimit(2)
                    .padding(.leading, PeekSettingsRowMetrics.iconWidth + PeekSettingsRowMetrics.rowSpacing)
            }

            PeekSettingsExpandableRow(
                icon: "gearshape",
                title: "Advanced",
                subtitle: "Custom server address",
                isExpanded: $visionModelAdvancedExpanded
            )

            if visionModelAdvancedExpanded {
                PeekSettingsFormField(
                    icon: "link",
                    title: "Server address",
                    text: ollamaURLBinding,
                    placeholder: "http://127.0.0.1:11434",
                    monospaced: true
                )
                PeekSettingsNote(
                    text: "Default is this Mac. Change only if Ollama runs elsewhere."
                )
            }
        }
    }

    @ViewBuilder
    private func usageSection(stats: UsageStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            PeekSettingsValueRow(label: "Captures", value: "\(stats.captures)")
            PeekSettingsValueRow(label: "Screen data", value: String(format: "%.1f MB", stats.imageMegabytes))
            PeekSettingsValueRow(
                label: "Model usage",
                value: "\(stats.promptTokens.formatted()) in · \(stats.responseTokens.formatted()) out"
            )
            PeekSettingsValueRow(
                label: "Response speed",
                value: stats.averageTokensPerSecond > 0
                    ? String(format: "~%.0f (higher is faster)", stats.averageTokensPerSecond)
                    : "—"
            )

            PeekSettingsCommandRow(
                icon: "arrow.counterclockwise",
                title: "Reset stats",
                subtitle: "Clear counters on this Mac",
                style: .destructive,
                trailing: .button("Reset"),
                action: { usage.reset() }
            )
        }
    }

    @ViewBuilder
    private func aboutSection(profile: SystemProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            PeekSettingsValueRow(label: "Version", value: PeekAppMetadata.versionLabel)
            PeekSettingsValueRow(label: "Memory", value: "\(profile.physicalMemoryGB) GB")
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        PeekSettingsDisclosureSection(
            title: title,
            isExpanded: Binding(
                get: { expandedSections.contains(title) },
                set: { open in
                    if open {
                        expandedSections.insert(title)
                        scrollToSectionID = title
                    } else {
                        expandedSections.remove(title)
                    }
                }
            ),
            content: content
        )
        .id(title)
    }

    private var setupSummaryDetail: String {
        if setup.isReady {
            return "Ollama, model, and Screen Recording are set."
        }
        var missing: [String] = []
        if setup.ollamaStep != .complete { missing.append("Ollama") }
        if setup.modelStep != .complete { missing.append("model") }
        if setup.captureStep != .complete { missing.append("Screen Recording") }
        guard !missing.isEmpty else { return "Finish setup before capturing." }
        return "Still needed: \(missing.joined(separator: ", "))."
    }

    private var ollamaServerDetail: String? {
        if let ollamaStatusDetail { return ollamaStatusDetail }
        switch ollamaStatusTone {
        case .loading: return "Checking connection…"
        case .ready: return "Runs vision models on this Mac"
        case .warning, .error: return nil
        }
    }

    private func applyDefaultExpandedSections() {
        var sections: Set<String> = [PeekSettingsSection.capture]
        if !setup.isReady {
            sections.insert(PeekSettingsSection.setup)
        }
        if shouldExpandVisionModelSection {
            sections.insert(PeekSettingsSection.visionModel)
        }
        expandedSections = sections
    }

    private var shouldExpandVisionModelSection: Bool {
        !setup.isReady
            || selectedModelNeedsDownload
            || setup.ollamaStep != .complete
            || ollamaStatusTone == .error
    }

    private var inferenceCheckKey: String {
        "\(orchestrator.settings.ollamaBaseURL)|\(orchestrator.settings.textModel)"
    }

    private var selectedModelNeedsDownload: Bool {
        !setup.isModelInstalled(orchestrator.settings.textModel)
    }

    private var selectedModelOption: InferenceModelOption? {
        TextModelCatalog.option(for: orchestrator.settings.textModel)
    }

    private var downloadRowTitle: String {
        "Download \(TextModelCatalog.displayName(for: orchestrator.settings.textModel))"
    }

    private var downloadRowSubtitle: String {
        if setup.isPullingModel {
            return setup.pullStatusLine ?? "Download in progress…"
        }
        if let option = selectedModelOption {
            return option.downloadRowSubtitle
        }
        return setup.suggestedModelDiskHint + " · once via Ollama"
    }

    private var downloadConfirmationTitle: String {
        guard let pendingDownload else { return "Download model?" }
        return "Download \(pendingDownload.displayName)?"
    }

    private var downloadConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingDownload != nil },
            set: { if !$0 { pendingDownload = nil } }
        )
    }

    private var ollamaURLBinding: Binding<String> {
        Binding(
            get: { orchestrator.settings.ollamaBaseURL },
            set: { newValue in
                orchestrator.settings.ollamaBaseURL = newValue
                setup.settings.ollamaBaseURL = newValue
                orchestrator.persistSettings(to: moduleDefaults)
                setup.persistSettings()
            }
        )
    }

    private func openSetup() {
        appState.showHome()
        appState.moduleBreadcrumb = PeekRootView.setupBreadcrumb
    }

    private func selectModel(_ option: InferenceModelOption) {
        if setup.isModelInstalled(option.tag) {
            setup.selectTextModel(option.tag)
            return
        }
        pendingDownload = option
    }

    private func beginModelDownloadForCurrentSelection() {
        if let option = selectedModelOption {
            beginModelDownload(option)
            return
        }
        beginModelDownload(
            InferenceModelOption(
                tag: orchestrator.settings.textModel,
                displayName: TextModelCatalog.displayName(for: orchestrator.settings.textModel),
                provider: "Ollama"
            )
        )
    }

    private func beginModelDownload(_ option: InferenceModelOption) {
        setup.settings.textModel = option.tag
        setup.persistSettings()
        orchestrator.settings.textModel = option.tag
        orchestrator.persistSettings(to: moduleDefaults)
        setup.pullRecommendedModel()
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

    private var previewBeforeInferBinding: Binding<Bool> {
        Binding(
            get: { orchestrator.settings.previewBeforeInfer },
            set: { newValue in
                orchestrator.settings.previewBeforeInfer = newValue
                orchestrator.persistSettings(to: moduleDefaults)
            }
        )
    }

    private var suggestFollowUpsBinding: Binding<Bool> {
        Binding(
            get: { orchestrator.settings.suggestFollowUps },
            set: { newValue in
                orchestrator.settings.suggestFollowUps = newValue
                orchestrator.persistSettings(to: moduleDefaults)
            }
        )
    }

    private func refreshOllamaStatus() async {
        ollamaStatusLabel = "Checking"
        ollamaStatusDetail = nil
        ollamaStatusTone = .loading

        let engine = OllamaInferenceEngine()
        let health = await engine.health(
            baseURL: orchestrator.settings.ollamaBaseURL,
            model: orchestrator.settings.textModel
        )
        switch health {
        case .ready:
            ollamaStatusLabel = "Ready"
            ollamaStatusDetail = nil
            ollamaStatusTone = .ready
        case .unavailable(let reason):
            ollamaStatusLabel = "Unavailable"
            ollamaStatusDetail = reason
            ollamaStatusTone = .error
        }
        await setup.refresh()
    }
}
