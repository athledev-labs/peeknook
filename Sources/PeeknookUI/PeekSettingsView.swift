// SPDX-License-Identifier: Apache-2.0

import AppKit
import NookApp
import PeeknookCore
import SwiftUI

public struct PeekSettingsView: View {
    public var orchestrator: SessionOrchestrator
    public var setup: SetupCoordinator
    public var settings: PeekSettingsController
    public var usage: UsageStore
    public var onCaptureHotkeyChange: ((CaptureHotkey) -> Void)?

    @Environment(\.nookContentInsets) private var contentInsets
    @EnvironmentObject private var appState: AppState
    @State private var ollamaStatusLabel = "Checking"
    @State private var ollamaStatusDetail: String?
    @State private var ollamaStatusTone: PeekSettingsStatusTone = .loading
    @State private var expandedSections: Set<String> = [PeekSettingsSectionTitle.capture]
    @State private var didApplyDefaultExpansion = false
    @State private var visionModelAdvancedExpanded = false
    @State private var pendingDownload: InferenceModelOption?
    @State private var scrollToSectionID: String?

    public init(
        orchestrator: SessionOrchestrator,
        setup: SetupCoordinator,
        settings: PeekSettingsController,
        usage: UsageStore,
        onCaptureHotkeyChange: ((CaptureHotkey) -> Void)? = nil
    ) {
        self.orchestrator = orchestrator
        self.setup = setup
        self.settings = settings
        self.usage = usage
        self.onCaptureHotkeyChange = onCaptureHotkeyChange
    }

    public var body: some View {
        let profile = SystemProfile.current()
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 16) {
                    section(PeekSettingsSectionTitle.setup) {
                        PeekSettingsSetupSection(setup: setup, onOpenSetup: openSetup)
                    }

                    section(PeekSettingsSectionTitle.capture) {
                        PeekSettingsCaptureSection(
                            orchestrator: orchestrator,
                            settings: settings,
                            onCaptureHotkeyChange: onCaptureHotkeyChange
                        )
                    }

                    section(PeekSettingsSectionTitle.visionModel) {
                        PeekSettingsVisionSection(
                            orchestrator: orchestrator,
                            setup: setup,
                            settings: settings,
                            ollamaStatusLabel: ollamaStatusLabel,
                            ollamaStatusDetail: ollamaStatusDetail,
                            ollamaStatusTone: ollamaStatusTone,
                            advancedExpanded: $visionModelAdvancedExpanded,
                            onSelectModel: selectModel
                        )
                    }

                    section(PeekSettingsSectionTitle.usage) {
                        PeekSettingsUsageSection(stats: usage.stats, onReset: { usage.reset() })
                    }

                    section(PeekSettingsSectionTitle.about) {
                        PeekSettingsAboutSection(profile: profile)
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
        .peekModelDownloadConfirmation(pending: $pendingDownload) { option in
            settings.beginModelDownload(option)
        }
    }

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

    private func applyDefaultExpandedSections() {
        var sections: Set<String> = [PeekSettingsSectionTitle.capture]
        if !setup.isReady {
            sections.insert(PeekSettingsSectionTitle.setup)
        }
        if shouldExpandVisionModelSection {
            sections.insert(PeekSettingsSectionTitle.visionModel)
        }
        expandedSections = sections
    }

    private var shouldExpandVisionModelSection: Bool {
        !setup.isReady
            || !setup.isModelInstalled(orchestrator.settings.textModel)
            || setup.ollamaStep != .complete
            || ollamaStatusTone == .error
    }

    private var inferenceCheckKey: String {
        "\(orchestrator.settings.ollamaBaseURL)|\(orchestrator.settings.textModel)"
    }

    private func openSetup() {
        appState.showHome()
        appState.moduleBreadcrumb = PeekRootView.setupBreadcrumb
    }

    private func selectModel(_ option: InferenceModelOption) {
        switch settings.pickModel(option) {
        case .selected:
            break
        case .needsDownload(let pending):
            pendingDownload = pending
        }
    }

    private func refreshOllamaStatus() async {
        ollamaStatusLabel = "Checking"
        ollamaStatusDetail = nil
        ollamaStatusTone = .loading

        let health = await settings.inferenceHealth()
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
