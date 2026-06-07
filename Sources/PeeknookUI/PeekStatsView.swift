// SPDX-License-Identifier: Apache-2.0

import NookApp
import PeeknookCore
import SwiftUI

private enum StatsSection: String, CaseIterable, Hashable {
    case overview, tokenMix, growth, models

    var title: String {
        switch self {
        case .overview: "Usage Overview"
        case .tokenMix: "Token Mix"
        case .growth: "Usage Over Time"
        case .models: "Model Usage"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .tokenMix: "arrow.left.arrow.right"
        case .growth: "chart.line.uptrend.xyaxis"
        case .models: "cpu"
        }
    }
}

/// All-time usage analytics with a date filter. Full-width charts, no clipped rings.
struct PeekStatsView: View {
    var orchestrator: SessionOrchestrator

    @Environment(\.nookResolvedTheme) private var theme
    @State private var dateRange: UsageDateRange = .allTime
    @State private var timelineModel: String?
    @State private var growthMetric: UsageGrowthMetric = .tokens
    @State private var selectedGrowthEventID: UUID?
    @State private var expandedSections: Set<StatsSection> = Set(StatsSection.allCases)
    @State private var showsResetConfirmation = false

    private var rawStats: UsageStats {
        orchestrator.usage?.stats ?? UsageStats()
    }

    private var window: UsageWindow {
        rawStats.window(for: dateRange)
    }

    private var usesInferredModel: Bool {
        window.events.isEmpty && window.modelSummaries.isEmpty && window.hasData
    }

