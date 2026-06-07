// SPDX-License-Identifier: Apache-2.0

import Charts
import NookApp
import PeeknookCore
import SwiftUI

enum UsageGrowthMetric: CaseIterable, Equatable {
    case tokens, captures, speed

    var label: String {
        switch self {
        case .tokens: "Tokens"
        case .captures: "Captures"
        case .speed: "Speed"
        }
    }
}

private struct ChartSeriesScrub: Equatable, Identifiable {
    let seriesID: String
    let value: Double
    let anchorEvent: UsageEvent?

    var id: String { seriesID }
}

private struct ChartScrubState: Equatable {
    let date: Date
    let plotX: CGFloat
    let series: [ChartSeriesScrub]
    /// Sticky focus for click when multiple lines overlap, not used for tooltip display.
    let focusSeriesID: String?
}

struct UsageGrowthPoint: Identifiable, Equatable {
    let id: UUID
    let date: Date
    let value: Double
    let seriesID: String
    let event: UsageEvent?

    init(
        id: UUID = UUID(),
        date: Date,
        value: Double,
        seriesID: String,
        event: UsageEvent? = nil
    ) {
        self.id = id
        self.date = date
        self.value = value
        self.seriesID = seriesID
        self.event = event
    }
}

/// Cumulative usage over calendar time, one colored line per model when unfiltered.
struct PeekUsageGrowthChart: View {
    let events: [UsageEvent]
    let modelFilter: String?
    let modelTags: [String]
    let metric: UsageGrowthMetric
    @Binding var selectedEventID: UUID?

    @Environment(\.nookResolvedTheme) private var theme
    @State private var scrubState: ChartScrubState?
    @State private var stickyFocusSeriesID: String?

    private var showsMultipleSeries: Bool {
        modelFilter == nil && modelTags.count > 1
    }

    private var actualPoints: [UsageGrowthPoint] {
        if showsMultipleSeries {
            return modelTags.flatMap { tag in
                Self.buildActualPoints(
                    events: events.filter { $0.modelTag == tag },
                    metric: metric,
                    seriesID: tag
                )
            }
        }
        let seriesID = modelFilter ?? modelTags.first ?? "usage"
        return Self.buildActualPoints(events: events, metric: metric, seriesID: seriesID)
    }

    private var colorScale: [String: Color] {
        var scale: [String: Color] = [:]
        for (index, tag) in modelTags.enumerated() {
            scale[tag] = PeekModelMixPalette.color(index: index)
        }
        if let only = modelTags.first {
            scale[only] = PeekModelMixPalette.color(index: 0)
        }
        return scale
    }

    private var activeSeriesIDs: [String] {
        if showsMultipleSeries { return modelTags }
        return [modelFilter ?? modelTags.first ?? "usage"]
    }

    private var displayScrub: ChartScrubState? {
        if let selectedEventID,
           let point = actualPoints.first(where: { $0.event?.id == selectedEventID }),
           let event = point.event {
            return ChartScrubState(
                date: point.date,
                plotX: 0,
                series: [
                    ChartSeriesScrub(
                        seriesID: point.seriesID,
                        value: point.value,
                        anchorEvent: event
                    ),
                ],
                focusSeriesID: point.seriesID
            )
        }
        return scrubState
    }

