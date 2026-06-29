// SPDX-License-Identifier: Apache-2.0

import PeeknookCore
import SwiftUI

public struct PeekCompactView: View {
    public var orchestrator: SessionOrchestrator
    public var setup: SetupCoordinator
    /// Expand the nook to Home so the user can read the answer / continue the chat. Wired by the
    /// module to the `AppCoordinator`. Safe: expanding never discards the thread.
    public var onExpand: (() -> Void)?

    public init(
        orchestrator: SessionOrchestrator,
        setup: SetupCoordinator,
        onExpand: (() -> Void)? = nil
    ) {
        self.orchestrator = orchestrator
        self.setup = setup
        self.onExpand = onExpand
    }

    public var body: some View {
        Button(action: handleTap) {
            // `sparkles.rectangle.stack` is a busy, multi-part glyph: its ink is spread across thin
            // strokes, so it optically reads smaller and lighter than the host's solid `house` mark in
            // the opposite compact slot, even though SF Symbols size to cap-height. Bold thickens the
            // strokes (the biggest lever for a fine symbol) and a slightly larger size balances the two.
            Image(systemName: glyphName)
                .font(.system(size: 14, weight: .bold))
                .symbolEffect(.pulse, isActive: isBusy)
        }
        .buttonStyle(.plain)
        .disabled(!setup.isReady && orchestrator.phase == .idle)
        .help(helpText)
        // Single-image button: a plain label (vs `peekAction`, which collapses a multi-child
        // icon+text subtree) keeps the Button's native activation and disabled state intact for
        // VoiceOver, while naming the otherwise-unlabeled glyph. `help` supplies the hint.
        .accessibilityLabel(Text(voiceOverLabel))
    }

    /// idle → capture, failed → retry, result → expand to read/continue (no thread loss).
    /// Previewing auto-expands via the module; capturing/inferring no-op (busy).
    private func handleTap() {
        switch orchestrator.phase {
        case .idle:
            orchestrator.beginCapture()
        case .failed:
            orchestrator.retryAfterFailure()
        case .result:
            onExpand?()
        default:
            break
        }
    }

    private var glyphName: String {
        orchestrator.settings.mode.symbolName
    }

    /// Non-nil exactly during the capture/inference stages, so it doubles as the "busy" signal.
    private var loadingPresentation: PeekSessionLoadingPresentation? {
        PeekSessionLoadingPresentation.resolve(for: orchestrator)
    }

    private var isBusy: Bool {
        loadingPresentation != nil
    }

    private var helpText: String {
        if let presentation = loadingPresentation { return presentation.label }
        switch orchestrator.phase {
        case .idle:
            return setup.isReady
                ? "Capture & answer (\(orchestrator.settings.captureHotkey.display))"
                : "Finish setup first"
        case .previewing:
            return "Opening preview to confirm"
        case .cameraLive:
            return "Live camera preview open"
        case .captioning:
            return "Live captions on"
        case .result:
            return "Answer ready, tap to expand"
        case .failed(let failure):
            return failure.title
        case .capturing, .inferring:
            return "" // unreachable: loadingPresentation is non-nil for these
        }
    }

    /// Concise VoiceOver label describing what a tap *does* in the current phase (the longer
    /// ``helpText`` rides as the hint).
    private var voiceOverLabel: String {
        switch orchestrator.phase {
        case .idle:
            return setup.isReady ? "Capture and answer" : "Finish setup first"
        case .failed:
            return "Retry capture"
        case .result:
            return "Open answer"
        case .cameraLive:
            return "Live camera preview"
        case .captioning:
            return "Live captions"
        case .capturing, .inferring, .previewing:
            return loadingPresentation?.label ?? "Opening preview to confirm"
        }
    }
}
