// SPDX-License-Identifier: Apache-2.0

import AppKit
import PeeknookDesign
import PeeknookCore
import SwiftUI

public struct PeekSettingsView: View {
    public var orchestrator: SessionOrchestrator
    public var setup: SetupCoordinator
    public var settings: PeekSettingsController
    public var modelCatalog: ModelCatalogService
    public var usage: UsageStore
    public var storageFootprint: any StorageFootprinting
    public var onCaptureHotkeyChange: ((CaptureHotkey) -> Void)?
    public var onBriefHotkeyChange: ((CaptureHotkey) -> Void)?
    public var onCameraHotkeyChange: ((CaptureHotkey) -> Void)?

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
    // Physical RAM doesn't change while the panel is open; snapshot once instead of probing
    // ProcessInfo on every body re-evaluation (the panel re-renders on each settings/probe change).
    @State private var profile = SystemProfile.current()

    public init(
        orchestrator: SessionOrchestrator,
        setup: SetupCoordinator,
        settings: PeekSettingsController,
        modelCatalog: ModelCatalogService,
        usage: UsageStore,
        storageFootprint: any StorageFootprinting,
        onCaptureHotkeyChange: ((CaptureHotkey) -> Void)? = nil,
        onBriefHotkeyChange: ((CaptureHotkey) -> Void)? = nil,
        onCameraHotkeyChange: ((CaptureHotkey) -> Void)? = nil
    ) {
        self.orchestrator = orchestrator
        self.setup = setup
        self.settings = settings
        self.modelCatalog = modelCatalog
        self.usage = usage
        self.storageFootprint = storageFootprint
        self.onCaptureHotkeyChange = onCaptureHotkeyChange
        self.onBriefHotkeyChange = onBriefHotkeyChange
        self.onCameraHotkeyChange = onCameraHotkeyChange
    }

