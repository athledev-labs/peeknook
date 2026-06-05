// SPDX-License-Identifier: Apache-2.0

import PeeknookCore
import SwiftUI

extension View {
    /// Shared confirmation before pulling a vision model via Ollama.
    func peekModelDownloadConfirmation(
        pending: Binding<InferenceModelOption?>,
        onDownload: @escaping (InferenceModelOption) -> Void
    ) -> some View {
        confirmationDialog(
            pending.wrappedValue.map { "Download \($0.displayName)?" } ?? "Download model?",
            isPresented: Binding(
                get: { pending.wrappedValue != nil },
                set: { if !$0 { pending.wrappedValue = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Download") {
                if let option = pending.wrappedValue {
                    onDownload(option)
                }
                pending.wrappedValue = nil
            }
            Button("Cancel", role: .cancel) {
                pending.wrappedValue = nil
            }
        } message: {
            if let option = pending.wrappedValue {
                Text(option.downloadConfirmationMessage)
            }
        }
    }
}
