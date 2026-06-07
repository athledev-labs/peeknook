// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct PeekSettingsDataSection: View {
    var onReset: () -> Void
    @State private var showsResetConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PeekSettingsNote(text: "Charts and breakdowns are in Stats on the home screen.")

            PeekSettingsCommandRow(
                icon: "arrow.counterclockwise",
                title: "Reset stats",
                subtitle: "Clear counters on this Mac",
                style: .destructive,
                trailing: .button("Reset"),
                action: { showsResetConfirmation = true }
            )
        }
        .confirmationDialog(
            "Reset usage stats?",
            isPresented: $showsResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset stats", role: .destructive, action: onReset)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clears capture counts, token totals, and history on this Mac. You can't undo it.")
        }
    }
}
