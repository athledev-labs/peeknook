// SPDX-License-Identifier: Apache-2.0

import PeeknookDesign
import PeeknookCore
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

private enum WebLookupSort: String, CaseIterable {
    case relevance
    case title
    case host

    var label: String {
        switch self {
        case .relevance: "Relevance"
        case .title: "Title"
        case .host: "Site"
        }
    }
}

/// Filterable, sortable web lookup results, shown during inference and on the answer screen.
struct PeekWebLookupTableView: View {
    let snapshot: WebLookupSnapshot?
    var isLoading: Bool = false

    @Environment(\.nookResolvedTheme) private var theme
    @State private var filterText = ""
    @State private var sort: WebLookupSort = .relevance
    @State private var sortAscending = true
    @State private var selectedID: UUID?
    @State private var isExpanded = true

    private var queryLabel: String {
        guard let snapshot else { return PeekLocalized("Web lookup") }
        if snapshot.lookupFailure == .sensitiveContent {
            return PeekLocalized("Web lookup blocked")
        }
        if snapshot.query.isEmpty { return PeekLocalized("Web lookup") }
        return snapshot.query
    }

    private var emptyStateMessage: String? {
        guard let snapshot, snapshot.results.isEmpty else { return nil }
        if snapshot.lookupFailed {
            switch snapshot.lookupFailure {
            case .rateLimited:
                return PeekLocalized("Web lookup skipped. Wait a few seconds between searches.")
            case .unavailable:
                return PeekLocalized("Web lookup unavailable. Check your network connection.")
            case .sensitiveContent:
                return PeekLocalized("Web lookup skipped. Sensitive content detected.")
            case .none:
                return PeekLocalized("Web lookup unavailable. Check your network connection.")
            }
        }
        return String(format: PeekLocalized("No web results for \"%@\"."), snapshot.query)
    }

    private var filteredResults: [WebSearchResult] {
        guard let results = snapshot?.results else { return [] }
        let needle = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = needle.isEmpty ? results : results.filter {
            $0.title.lowercased().contains(needle)
                || $0.snippet.lowercased().contains(needle)
                || $0.host.lowercased().contains(needle)
        }
        return base.sorted { lhs, rhs in
            let ordered: Bool
            switch sort {
            case .relevance:
                ordered = lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            case .title:
                ordered = lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            case .host:
                ordered = lhs.host.localizedCaseInsensitiveCompare(rhs.host) == .orderedAscending
            }
            return sortAscending ? ordered : !ordered
        }
    }

    var body: some View {
        PeekCollapsibleSection(title: queryLabel, symbol: "globe", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                if isLoading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                            .peekDecorative()
                        Text(peek: "Searching the web…")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.secondaryLabel)
                    }
                    .peekLoading("Searching the web…")
                } else if let message = emptyStateMessage {
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.tertiaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                } else if snapshot != nil {
                    controlsRow
                    tableHeader
                    resultsTable
                }
            }
        }
    }

    private var controlsRow: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.tertiaryLabel)
                    .peekDecorative()
                TextField("Filter results…", text: $filterText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(theme.subtleFill.opacity(0.55), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            Menu {
                ForEach(WebLookupSort.allCases, id: \.self) { option in
                    Button {
                        if sort == option {
                            sortAscending.toggle()
                        } else {
                            sort = option
                            sortAscending = true
                        }
                    } label: {
                        HStack {
                            Text(option.label)
                            if sort == option {
                                Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(sort.label)
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(theme.secondaryLabel)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .peekGlass(cornerRadius: 6, isHovered: false, prominent: false)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 8) {
            Text("Title")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Site")
                .frame(width: 72, alignment: .leading)
        }
        .font(.system(size: 8, weight: .semibold))
        .foregroundStyle(theme.quaternaryLabel)
        .textCase(.uppercase)
        .tracking(0.3)
    }

    private var resultsTable: some View {
        VStack(spacing: 0) {
            ForEach(filteredResults) { result in
                resultRow(result)
                if result.id != filteredResults.last?.id {
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

    private func resultRow(_ result: WebSearchResult) -> some View {
        let isSelected = selectedID == result.id
        return Button {
            selectedID = result.id
            openURL(result.url)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(result.title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.primaryLabel.opacity(0.95))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(result.host)
                        .font(.system(size: 9))
                        .foregroundStyle(theme.tertiaryLabel)
                        .lineLimit(1)
                        .frame(width: 72, alignment: .leading)
                }
                if !result.snippet.isEmpty {
                    Text(result.snippet)
                        .font(.system(size: 9))
                        .foregroundStyle(theme.secondaryLabel)
                        .lineLimit(isSelected ? 4 : 2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(isSelected ? theme.subtleFill.opacity(0.65) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .peekAction(label: result.title, hint: "Open in browser")
    }

    private func openURL(_ url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }
}