    public var body: some View {
        ScrollViewReader { proxy in
            PeekScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section(PeekSettingsSectionTitle.setup) {
                        PeekSettingsSetupSection(setup: setup, onOpenSetup: openSetup)
                    }

                    section(PeekSettingsSectionTitle.appearance) {
                        NookAppearanceSettingsSection(appState: appState)
                    }

                    section(PeekSettingsSectionTitle.capture) {
                        PeekSettingsCaptureSection(
                            orchestrator: orchestrator,
                            setup: setup,
                            settings: settings,
                            onCaptureHotkeyChange: onCaptureHotkeyChange,
                            onBriefHotkeyChange: onBriefHotkeyChange,
                            onCameraHotkeyChange: onCameraHotkeyChange
                        )
                    }

                    section(PeekSettingsSectionTitle.profiles) {
                        PeekSettingsProfilesSection(
                            orchestrator: orchestrator,
                            settings: settings
                        )
                    }

                    section(PeekSettingsSectionTitle.layout) {
                        PeekSettingsLayoutSection(
                            orchestrator: orchestrator,
                            settings: settings
                        )
                    }

                    section(PeekSettingsSectionTitle.interaction) {
                        PeekSettingsInteractionSection(
                            orchestrator: orchestrator,
                            settings: settings
                        )
                    }

                    section(PeekSettingsSectionTitle.answerModel) {
                        PeekSettingsVisionSection(
                            orchestrator: orchestrator,
                            setup: setup,
                            settings: settings,
                            modelCatalog: modelCatalog,
                            ollamaStatusLabel: ollamaStatusLabel,
                            ollamaStatusDetail: ollamaStatusDetail,
                            ollamaStatusTone: ollamaStatusTone,
                            advancedExpanded: $visionModelAdvancedExpanded,
                            onSelectModel: selectModel,
                            onBrowseModels: openModelLibrary
                        )
                    }

                    section(PeekSettingsSectionTitle.data) {
                        PeekSettingsDataSection(
                            orchestrator: orchestrator,
                            storageFootprint: storageFootprint,
                            onReset: { usage.reset() },
                            onOpenModelLibrary: openModelLibrary,
                            onOpenPastChats: openPastChats
                        )
                    }

                    section(PeekSettingsSectionTitle.about) {
                        PeekSettingsAboutSection(profile: profile)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, contentInsets.bottom + 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: scrollToSectionID) { _, sectionID in
                guard let sectionID else { return }
                Task { @MainActor in
                    // Let the disclosure spring settle before scrolling, animating both
                    // at once makes the scroll indicator flicker in the capped panel.
                    try? await Task.sleep(nanoseconds: 320_000_000)
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        proxy.scrollTo(sectionID, anchor: .top)
                    }
                    scrollToSectionID = nil
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: PeekPanelLayout.settingsMaxHeight, alignment: .leading)
        .task(id: inferenceCheckKey) {
            if setup.skipsLiveProbes {
                ollamaStatusLabel = "Ready"
                ollamaStatusTone = .ready
            } else {
                await refreshOllamaStatus()
            }
            if !didApplyDefaultExpansion {
                applyDefaultExpandedSections()
                didApplyDefaultExpansion = true
            }
            applyPendingFocusIfNeeded()
        }
        .task(id: appState.isNookVisible) {
            guard !setup.skipsLiveProbes, appState.isNookVisible else { return }
            // Light periodic refresh while the panel is open so a server dying, or coming back -
            // mid-session updates the badge without waiting on a URL/model edit. Silent (no
            // "Checking" flicker) since it's a background poll, not a user-triggered check. Gated on
            // visibility: the Settings surface stays mounted (0×0) while collapsed, so an un-gated
            // loop would keep probing a panel nobody is looking at.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { break }
                await refreshOllamaStatus(resetToChecking: false)
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
            sections.insert(PeekSettingsSectionTitle.answerModel)
        }
        expandedSections = sections
    }

    private var shouldExpandVisionModelSection: Bool {
        if orchestrator.settings.answerBackend == .openAICompatible {
            // Server-managed backend: expand while unconfigured or unreachable.
            return !setup.isReady
                || orchestrator.settings.openAICompatibleBaseURL.isEmpty
                || orchestrator.settings.openAICompatibleModelTag.isEmpty
                || ollamaStatusTone == .error
        }
        return !setup.isReady
            || !setup.isModelInstalled(orchestrator.settings.textModel)
            || setup.ollamaStep != .complete
            || ollamaStatusTone == .error
    }

    private var inferenceCheckKey: String {
        let settings = orchestrator.settings
        return "\(settings.answerBackend.rawValue)|\(settings.ollamaBaseURL)|\(settings.textModel)|\(settings.openAICompatibleBaseURL)|\(settings.openAICompatibleModelTag)"
    }

    private func applyPendingFocusIfNeeded() {
        guard let focus = PeekSettingsNavigation.consumePendingFocus() else { return }
        switch focus {
        case .visionServer:
            expandedSections.insert(PeekSettingsSectionTitle.answerModel)
            visionModelAdvancedExpanded = true
            scrollToSectionID = PeekSettingsSectionTitle.answerModel
        }
    }

    private func openSetup() {
        appState.showHome()
        appState.moduleBreadcrumb = PeekRootView.setupBreadcrumb
    }

    private func openModelLibrary() {
        PeekModelLibraryNavigation.open(appState: appState)
    }

    private func openPastChats() {
        appState.showHome()
        appState.moduleBreadcrumb = PeekHomeBreadcrumb.pastChats
    }

    private func selectModel(_ option: InferenceModelOption) {
        switch settings.pickModel(option) {
        case .selected:
            break
        case .needsDownload(let pending):
            pendingDownload = pending
        }
    }

    private func refreshOllamaStatus(resetToChecking: Bool = true) async {
        if resetToChecking {
            ollamaStatusLabel = "Checking"
            ollamaStatusDetail = nil
            ollamaStatusTone = .loading
        }

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