    var body: some View {
        Chart(actualPoints) { point in
            LineMark(
                x: .value("Date", point.date),
                y: .value(yAxisLabel, point.value),
                series: .value("Series", point.seriesID)
            )
            .interpolationMethod(interpolation(for: point.seriesID))
            .foregroundStyle(colorScale[point.seriesID] ?? Color.accentColor)
            .lineStyle(StrokeStyle(lineWidth: 2))
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(theme.tertiaryLabel.opacity(0.2))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(shortAxisDate(date))
                            .font(.system(size: 9, weight: .regular))
                            .foregroundStyle(theme.tertiaryLabel)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(theme.tertiaryLabel.opacity(0.2))
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(yAxisLabel(for: number))
                            .font(.system(size: 9, weight: .regular))
                            .foregroundStyle(theme.tertiaryLabel)
                    }
                }
            }
        }
        .chartYScale(domain: yDomain)
        .chartYAxisLabel(position: .leading, alignment: .center, spacing: 6) {
            Text(yAxisTitle)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.tertiaryLabel)
        }
        .chartXAxisLabel(position: .bottom, alignment: .center, spacing: 4) {
            Text(peek: "Date")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.tertiaryLabel)
        }
        .chartPlotStyle { plot in
            plot.padding(.horizontal, 4)
        }
        .frame(height: 124)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                updateHover(at: location, proxy: proxy, geometry: geometry)
                            case .ended:
                                scrubState = nil
                                stickyFocusSeriesID = nil
                            }
                        }
                        .gesture(
                            SpatialTapGesture()
                                .onEnded { value in
                                    handleTap(at: value.location, proxy: proxy, geometry: geometry)
                                }
                        )

                    interactionOverlay(proxy: proxy, geometry: geometry)
                }
            }
        }
    }

    @ViewBuilder
    private func interactionOverlay(proxy: ChartProxy, geometry: GeometryProxy) -> some View {
        if let plotFrame = proxy.plotFrame, let scrub = displayScrub {
            let plotRect = geometry[plotFrame]
            let plotX = scrub.plotX > 0 ? scrub.plotX : (proxy.position(forX: scrub.date) ?? 0)
            let x = plotRect.origin.x + plotX

            Path { path in
                path.move(to: CGPoint(x: x, y: plotRect.minY))
                path.addLine(to: CGPoint(x: x, y: plotRect.maxY))
            }
            .stroke(theme.tertiaryLabel.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

            ForEach(scrub.series) { entry in
                if let yPosition = proxy.position(forY: entry.value) {
                    let y = plotRect.origin.y + yPosition
                    let isFocused = entry.seriesID == scrub.focusSeriesID
                    let isSelected = entry.anchorEvent?.id == selectedEventID
                    Circle()
                        .fill(colorScale[entry.seriesID] ?? Color.accentColor)
                        .frame(
                            width: isSelected ? 9 : (isFocused ? 7 : 5),
                            height: isSelected ? 9 : (isFocused ? 7 : 5)
                        )
                        .position(x: x, y: y)
                }
            }

            chartTooltip(for: scrub)
                .fixedSize()
                .position(
                    x: min(max(x, plotRect.minX + 52), plotRect.maxX - 52),
                    y: plotRect.minY + 6
                )
        }
    }

    private func chartTooltip(for scrub: ChartScrubState) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Self.tooltipDateFormatter.string(from: scrub.date))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.primaryLabel)
            if scrub.series.count == 1, let entry = scrub.series.first {
                Text(tooltipValue(entry.value))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(theme.secondaryLabel)
            } else {
                ForEach(scrub.series) { entry in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(colorScale[entry.seriesID] ?? Color.accentColor)
                            .frame(width: 5, height: 5)
                            .peekDecorative()
                        Text(TextModelCatalog.displayName(for: entry.seriesID))
                            .font(.system(size: 9, weight: .regular))
                            .foregroundStyle(theme.secondaryLabel)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(tooltipValue(entry.value))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(theme.primaryLabel.opacity(0.95))
                    }
                }
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(theme.subtleFill.opacity(0.55), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(theme.subtleStroke.opacity(0.35), lineWidth: 0.5)
        )
    }

    private func tooltipValue(_ value: Double) -> String {
        switch metric {
        case .tokens: "\(TokenFormat.compact(Int(value.rounded())))"
        case .captures: "\(Int(value.rounded()))"
        case .speed: String(format: "%.0f tok/s", value)
        }
    }

    private func handleTap(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let scrub = resolveScrub(at: location, proxy: proxy, geometry: geometry),
              let event = scrub.series.first(where: { $0.seriesID == scrub.focusSeriesID })?.anchorEvent
                ?? scrub.series.compactMap(\.anchorEvent).min(by: {
                    abs($0.recordedAt.timeIntervalSince(scrub.date)) < abs($1.recordedAt.timeIntervalSince(scrub.date))
                })
        else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            selectedEventID = selectedEventID == event.id ? nil : event.id
        }
    }

    private func updateHover(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let scrub = resolveScrub(at: location, proxy: proxy, geometry: geometry) else {
            scrubState = nil
            stickyFocusSeriesID = nil
            return
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            scrubState = scrub
        }
    }

    /// Continuous X scrub, show every series at this date so overlapping lines don't flicker.
    private func resolveScrub(
        at location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) -> ChartScrubState? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let plotRect = geometry[plotFrame]
        let hoverX = location.x - plotRect.origin.x
        let hoverY = location.y - plotRect.origin.y
        guard hoverX >= 0, hoverX <= plotRect.width,
              hoverY >= 0, hoverY <= plotRect.height,
              let date: Date = proxy.value(atX: hoverX, as: Date.self)
        else { return nil }

        let seriesSnapshots = activeSeriesIDs.map { seriesID -> ChartSeriesScrub in
            let seriesPoints = actualPoints
                .filter { $0.seriesID == seriesID }
                .sorted { $0.date < $1.date }
            let value = stepValue(at: date, in: seriesPoints)
            let anchorEvent = nearestEvent(to: date, in: seriesPoints)
            return ChartSeriesScrub(seriesID: seriesID, value: value, anchorEvent: anchorEvent)
        }

        let focus = resolvedFocusSeriesID(
            hoverY: hoverY,
            series: seriesSnapshots,
            proxy: proxy
        )
        stickyFocusSeriesID = focus

        return ChartScrubState(
            date: date,
            plotX: hoverX,
            series: seriesSnapshots,
            focusSeriesID: focus
        )
    }

    private func resolvedFocusSeriesID(
        hoverY: CGFloat,
        series: [ChartSeriesScrub],
        proxy: ChartProxy
    ) -> String? {
        guard showsMultipleSeries else { return series.first?.seriesID }

        let distances: [(String, CGFloat)] = series.compactMap { entry in
            guard let yPos = proxy.position(forY: entry.value) else { return nil }
            return (entry.seriesID, abs(yPos - hoverY))
        }
        guard let closest = distances.min(by: { $0.1 < $1.1 }) else {
            return stickyFocusSeriesID ?? series.first?.seriesID
        }

        let stickiness: CGFloat = 20
        if let sticky = stickyFocusSeriesID,
           let stickyDistance = distances.first(where: { $0.0 == sticky })?.1,
           closest.1 + stickiness >= stickyDistance {
            return sticky
        }
        return closest.0
    }

    private func stepValue(at date: Date, in points: [UsageGrowthPoint]) -> Double {
        guard let first = points.first else { return 0 }
        if date < first.date { return 0 }
        return points.last(where: { $0.date <= date })?.value ?? first.value
    }

    private func nearestEvent(to date: Date, in points: [UsageGrowthPoint]) -> UsageEvent? {
        points.compactMap(\.event).min {
            abs($0.recordedAt.timeIntervalSince(date)) < abs($1.recordedAt.timeIntervalSince(date))
        }
    }

    private func interpolation(for seriesID: String) -> InterpolationMethod {
        switch metric {
        case .tokens, .captures:
            return .linear
        case .speed:
            let count = actualPoints.filter { $0.seriesID == seriesID }.count
            return count >= 4 ? .catmullRom : .linear
        }
    }

    private var yAxisLabel: String {
        switch metric {
        case .tokens: "Tokens"
        case .captures: "Captures"
        case .speed: "tok/s"
        }
    }

    private var yAxisTitle: LocalizedStringKey {
        switch metric {
        case .tokens: "Cumulative tokens"
        case .captures: "Cumulative captures"
        case .speed: "Daily avg speed (tok/s)"
        }
    }

    private var yDomain: ClosedRange<Double> {
        let values = actualPoints.map(\.value)
        guard let minValue = values.min(), let maxValue = values.max() else { return 0 ... 1 }
        if metric == .speed, maxValue > minValue {
            let padding = max(4, (maxValue - minValue) * 0.15)
            return max(0, minValue - padding) ... (maxValue + padding)
        }
        let peak = max(maxValue, 1)
        return 0 ... peak * 1.08
    }

    private func yAxisLabel(for value: Double) -> String {
        switch metric {
        case .tokens: TokenFormat.compact(Int(value.rounded()))
        case .captures: String(format: "%.0f", value)
        case .speed: String(format: "%.0f", value)
        }
    }

    private func shortAxisDate(_ date: Date) -> String {
        Self.axisDateFormatter.string(from: date)
    }

    static func buildActualPoints(
        events: [UsageEvent],
        metric: UsageGrowthMetric,
        seriesID: String
    ) -> [UsageGrowthPoint] {
        if metric == .speed {
            return buildDailySpeedPoints(events: events, seriesID: seriesID)
        }

        var cumulativeTokens = 0
        var cumulativeCaptures = 0
        return events.map { event in
            cumulativeTokens += event.responseTokens
            if event.didCapture { cumulativeCaptures += 1 }
            let value: Double = switch metric {
            case .tokens: Double(cumulativeTokens)
            case .captures: Double(cumulativeCaptures)
            case .speed: 0
            }
            return UsageGrowthPoint(
                date: event.recordedAt,
                value: value,
                seriesID: seriesID,
                event: event
            )
        }
    }

    static func buildDailySpeedPoints(events: [UsageEvent], seriesID: String) -> [UsageGrowthPoint] {
        let calendar = Calendar.current
        var buckets: [Date: [UsageEvent]] = [:]
        for event in events {
            let day = calendar.startOfDay(for: event.recordedAt)
            buckets[day, default: []].append(event)
        }
        return buckets.keys.sorted().compactMap { day in
            let dayEvents = buckets[day] ?? []
            let speeds = dayEvents.compactMap { event -> Double? in
                guard event.generationSeconds > 0 else { return nil }
                return Double(event.responseTokens) / event.generationSeconds
            }
            guard !speeds.isEmpty else { return nil }
            let average = speeds.reduce(0, +) / Double(speeds.count)
            let representative = dayEvents.max { lhs, rhs in
                speed(for: lhs) < speed(for: rhs)
            }
            return UsageGrowthPoint(
                date: day,
                value: average,
                seriesID: seriesID,
                event: representative
            )
        }
    }

    private static func speed(for event: UsageEvent) -> Double {
        guard event.generationSeconds > 0 else { return 0 }
        return Double(event.responseTokens) / event.generationSeconds
    }

    private static let axisDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter
    }()

    private static let tooltipDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
