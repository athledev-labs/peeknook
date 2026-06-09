// SPDX-License-Identifier: Apache-2.0

import PeeknookDesign
import PeeknookCore
import SwiftUI

private enum ModelLibraryTab: String, CaseIterable, Hashable {
    case search
    case recommended
    case onThisMac
    case custom

    var title: String {
        switch self {
        case .search: "Search"
        case .recommended: "Recommended"
        case .onThisMac: "On this Mac"
        case .custom: "Custom"
        }
    }
}

private enum CustomTagValidation: Equatable {
    case idle
    case checking
    case ready(vision: Bool?)
    case duplicate
    case unreachable
}

/// Dedicated drill-in for browsing, selecting, and downloading vision models.
struct PeekModelLibraryView: View {
    var orchestrator: SessionOrchestrator
    var setup: SetupCoordinator
    var settings: PeekSettingsController
    var modelCatalog: ModelCatalogService
    @Binding var pendingDownload: InferenceModelOption?
    var showsBackButton: Bool = false
    var onDismiss: () -> Void = {}

    @Environment(\.nookResolvedTheme) private var theme
    @State private var selectedTab: ModelLibraryTab = .recommended
    @State private var capabilityFilters: Set<ModelLibraryCapabilityFilter> = []
    @State private var visionByTag: [String: Bool] = [:]
    @State private var checkingTags: Set<String> = []
    @State private var ollamaUnreachable = false

    @State private var customTag = ""
    @State private var customValidation: CustomTagValidation = .idle
    @State private var customValidationTask: Task<Void, Never>?
    @FocusState private var customFieldFocused: Bool

    private var profile: SystemProfile { SystemProfile.current() }
    private var currentTag: String { orchestrator.settings.textModel }

    private var curatedModels: [InferenceModelOption] {
        modelCatalog.curatedModels(recommendedTag: profile.suggestedTextModel)
    }

    private var customModelOptions: [InferenceModelOption] {
        settings.customModels.map(InferenceModelOption.init(custom:))
    }

    private var undiscoveredTags: [String] {
        settings.undiscoveredInstalledTags()
    }

