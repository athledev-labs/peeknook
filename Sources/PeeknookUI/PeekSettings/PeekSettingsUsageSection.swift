// SPDX-License-Identifier: Apache-2.0

import PeeknookCore
import SwiftUI

struct PeekSettingsUsageSection: View {
    var stats: UsageStats
    var onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PeekSettingsValueRow(label: "Captures", value: "\(stats.captures)")
            PeekSettingsValueRow(label: "Screen data", value: String(format: "%.1f MB", stats.imageMegabytes))
            PeekSettingsValueRow(
                label: "Model usage",
                value: "\(stats.promptTokens.formatted()) in · \(stats.responseTokens.formatted()) out"
            )
            PeekSettingsValueRow(
                label: "Response speed",
                value: stats.averageTokensPerSecond > 0
                    ? String(format: "~%.0f (higher is faster)", stats.averageTokensPerSecond)
                    : "—"
            )

            PeekSettingsCommandRow(
                icon: "arrow.counterclockwise",
                title: "Reset stats",
                subtitle: "Clear counters on this Mac",
                style: .destructive,
                trailing: .button("Reset"),
                action: onReset
            )
        }
    }
}
