// SPDX-License-Identifier: Apache-2.0

import Charts
import PeeknookDesign
import PeeknookCore
import SwiftUI

enum PeekModelMixPalette {
    static let colors: [Color] = [
        Color.accentColor,
        Color.cyan.opacity(0.9),
        Color.purple.opacity(0.88),
        Color.orange.opacity(0.92),
        Color.green.opacity(0.82),
        Color.pink.opacity(0.88),
        Color.yellow.opacity(0.9),
        Color.indigo.opacity(0.88),
        Color.mint.opacity(0.9),
        Color.teal.opacity(0.85),
    ]

    static func color(index: Int) -> Color {
        colors[index % colors.count]
    }
}

private struct ModelMixSlice: Identifiable {
    let id: String
    let label: String
    let tokens: Int
    let colorIndex: Int
}

/// Donut mix chart with a center total and a scrollable legend on the right.
struct PeekModelMixChart: View {
    let models: [ModelUsageSummary]

    @Environment(\.nookResolvedTheme) private var theme

    private var slices: [ModelMixSlice] {
        models.enumerated().map { index, summary in
            ModelMixSlice(
                id: summary.modelTag,
                label: TextModelCatalog.displayName(for: summary.modelTag),
                tokens: summary.totalTokens,
                colorIndex: index
            )
        }
    }

    private var totalTokens: Int {
        max(1, models.map(\.totalTokens).reduce(0, +))
    }

    private var modelCount: Int { models.count }

    /// Ring gets thinner as slices multiply so segments stay legible, not chunky slivers.
    private var innerRadiusRatio: CGFloat {
        switch modelCount {
        case ..<4: 0.62
        case ..<7: 0.68
        case ..<10: 0.74
        default: 0.78
        }
    }

    private var angularInset: CGFloat {
        min(2.5, max(0.6, 16 / CGFloat(max(modelCount, 1))))
    }

    private var segmentCornerRadius: CGFloat {
        min(5, max(1, 30 / CGFloat(max(modelCount, 1))))
    }

    private var donutSize: CGFloat {
        switch modelCount {
        case ..<6: 88
        case ..<10: 80
        default: 72
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            donut
                .frame(width: donutSize, height: donutSize)
            legend
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var donut: some View {
        ZStack {
            Chart(slices) { slice in
                SectorMark(
                    angle: .value("Tokens", slice.tokens),
                    innerRadius: .ratio(innerRadiusRatio),
                    outerRadius: .ratio(1.0),
                    angularInset: angularInset
                )
                .cornerRadius(segmentCornerRadius)
                .foregroundStyle(PeekModelMixPalette.color(index: slice.colorIndex))
            }
            .chartLegend(.hidden)

            VStack(spacing: 1) {
                Text(TokenFormat.compact(totalTokens))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.primaryLabel)
                    .minimumScaleFactor(0.8)
                    .lineLimit(1)
                Text(peek: "Tokens")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(theme.tertiaryLabel)
            }
            .padding(.horizontal, 8)
        }
    }

    @ViewBuilder
    private var legend: some View {
        let table = VStack(alignment: .leading, spacing: 5) {
            legendHeaderRow
            ForEach(slices) { slice in
                legendDataRow(slice)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        if slices.count > 5 {
            ScrollView(.vertical, showsIndicators: false) {
                table
            }
            .frame(maxHeight: 120)
        } else {
            table
        }
    }

    private var legendHeaderRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: ModelMixTableMetrics.columnSpacing) {
            Color.clear
                .frame(width: ModelMixTableMetrics.swatchWidth)
                .peekDecorative()
            Text(peek: "Model")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(peek: "Tokens")
                .frame(width: ModelMixTableMetrics.tokensWidth, alignment: .trailing)
            Text(peek: "Share")
                .frame(width: ModelMixTableMetrics.shareWidth, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(theme.tertiaryLabel)
        .padding(.bottom, 1)
    }

    private func legendDataRow(_ slice: ModelMixSlice) -> some View {
        let share = Int((Double(slice.tokens) / Double(totalTokens) * 100).rounded())
        return HStack(alignment: .firstTextBaseline, spacing: ModelMixTableMetrics.columnSpacing) {
            Circle()
                .fill(PeekModelMixPalette.color(index: slice.colorIndex))
                .frame(width: 6, height: 6)
                .frame(width: ModelMixTableMetrics.swatchWidth)
                .peekDecorative()
            Text(slice.label)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(theme.secondaryLabel)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(TokenFormat.compact(slice.tokens))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.primaryLabel.opacity(0.95))
                .monospacedDigit()
                .frame(width: ModelMixTableMetrics.tokensWidth, alignment: .trailing)
            Text("\(share)%")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.primaryLabel.opacity(0.95))
                .monospacedDigit()
                .frame(width: ModelMixTableMetrics.shareWidth, alignment: .trailing)
        }
    }
}

private enum ModelMixTableMetrics {
    static let columnSpacing: CGFloat = 8
    static let swatchWidth: CGFloat = 10
    static let tokensWidth: CGFloat = 36
    static let shareWidth: CGFloat = 32
}