    private var trimmedCustomTag: String {
        customTag.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsBackButton {
                backButton
            }

            PeekSurfaceScrollColumn(maxScrollHeight: PeekPanelLayout.modelLibraryMaxHeight) {
                VStack(alignment: .leading, spacing: 12) {
                    introNote
                    tabContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)
            } footer: {
                tabFilterBar
            }
        }
        .peekModelDownloadConfirmation(pending: $pendingDownload) { option in
            settings.beginModelDownload(option)
        }
        .task(id: onThisMacScanKey) {
            guard selectedTab == .onThisMac else { return }
            await scanInstalledModels()
        }
        .onChange(of: selectedTab) { _, tab in
            if tab == .onThisMac {
                Task { await scanInstalledModels() }
            }
        }
        .onChange(of: customTag) { _, _ in
            scheduleCustomValidation()
        }
        .onChange(of: orchestrator.settings.ollamaBaseURL) { _, _ in
            visionByTag = [:]
            checkingTags = []
            if selectedTab == .onThisMac {
                Task { await scanInstalledModels() }
            }
            scheduleCustomValidation()
        }
        .onDisappear {
            customValidationTask?.cancel()
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .search:
            PeekModelCatalogSearchView(
                settings: settings,
                setup: setup,
                modelCatalog: modelCatalog,
                pendingDownload: $pendingDownload,
                onSelect: dismissLibrary
            )
        case .recommended:
            recommendedContent
        case .onThisMac:
            onThisMacContent
        case .custom:
            customContent
        }
    }

    private var recommendedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Vision models")
            capabilityFilterRow
            if filteredCuratedModels.isEmpty {
                emptyState(
                    title: "No installed models",
                    detail: "None of the recommended models are on this Mac yet. Clear the filter to see all of them."
                )
            } else {
                modelList(filteredCuratedModels)
            }
        }
    }

    private var filteredCuratedModels: [InferenceModelOption] {
        ModelLibraryFilters.apply(
            capabilityFilters,
            to: curatedModels,
            installedNames: setup.installedModelNames
        )
    }

    private var capabilityFilterRow: some View {
        PeekSurfaceCommandPills {
            ForEach(ModelLibraryCapabilityFilter.allCases, id: \.self) { filter in
                PeekSurfaceFilterPill(
                    title: filterTitle(filter),
                    isSelected: capabilityFilters.contains(filter)
                ) {
                    withAnimation(.easeOut(duration: 0.15)) { toggleFilter(filter) }
                }
            }
        }
    }

    private func filterTitle(_ filter: ModelLibraryCapabilityFilter) -> String {
        switch filter {
        case .installed: "Installed"
        }
    }

    private func toggleFilter(_ filter: ModelLibraryCapabilityFilter) {
        if capabilityFilters.contains(filter) {
            capabilityFilters.remove(filter)
        } else {
            capabilityFilters.insert(filter)
        }
    }

    @ViewBuilder
    private var onThisMacContent: some View {
        if ollamaUnreachable {
            emptyState(
                title: "Can't reach Ollama",
                detail: "Open the Ollama app or check your server address in Settings."
            )
        } else if undiscoveredTags.isEmpty {
            emptyState(
                title: "No other models found",
                detail: "Models you pull with Ollama appear here when they aren't already in your picker."
            )
        } else {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Installed on this Mac")
                VStack(spacing: 6) {
                    ForEach(undiscoveredTags, id: \.self) { tag in
                        discoverRow(for: tag)
                    }
                }
            }
        }
    }

    private var customContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(peek: "Ollama tag")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.tertiaryLabel)

                TextField("e.g. qwen3-vl:8b", text: $customTag)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(theme.primaryLabel.opacity(0.95))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(theme.subtleFill.opacity(0.55), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(theme.subtleStroke.opacity(0.45), lineWidth: 1)
                    )
                    .focused($customFieldFocused)
                    .onSubmit(addCustomTag)

                customValidationNote

                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    if showsAddAnyway {
                        NookToolbarButton(title: "Add anyway", symbol: "exclamationmark.triangle", action: addCustomTag)
                    }
                    NookToolbarButton(
                        title: "Add model",
                        symbol: "plus",
                        prominent: true,
                        action: addCustomTag
                    )
                    .disabled(!canAddCustomTag)
                }
            }

            if !customModelOptions.isEmpty {
                sectionHeader("Your models")
                VStack(spacing: 6) {
                    ForEach(customModelOptions) { option in
                        PeekModelLibraryRow(
                            option: option,
                            isSelected: isSelected(option),
                            isInstalled: setup.isModelInstalled(option.tag),
                            isRecommended: false,
                            isDownloading: isPulling(option),
                            downloadStatus: isPulling(option) ? setup.pullStatusLine : nil,
                            onTap: { select(option) },
                            onRemove: { settings.removeCustomModel(tag: option.tag) }
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var customValidationNote: some View {
        switch customValidation {
        case .idle:
            if trimmedCustomTag.isEmpty {
                Text(peek: "Type any Ollama tag. Peek pulls it if it isn't installed yet.")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.tertiaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .checking:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(peek: "Checking vision support…")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.secondaryLabel)
            }
        case .ready(let vision):
            switch vision {
            case .some(true):
                Text(peek: "Supports vision, ready to add.")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.green.opacity(0.9))
            case .some(false):
                Text(peek: "Text-only, it won't read your screenshots. You can still add it to test.")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.orange.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)
            case .none:
                Text(peek: "Couldn't verify vision support. Peek will add it anyway.")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .duplicate:
            Text(peek: "Already in your library.")
                .font(.system(size: 9))
                .foregroundStyle(theme.secondaryLabel)
        case .unreachable:
            Text(peek: "Can't reach Ollama, check it's running.")
                .font(.system(size: 9))
                .foregroundStyle(Color.orange.opacity(0.95))
        }
    }

    private var canAddCustomTag: Bool {
        guard !trimmedCustomTag.isEmpty, !settings.isKnownModel(tag: trimmedCustomTag) else { return false }
        if case .ready(let vision) = customValidation {
            return vision != false
        }
        return false
    }

    private var showsAddAnyway: Bool {
        if case .ready(let vision) = customValidation, vision == false {
            return !trimmedCustomTag.isEmpty
        }
        return false
    }

    private var onThisMacScanKey: String {
        "\(selectedTab.rawValue)|\(orchestrator.settings.ollamaBaseURL)|\(setup.installedModelNames.count)"
    }

    private var introNote: some View {
        Text(peek: "Peek sends a screenshot with every capture. Pick a model that supports vision (image input).")
            .font(.system(size: 10))
            .foregroundStyle(theme.secondaryLabel)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var backButton: some View {
        Button(action: onDismiss) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 9, weight: .bold))
                Text(peek: "Back")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(theme.secondaryLabel)
            .padding(.bottom, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .peekAction(label: "Back", hint: "Return to setup")
    }

    private var tabFilterBar: some View {
        PeekSurfaceCommandBar {
            if setup.isPullingModel {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(setup.pullStatusLine ?? "Downloading…")
                        .font(.system(size: 9))
                        .foregroundStyle(theme.tertiaryLabel)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button("Cancel") { setup.cancelPull() }
                        .font(.system(size: 9, weight: .semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(.red.opacity(0.9))
                }
            } else {
                PeekSurfaceCommandPills {
                    ForEach(ModelLibraryTab.allCases, id: \.self) { tab in
                        PeekSurfaceFilterPill(
                            title: tab.title,
                            isSelected: selectedTab == tab
                        ) {
                            withAnimation(.easeOut(duration: 0.15)) { selectedTab = tab }
                        }
                    }
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(theme.tertiaryLabel)
            .textCase(.uppercase)
            .tracking(0.4)
    }

    private func emptyState(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.secondaryLabel)
            Text(detail)
                .font(.system(size: 9))
                .foregroundStyle(theme.tertiaryLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func modelList(_ models: [InferenceModelOption]) -> some View {
        VStack(spacing: 6) {
            ForEach(models) { option in
                // Gate curated rows on the option's declared vision support the same way discovered
                // rows gate the live `/api/show` result. Curated models are all vision today, so
                // `.none` keeps their appearance unchanged; a future text-only curated entry would
                // be blocked instead of silently selectable (drift fix).
                let visionState: ModelLibraryVisionState = option.supportsVision ? .none : .textOnly
                PeekModelLibraryRow(
                    option: option,
                    isSelected: isSelected(option),
                    isInstalled: setup.isModelInstalled(option.tag),
                    isRecommended: modelCatalog.matchesModel(
                        installedNames: [option.tag],
                        wanted: profile.suggestedTextModel
                    ),
                    visionState: visionState,
                    isDownloading: isPulling(option),
                    downloadStatus: isPulling(option) ? setup.pullStatusLine : nil,
                    isActionEnabled: visionState.allowsSelection,
                    onTap: { select(option) }
                )
            }
        }
    }

    private func discoverRow(for tag: String) -> some View {
        let option = InferenceModelOption(tag: tag, displayName: tag, provider: "Ollama")
        let vision = visionByTag[modelCatalog.normalizedTag(tag)]
        let isChecking = checkingTags.contains(modelCatalog.normalizedTag(tag))
        let visionState: ModelLibraryVisionState = {
            if isChecking { return .checking }
            if let vision {
                return vision ? .supports : .textOnly
            }
            return .unknown
        }()
        let canAdd = visionState.allowsSelection

        return PeekModelLibraryRow(
            option: option,
            isSelected: false,
            isInstalled: true,
            isRecommended: false,
            visionState: visionState,
            isActionEnabled: canAdd,
            trailingOverride: canAdd ? "Add" : nil,
            onTap: { addDiscoveredModel(tag: tag) }
        )
    }

    private func isSelected(_ option: InferenceModelOption) -> Bool {
        modelCatalog.matchesModel(installedNames: [currentTag], wanted: option.tag)
    }

    private func isPulling(_ option: InferenceModelOption) -> Bool {
        setup.isPullingModel
            && modelCatalog.matchesModel(installedNames: [orchestrator.settings.textModel], wanted: option.tag)
    }

    private func scanInstalledModels() async {
        await setup.refresh()
        let health = await settings.inferenceHealth()
        ollamaUnreachable = health != .ready

        guard !ollamaUnreachable else {
            visionByTag = [:]
            checkingTags = []
            return
        }

        let tags = settings.undiscoveredInstalledTags()
        guard !tags.isEmpty else {
            checkingTags = []
            return
        }

        for tag in tags {
            let key = modelCatalog.normalizedTag(tag)
            guard visionByTag[key] == nil else { continue }
            checkingTags.insert(key)
        }

        await withTaskGroup(of: (String, Bool?).self) { group in
            for tag in tags {
                let key = modelCatalog.normalizedTag(tag)
                group.addTask {
                    let supports = await settings.supportsVision(for: tag)
                    return (key, supports)
                }
            }
            for await (key, supports) in group {
                checkingTags.remove(key)
                if let supports {
                    visionByTag[key] = supports
                }
            }
        }
    }

    private func scheduleCustomValidation() {
        customValidationTask?.cancel()
        let tag = trimmedCustomTag
        guard !tag.isEmpty else {
            customValidation = .idle
            return
        }
        if settings.isKnownModel(tag: tag) {
            customValidation = .duplicate
            return
        }

        customValidation = .checking
        customValidationTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }

            let health = await settings.inferenceHealth()
            guard !Task.isCancelled else { return }
            guard health == .ready else {
                customValidation = .unreachable
                return
            }

            if settings.isKnownModel(tag: tag) {
                customValidation = .duplicate
                return
            }

            let vision = await settings.supportsVision(for: tag)
            guard !Task.isCancelled else { return }
            customValidation = .ready(vision: vision)
        }
    }

    private func addDiscoveredModel(tag: String) {
        guard let option = settings.addCustomModel(tag: tag) else { return }
        select(option)
    }

    private func addCustomTag() {
        guard !trimmedCustomTag.isEmpty else { return }
        switch settings.addAndPickModel(tag: trimmedCustomTag) {
        case .selected:
            customTag = ""
            customValidation = .idle
            dismissLibrary()
        case .needsDownload(let pending):
            customTag = ""
            customValidation = .idle
            pendingDownload = pending
        case nil:
            break
        }
    }

    private func select(_ option: InferenceModelOption) {
        switch settings.pickModel(option) {
        case .selected:
            dismissLibrary()
        case .needsDownload(let pending):
            pendingDownload = pending
        }
    }

    private func dismissLibrary() {
        onDismiss()
    }
}

/// Opens the model library drill-in on the home surface.
@MainActor
enum PeekModelLibraryNavigation {
    static func open(appState: AppState) {
        appState.showHome()
        appState.moduleBreadcrumb = PeekHomeBreadcrumb.modelLibrary
    }

    static func close(appState: AppState) {
        if appState.moduleBreadcrumb == PeekHomeBreadcrumb.modelLibrary {
            appState.moduleBreadcrumb = nil
        }
    }
}