    private var displayModels: [ModelUsageSummary] {
        if !window.modelSummaries.isEmpty { return window.modelSummaries }
        guard usesInferredModel else { return [] }
        return [
            ModelUsageSummary(
                modelTag: orchestrator.settings.textModel,
                promptTokens: window.promptTokens,
                responseTokens: window.responseTokens,
                eventCount: max(1, window.captures),
                captures: window.captures
            ),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    if window.hasData {
                        collapsible(.overview) { overviewRows }
                        collapsible(.tokenMix) { tokenMixChart }
                        collapsible(.growth) { growthSection }
                        collapsible(.models) { modelSectionBody }
                    } else {
                        emptyState
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .frame(maxHeight: PeekPanelLayout.statsMaxHeight)

            dateFilterBar
        }
        .animation(.easeOut(duration: 0.18), value: dateRange)
        .onChange(of: dateRange) { _, _ in
            selectedGrowthEventID = nil
            timelineModel = nil
        }
        .confirmationDialog(
            "Reset usage stats?",
            isPresented: $showsResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset stats", role: .destructive) {
                orchestrator.usage?.reset()
                selectedGrowthEventID = nil
                timelineModel = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clears capture counts, token totals, and history on this Mac. You can't undo it.")
        }
    }

    // MARK: - Chrome

    private var dateFilterBar: some View {
        PeekSurfaceCommandBar {
            PeekSurfaceCommandPills {
                ForEach(UsageDateRange.allCases, id: \.self) { range in
                    PeekSurfaceFilterPill(
                        title: range.filterLabel,
                        isSelected: dateRange == range
                    ) {
                        withAnimation(.easeOut(duration: 0.15)) { dateRange = range }
                    }
                }
            }
            Spacer(minLength: 0)
            if rawStats.window(for: .allTime).hasData {
                NookToolbarButton(
                    title: "Reset",
                    symbol: "arrow.counterclockwise",
                    help: "Clear usage counters on this Mac"
                ) {
                    showsResetConfirmation = true
                }
            }
        }
    }

    private func collapsible(
        _ section: StatsSection,
        @ViewBuilder content: @escaping () -> some View
    ) -> some View {
        PeekCollapsibleSection(
            title: section.title,
            symbol: section.symbol,
            isExpanded: Binding(
                get: { expandedSections.contains(section) },
                set: { expanded in
                    if expanded { expandedSections.insert(section) }
                    else { expandedSections.remove(section) }
                }
            ),
            content: content
        )
    }

    // MARK: - Overview

    private var overviewRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            statsValueRow(symbol: "camera.viewfinder", label: "Captures", value: "\(window.captures)")
            statsValueRow(
                symbol: "photo.on.rectangle.angled",
                label: "Screen Data",
                value: String(format: "%.1f MB", window.imageMegabytes)
            )
            statsValueRow(
                symbol: "arrow.down.to.line",
                label: "Prompt In",
                value: TokenFormat.compact(window.promptTokens)
            )
            statsValueRow(
                symbol: "arrow.up.from.line",
                label: "Generated Out",
                value: TokenFormat.compact(window.responseTokens)
            )
            statsValueRow(
                symbol: "speedometer",
                label: "Response Speed",
                value: window.averageTokensPerSecond > 0
                    ? String(format: "~%.0f tok/s", window.averageTokensPerSecond)
                    : "-"
            )
            statsValueRow(
                symbol: "clock",
                label: "Generation Time",
                value: window.generationSeconds > 0
                    ? String(format: "%.0fs", window.generationSeconds)
                    : "-"
            )
        }
    }

    private func statsValueRow(symbol: String, label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PeekSettingsRowMetrics.rowSpacing) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.tertiaryLabel)
                .frame(width: PeekSettingsRowMetrics.iconWidth)
                .peekDecorative()
            Text(label)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(theme.secondaryLabel)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.primaryLabel.opacity(0.95))
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Token mix (horizontal stacked bar)

    private var tokenMixChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            let total = max(1, window.promptTokens + window.responseTokens)
            let promptFraction = Double(window.promptTokens) / Double(total)
            GeometryReader { geo in
                HStack(spacing: 2) {
                    Capsule()
                        .fill(Color.accentColor.opacity(0.85))
                        .frame(width: max(4, geo.size.width * promptFraction))
                    Capsule()
                        .fill(theme.tertiaryLabel.opacity(0.3))
                }
            }
            .frame(height: 10)
            .padding(.horizontal, 2)
            HStack {
                legendDot(color: Color.accentColor.opacity(0.85))
                Text("Prompt In \(TokenFormat.compact(window.promptTokens))")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(theme.secondaryLabel)
                Spacer(minLength: 8)
                legendDot(color: theme.tertiaryLabel.opacity(0.3))
                Text("Generated \(TokenFormat.compact(window.responseTokens))")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(theme.secondaryLabel)
            }
        }
    }

    private func legendDot(color: Color) -> some View {
        Circle().fill(color).frame(width: 6, height: 6).peekDecorative()
    }

    // MARK: - Usage over time (Swift Charts: calendar X, cumulative Y)

    private var growthSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if window.events.isEmpty {
                PeekSettingsNote(text: PeekLocalized("Timeline needs per-answer history. Your totals are in Usage Overview until your next capture."))
            } else {
                growthFilterBar
                PeekUsageGrowthChart(
                    events: window.events,
                    modelFilter: timelineModel,
                    modelTags: window.modelTags,
                    metric: growthMetric,
                    selectedEventID: $selectedGrowthEventID
                )
                if let eventID = selectedGrowthEventID,
                   let event = window.events.first(where: { $0.id == eventID }) {
                    TimelineEventBreakdown(event: event)
                }
            }
        }
    }

    private var growthFilterBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Text(peek: "Metric")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.tertiaryLabel)
                    .frame(width: 36, alignment: .leading)
                PeekSurfaceCommandPills {
                    ForEach(UsageGrowthMetric.allCases, id: \.self) { metric in
                        growthMetricPill(metric)
                    }
                }
            }
            if window.modelTags.count > 1 {
                growthModelFilter
            }
        }
    }

    // MARK: - Models (donut + right-side legend)

    private var modelSectionBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            PeekModelMixChart(models: displayModels)
            if usesInferredModel {
                PeekSettingsNote(text: PeekLocalized("Showing your active model against all lifetime usage. Per-model split tracks from your next capture."))
            }
        }
    }

    @ViewBuilder
    private var growthModelFilter: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(peek: "Model")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.tertiaryLabel)
                .frame(width: 36, alignment: .leading)
            if window.modelTags.count > 4 {
                modelFilterMenu
            } else {
                PeekSurfaceCommandPills {
                    modelPill(nil, label: "All")
                    ForEach(window.modelTags, id: \.self) { tag in
                        modelPill(tag, label: Self.shortModelTag(tag))
                    }
                }
            }
        }
    }

    private var modelFilterMenu: some View {
        Menu {
            Button("All models") { timelineModel = nil }
            Divider()
            ForEach(window.modelTags, id: \.self) { tag in
                Button(TextModelCatalog.displayName(for: tag)) {
                    timelineModel = tag
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(LocalizedStringKey(selectedModelFilterLabel), bundle: .module)
                    .font(.system(size: 9, weight: .regular))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .peekGlass(cornerRadius: 7, isHovered: false, prominent: true)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var selectedModelFilterLabel: String {
        if let timelineModel {
            return TextModelCatalog.displayName(for: timelineModel)
        }
        return "All models"
    }

    private static func shortModelTag(_ tag: String) -> String {
        guard let suffix = tag.split(separator: ":").last else { return tag }
        return String(suffix).uppercased()
    }

    private func modelPill(_ tag: String?, label: String) -> some View {
        PeekSurfaceFilterPill(title: label, isSelected: timelineModel == tag) {
            withAnimation(.easeOut(duration: 0.15)) {
                timelineModel = tag
                selectedGrowthEventID = nil
            }
        }
    }

    private func growthMetricPill(_ metric: UsageGrowthMetric) -> some View {
        PeekSurfaceFilterPill(title: metric.label, isSelected: growthMetric == metric) {
            withAnimation(.easeOut(duration: 0.15)) {
                growthMetric = metric
                selectedGrowthEventID = nil
            }
        }
    }

    private var filteredTimelineEvents: [UsageEvent] {
        let events = window.events
        guard let timelineModel else { return events }
        return events.filter { $0.modelTag == timelineModel }
    }

    @ViewBuilder
    private var emptyState: some View {
        Group {
            switch dateRange {
            case .allTime:
                Text(peek: "No usage yet. Capture with ⌘⇧P to start building stats.")
            case .today:
                Text(peek: "Nothing recorded today.")
            case .last7Days:
                Text(peek: "Nothing recorded in the last 7 days.")
            case .last30Days:
                Text(peek: "Nothing recorded in the last 30 days.")
            }
        }
        .font(.system(size: 11, weight: .regular))
        .foregroundStyle(theme.tertiaryLabel)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 4)
    }

}

private struct TimelineEventBreakdown: View {
    let event: UsageEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PeekSettingsValueRow(
                label: "Model",
                value: TextModelCatalog.displayName(for: event.modelTag)
            )
            PeekSettingsValueRow(label: "When", value: Self.formatter.string(from: event.recordedAt))
            PeekSettingsValueRow(label: "Prompt", value: TokenFormat.compact(event.promptTokens))
            PeekSettingsValueRow(label: "Generated", value: TokenFormat.compact(event.responseTokens))
            if event.generationSeconds > 0 {
                PeekSettingsValueRow(
                    label: "Time",
                    value: String(format: "%.1fs", event.generationSeconds)
                )
                PeekSettingsValueRow(
                    label: "Speed",
                    value: String(format: "~%.0f tok/s", Double(event.responseTokens) / event.generationSeconds)
                )
            }
            PeekSettingsValueRow(
                label: "Type",
                value: event.didCapture ? "Capture" : "Follow-up"
            )
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
