// SPDX-License-Identifier: Apache-2.0

import PeeknookDesign
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

/// Stacked usage through the thread, tap a bar for a breakdown.
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

/// Expanded usage for one answer, shown when a chart bar is selected.
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

/// Warning when the opt-in conversation archive fails to save on disk.
struct PeekArchivePersistenceBanner: View {
    @Environment(\.nookResolvedTheme) private var theme
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.orange)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text("Couldn't save chat")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.primaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                NookToolbarButton(
                    title: "Dismiss",
                    symbol: "xmark",
                    help: "Hide this warning",
                    action: onDismiss
                )
                .padding(.top, 1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.subtleFill.opacity(0.28), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Couldn't save chat. \(message)")
    }
}

/// Proactive nudge shown *before* the next capture/follow-up when the chat is near the model's
/// context window. Reuses `PeekContextTint` for color and a `SessionFailure`-style recovery layout,
/// steering the user toward a new chat (the only reliable reset). Hidden while pressure is `.normal`.
struct PeekContextWarningBanner: View {
    @Environment(\.nookResolvedTheme) private var theme
    let pressure: SessionOrchestrator.ContextPressure
    let fraction: Double
    let onStartNewChat: () -> Void

    var body: some View {
        if pressure == .normal {
            EmptyView()
        } else {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "gauge.with.dots.needle.100percent")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.primaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                    NookToolbarButton(
                        title: "New chat",
                        symbol: "arrow.counterclockwise",
                        help: "Start a fresh chat to reset the context window",
                        prominent: true,
                        action: onStartNewChat
                    )
                    .padding(.top, 1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.subtleFill.opacity(0.28), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(tint.opacity(0.3), lineWidth: 1)
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(title). \(message)")
        }
    }

    private var tint: Color { PeekContextTint.color(for: fraction) }

    private var title: String {
        pressure == .critical ? "Context window nearly full" : "Context window filling up"
    }

    private var message: String {
        pressure == .critical
            ? "Another capture or follow-up may drop earlier detail from this chat. Start fresh for best results."
            : "This chat is getting long. Answers stay sharpest in a fresh chat once the window fills."
    }
}

/// Context-usage bar color that warms as the prompt fills the model's window, plenty of room
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

/// Live context window meter for the active chat, shown above result content (not in the command bar).
struct PeekContextMeter: View {
    @Environment(\.nookResolvedTheme) private var theme
    let used: Int
    let total: Int

    var body: some View {
        let fraction = min(1, Double(used) / Double(max(total, 1)))
        HStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 9))
                .foregroundStyle(theme.quaternaryLabel)
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .frame(maxWidth: 72)
                .tint(PeekContextTint.color(for: fraction))
            Text("\(TokenFormat.compact(used)) / \(TokenFormat.compact(total)) context")
                .font(.system(size: 9))
                .foregroundStyle(theme.tertiaryLabel)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .help("\(used) / \(total) tokens in context for this chat")
    }
}
