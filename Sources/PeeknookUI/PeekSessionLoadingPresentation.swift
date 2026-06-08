// SPDX-License-Identifier: Apache-2.0

import PeeknookCore
import SwiftUI

/// One source of truth for the honest loading copy shown while a session is active, resolved from
/// the orchestrator's *real* warm / streaming / web-lookup flags rather than a timer. Shared by the
/// Home phase content and the compact glyph so neither drifts or fakes an "Analyzing…" state (see
/// the warm-model invariant in CLAUDE.md).
///
/// Copy here is intentionally un-localized for now — it consolidates strings that are still
/// hardcoded English across the UI, giving the later localization pass (Tier B) a single file to
/// migrate instead of scattered `Text` literals.
struct PeekSessionLoadingPresentation: Equatable {
    /// Short status line, e.g. "Reading the screen…".
    var label: String
    /// SF Symbol paired with the label.
    var symbol: String
    /// Shimmer the label — a "still working, nothing streamed yet" stage — versus a calm streaming
    /// label once tokens are arriving.
    var shimmers: Bool

    /// The active loading presentation for the current phase, or `nil` when the phase isn't a
    /// capture/inference stage (idle / previewing / result / failed render their own UI).
    @MainActor
    static func resolve(for orchestrator: SessionOrchestrator) -> PeekSessionLoadingPresentation? {
        switch orchestrator.phase {
        case .capturing:
            return .init(label: "Capturing the screen…", symbol: "camera.viewfinder", shimmers: true)
        case .inferring:
            // Tokens are streaming — calm, non-shimmer label.
            if !orchestrator.streamedAnswer.isEmpty {
                return .init(label: "Answering…", symbol: "sparkles", shimmers: false)
            }
            // Pre-stream stages, in the order runTurn hits them.
            if orchestrator.isFetchingWebLookup {
                return .init(label: "Looking up on the web…", symbol: "globe", shimmers: true)
            }
            if orchestrator.inferenceModelWasWarm {
                return .init(label: "Reading the screen…", symbol: "viewfinder", shimmers: true)
            }
            return .init(label: "Loading the model, first run is slower…", symbol: "hourglass", shimmers: true)
        default:
            return nil
        }
    }
}
