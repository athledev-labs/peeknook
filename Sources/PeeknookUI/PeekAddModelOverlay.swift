// SPDX-License-Identifier: Apache-2.0

import NookApp
import PeeknookCore
import SwiftUI

extension View {
    /// In-notch sheet for adding any Ollama model tag (bring-your-own-model). Presented as a
    /// contained glass overlay like ``peekModelDownloadConfirmation`` so the scrim stays bounded by
    /// the panel. Apply to a surface that fills the panel so the card centers.
    func peekAddModelOverlay(
        isPresented: Binding<Bool>,
        onAdd: @escaping (String) -> Void
    ) -> some View {
        modifier(PeekAddModelOverlayModifier(isPresented: isPresented, onAdd: onAdd))
    }
}

private struct PeekAddModelOverlayModifier: ViewModifier {
    @Binding var isPresented: Bool
    let onAdd: (String) -> Void

    func body(content: Content) -> some View {
        content.overlay {
            if isPresented {
                PeekAddModelOverlay(
                    onAdd: { tag in
                        onAdd(tag)
                        isPresented = false
                    },
                    onCancel: { isPresented = false }
                )
            }
        }
        .animation(.easeOut(duration: 0.15), value: isPresented)
    }
}

struct PeekAddModelOverlay: View {
    var onAdd: (String) -> Void
    var onCancel: () -> Void

    @Environment(\.nookResolvedTheme) private var theme
    @State private var tag = ""
    @FocusState private var fieldFocused: Bool

    private var trimmedTag: String {
        tag.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.4))
                .contentShape(Rectangle())
                .onTapGesture(perform: onCancel)

            VStack(alignment: .leading, spacing: 10) {
                Text("Add a model")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.primaryLabel)
                Text("Type any Ollama tag to test it in your notch. Peek pulls it via Ollama if it isn't installed yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("e.g. qwen3-vl:8b", text: $tag)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(theme.primaryLabel.opacity(0.95))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(theme.subtleFill.opacity(0.55), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(theme.subtleStroke.opacity(0.45), lineWidth: 1)
                    )
                    .focused($fieldFocused)
                    .onSubmit(submit)

                Text("Peeknook sends a screenshot, so pick a model that supports vision (image input).")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.tertiaryLabel)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    NookToolbarButton(title: "Cancel", symbol: "xmark", action: onCancel)
                    NookToolbarButton(title: "Add", symbol: "plus", prominent: true, action: submit)
                        .disabled(trimmedTag.isEmpty)
                }
            }
            .padding(14)
            .frame(maxWidth: 300)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(0.55))
                    PeekCommandPillGlass(cornerRadius: 12)
                }
            }
            .padding(16)
        }
        .transition(.opacity)
        .onAppear { fieldFocused = true }
    }

    private func submit() {
        guard !trimmedTag.isEmpty else { return }
        onAdd(trimmedTag)
    }
}
