// SPDX-License-Identifier: Apache-2.0

import NookApp
import PeeknookCore
import SwiftUI

/// Compact per-turn usage chip for History (cumulative context, delta, suggestion pass).
struct TurnUsageChip: View {
    @Environment(\.nookResolvedTheme) private var theme
    let usage: TurnUsage
    let promptDelta: Int
    let isFirstAnswer: Bool

    var body: some View {
        HStack(spacing: 8) {
            if let fraction = usage.contextFraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 44)
                    .tint(PeekContextTint.color(for: fraction))
            }
            Text(usageSummary)
                .font(.system(size: 9))
                .foregroundStyle(theme.tertiaryLabel)
                .lineLimit(2)
        }
        .help(helpText)
    }

    private var usageSummary: String {
        let prompt = TokenFormat.compact(usage.promptTokens)
        let out = TokenFormat.compact(usage.responseTokens)
        var parts: [String] = []
        if !isFirstAnswer, promptDelta > 0 {
            parts.append("+\(TokenFormat.compact(promptDelta)) since last")
        }
        parts.append("\(prompt) context · \(out) out")
        if let suggestion = usage.suggestionPass, suggestion.promptTokens > 0 || suggestion.responseTokens > 0 {
            parts.append(
                "pills +\(TokenFormat.compact(suggestion.promptTokens))/\(TokenFormat.compact(suggestion.responseTokens))"
            )
        }
        return parts.joined(separator: " · ")
    }

    private var helpText: String {
        var lines = [
            "Answer pass: \(usage.promptTokens) prompt tokens (full thread so far), \(usage.responseTokens) generated.",
        ]
        if !isFirstAnswer, promptDelta > 0 {
            lines.append("+\(promptDelta) prompt tokens vs the previous answer.")
        }
        if let suggestion = usage.suggestionPass {
            lines.append(
                "Suggestion pass: \(suggestion.promptTokens) prompt, \(suggestion.responseTokens) out (separate call for action pills)."
            )
        }
        return lines.joined(separator: " ")
    }
}

/// Stacked usage through the thread — tap a bar for a breakdown.
struct ContextThreadChart: View {
    @Environment(\.nookResolvedTheme) private var theme
    let points: [TurnUsageTimeline.Point]
    @State private var selectedID: Int?

    var body: some View {
        if points.isEmpty { EmptyView() } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Context through this chat")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.tertiaryLabel)
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(points) { point in
                        bar(for: point)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let selected = points.first(where: { $0.id == selectedID }) {
                    TurnUsageBreakdown(point: selected, onClose: { selectedID = nil })
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                Text("Tap a bar for a breakdown · bars = prompt size per answer (full thread)")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.quaternaryLabel)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(theme.tertiaryLabel.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .animation(.easeOut(duration: 0.18), value: selectedID)
        }
    }

    private func bar(for point: TurnUsageTimeline.Point) -> some View {
        let isSelected = selectedID == point.id
        return Button {
            withAnimation(.easeOut(duration: 0.18)) {
                selectedID = selectedID == point.id ? nil : point.id
            }
        } label: {
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(barColor(for: point, selected: isSelected))
                    .frame(width: 28, height: max(6, 52 * CGFloat(point.fraction)))
                Text(point.label)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(isSelected ? theme.primaryLabel : theme.tertiaryLabel)
            }
        }
        .buttonStyle(.plain)
    }

    private func barColor(for point: TurnUsageTimeline.Point, selected: Bool) -> Color {
        if selected { return Color.accentColor.opacity(0.85) }
        return PeekContextTint.color(for: point.fraction)
    }
}

/// Expanded usage for one answer — shown when a chart bar is selected.
struct TurnUsageBreakdown: View {
    @Environment(\.nookResolvedTheme) private var theme
    let point: TurnUsageTimeline.Point
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(point.label) breakdown")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.secondaryLabel)
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.tertiaryLabel)
                }
                .buttonStyle(.plain)
            }
            breakdownRow("Answer prompt", value: TokenFormat.compact(point.usage.promptTokens), detail: "Full thread sent to the model")
            if point.promptDelta > 0 {
                breakdownRow("Since last answer", value: "+\(TokenFormat.compact(point.promptDelta))", detail: nil)
            }
            breakdownRow("Answer generated", value: TokenFormat.compact(point.usage.responseTokens), detail: nil)
            if point.usage.generationSeconds > 0 {
                breakdownRow("Answer time", value: String(format: "%.1fs", point.usage.generationSeconds), detail: nil)
            }
            if let fraction = point.usage.contextFraction {
                breakdownRow(
                    "Context used",
                    value: String(format: "%.0f%%", fraction * 100),
                    detail: point.usage.contextWindow.map { "of \(TokenFormat.compact($0)) window" }
                )
            }
            if let suggestion = point.usage.suggestionPass,
               suggestion.promptTokens > 0 || suggestion.responseTokens > 0 {
                breakdownRow(
                    "Suggestion pass",
                    value: "\(TokenFormat.compact(suggestion.promptTokens)) in · \(TokenFormat.compact(suggestion.responseTokens)) out",
                    detail: "Separate call for action pills"
                )
            }
        }
        .padding(8)
        .background(theme.tertiaryLabel.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func breakdownRow(_ title: String, value: String, detail: String?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(theme.tertiaryLabel)
                .frame(width: 92, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(theme.primaryLabel)
                if let detail {
                    Text(detail)
                        .font(.system(size: 8))
                        .foregroundStyle(theme.quaternaryLabel)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

enum TokenFormat {
    static func compact(_ n: Int) -> String {
        let k = Double(n) / 1024
        if k < 1 { return "\(n)" }
        return k >= 10 ? String(format: "%.0fK", k) : String(format: "%.1fK", k)
    }
}

/// Context-usage bar color that warms as the prompt fills the model's window — plenty of room
/// reads calm green, near-full reads red (Claude-style). One source of truth for every meter.
enum PeekContextTint {
    static func color(for fraction: Double) -> Color {
        switch fraction {
        case ..<0.6: Color.green.opacity(0.75)
        case ..<0.8: Color.yellow.opacity(0.85)
        case ..<0.9: Color.orange
        default: Color.red.opacity(0.9)
        }
    }
}
