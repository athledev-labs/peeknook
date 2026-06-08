// SPDX-License-Identifier: Apache-2.0

import PeeknookDesign
import PeeknookCore
import SwiftUI

private enum CatalogSearchFilter: String, CaseIterable {
    case all
    case vision
    case cloud

    var title: String {
        switch self {
        case .all: "All"
        case .vision: "Vision"
        case .cloud: "Cloud"
        }
    }
}

/// Search tab for the model library, queries ollama.com via the community catalog API.
struct PeekModelCatalogSearchView: View {
    var settings: PeekSettingsController
    var setup: SetupCoordinator
    var modelCatalog: ModelCatalogService
    @Binding var pendingDownload: InferenceModelOption?
    var onSelect: () -> Void

    @Environment(\.nookResolvedTheme) private var theme
    @State private var query = ""
    @State private var filterText = ""
    @State private var filter: CatalogSearchFilter = .all
    @State private var results: [RemoteCatalogModel] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var expandedModelID: String?
    @State private var tagsByModel: [String: [RemoteCatalogTag]] = [:]
    @State private var loadingTags: Set<String> = []
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var queryFocused: Bool

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var displayedResults: [RemoteCatalogModel] {
        let needle = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return results.filter { model in
            if filter != .all {
                let tags = tagsByModel[model.modelID]?.map(\.id) ?? []
                switch filter {
                case .all:
                    break
                case .vision:
                    guard modelCatalog.likelySupportsVision(modelID: model.modelID, tags: tags) else {
                        return false
                    }
                case .cloud:
                    if tags.isEmpty {
                        guard model.modelID.lowercased().contains("cloud") else { return false }
                    } else {
                        guard tags.contains(where: modelCatalog.isCloudTag) else { return false }
                    }
                }
            }
            guard !needle.isEmpty else { return true }
            return model.displayName.lowercased().contains(needle)
                || model.modelID.lowercased().contains(needle)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            searchField
            statusLine
            filterRow
            if !displayedResults.isEmpty {
                tableHeader
                resultsList
            }
        }
        .onChange(of: query) { _, _ in scheduleSearch() }
        .onDisappear { searchTask?.cancel() }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(theme.tertiaryLabel)
                .peekDecorative()
            TextField("Search ollama.com library…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .focused($queryFocused)
                .onSubmit { scheduleSearch(immediate: true) }
            if isSearching {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(theme.subtleFill.opacity(0.55), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(theme.subtleStroke.opacity(0.45), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var statusLine: some View {
        if let searchError {
            Text(searchError)
                .font(.system(size: 9))
                .foregroundStyle(Color.orange.opacity(0.95))
                .fixedSize(horizontal: false, vertical: true)
        } else if trimmedQuery.isEmpty {
            Text("Search the public Ollama library, results load from ollama.com.")
                .font(.system(size: 9))
                .foregroundStyle(theme.tertiaryLabel)
                .fixedSize(horizontal: false, vertical: true)
        } else if !isSearching, displayedResults.isEmpty {
            Text("No models match \"\(trimmedQuery)\".")
                .font(.system(size: 9))
                .foregroundStyle(theme.tertiaryLabel)
        }
    }

    private var filterRow: some View {
        HStack(spacing: 6) {
            PeekSurfaceCommandPills {
                ForEach(CatalogSearchFilter.allCases, id: \.self) { pill in
                    PeekSurfaceFilterPill(title: pill.title, isSelected: filter == pill) {
                        withAnimation(.easeOut(duration: 0.15)) { filter = pill }
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 8))
                    .foregroundStyle(theme.tertiaryLabel)
                    .peekDecorative()
                TextField("Filter…", text: $filterText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 9))
                    .frame(width: 72)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(theme.subtleFill.opacity(0.45), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 8) {
            Text("Model")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Tags")
                .frame(width: 44, alignment: .trailing)
        }
        .font(.system(size: 8, weight: .semibold))
        .foregroundStyle(theme.quaternaryLabel)
        .textCase(.uppercase)
        .tracking(0.3)
    }

    private var resultsList: some View {
        VStack(spacing: 0) {
            ForEach(displayedResults) { model in
                modelSection(model)
                if model.id != displayedResults.last?.id {
                    Divider().opacity(0.35)
                }
            }
        }
        .background(theme.subtleFill.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(theme.subtleStroke.opacity(0.45), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func modelSection(_ model: RemoteCatalogModel) -> some View {
        let isExpanded = expandedModelID == model.modelID
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    expandedModelID = isExpanded ? nil : model.modelID
                }
                if !isExpanded { Task { await loadTags(for: model) } }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(theme.quaternaryLabel)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 10)
                        .peekDecorative()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.displayName)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(theme.primaryLabel.opacity(0.95))
                        Text(model.modelID)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(theme.tertiaryLabel)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if loadingTags.contains(model.modelID) {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text(tagCountLabel(for: model))
                            .font(.system(size: 9))
                            .foregroundStyle(theme.tertiaryLabel)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .peekAction(label: model.displayName, hint: "Show available tags")

            if isExpanded {
                tagRows(for: model)
            }
        }
    }

    @ViewBuilder
    private func tagRows(for model: RemoteCatalogModel) -> some View {
        let tags = tagsByModel[model.modelID] ?? []
        if tags.isEmpty, loadingTags.contains(model.modelID) {
            Text("Loading tags…")
                .font(.system(size: 9))
                .foregroundStyle(theme.secondaryLabel)
                .padding(.leading, 26)
                .padding(.bottom, 6)
        } else if tags.isEmpty {
            Text("No tags listed.")
                .font(.system(size: 9))
                .foregroundStyle(theme.tertiaryLabel)
                .padding(.leading, 26)
                .padding(.bottom, 6)
        } else {
            VStack(spacing: 4) {
                ForEach(tags, id: \.id) { detail in
                    tagRow(model: model, detail: detail)
                }
            }
            .padding(.leading, 18)
            .padding(.bottom, 6)
        }
    }

    private func tagRow(model: RemoteCatalogModel, detail: RemoteCatalogTag) -> some View {
        let installed = setup.isModelInstalled(detail.id)
        let known = settings.isKnownModel(tag: detail.id)
        let traits = modelCatalog.traits(modelID: model.modelID, tag: detail.id)
        return HStack(spacing: 6) {
            Text(detail.id)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(theme.secondaryLabel)
                .lineLimit(1)
            Spacer(minLength: 0)
            if traits.contains(.cloud) {
                badge("Cloud", color: .blue)
            }
            if traits.contains(.likelyVision) {
                badge("Vision", color: .green)
            }
            Button(installed ? "Use" : known ? "Select" : "Add") {
                pickTag(model: model, detail: detail)
            }
            .font(.system(size: 9, weight: .semibold))
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .disabled(setup.isPullingModel)
            .peekAction(label: installed ? "Use \(detail.id)" : "Add \(detail.id)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(theme.subtleFill.opacity(0.4), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func badge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(color.opacity(0.95))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func tagCountLabel(for model: RemoteCatalogModel) -> String {
        if let tags = tagsByModel[model.modelID] {
            return tags.isEmpty ? "-" : "\(tags.count)"
        }
        return "…"
    }

    private func scheduleSearch(immediate: Bool = false) {
        searchTask?.cancel()
        let q = trimmedQuery
        guard !q.isEmpty else {
            results = []
            searchError = nil
            isSearching = false
            return
        }
        isSearching = true
        searchError = nil
        searchTask = Task {
            if !immediate {
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
            guard !Task.isCancelled else { return }
            do {
                let found = try await modelCatalog.searchCatalog(query: q)
                guard !Task.isCancelled else { return }
                results = found
                isSearching = false
                if found.isEmpty { searchError = "No models found." }
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                isSearching = false
                searchError = "Can't reach the model catalog, check your connection."
            }
        }
    }

    private func loadTags(for model: RemoteCatalogModel) async {
        guard tagsByModel[model.modelID] == nil else { return }
        loadingTags.insert(model.modelID)
        defer { loadingTags.remove(model.modelID) }
        do {
            let tags = try await modelCatalog.catalogTags(for: model.modelID)
            tagsByModel[model.modelID] = tags
        } catch {
            tagsByModel[model.modelID] = []
        }
    }

    private func pickTag(model: RemoteCatalogModel, detail: RemoteCatalogTag) {
        let option = modelCatalog.inferenceOption(catalogModel: model, tag: detail)
        switch settings.pickModel(option) {
        case .selected:
            onSelect()
        case .needsDownload(let pending):
            pendingDownload = pending
        }
    }
}
