// SPDX-License-Identifier: Apache-2.0

import PeeknookCore
import PeeknookDesign
import SwiftUI

/// The `.cameraLive` preview surface. Sized by the PURE, width-keyed
/// `PeekPanelLayout.cameraPreviewSize(forWidth:aspect:)` — never `visibleFrame.height` (a live
/// preview layer has no intrinsic SwiftUI size; deriving height from the screen would grow the
/// panel past the notch and evict the host top bar). Until the real `AVCaptureSession` lands this
/// renders the placeholder face; the layer swap stays contained to this view.
struct PeekCameraLiveView: View {
    var orchestrator: SessionOrchestrator

    @Environment(\.nookResolvedTheme) private var theme

    var body: some View {
        let size = PeekPanelLayout.cameraPreviewSize(forWidth: PeekPanelLayout.cameraPreviewUsableWidth)
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.tertiaryLabel.opacity(0.08))
            VStack(spacing: 6) {
                Image(systemName: "camera")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(theme.secondaryLabel)
                    .peekDecorative()
                // Plain, non-shimmer label: a shimmer over a live feed reads as "still loading"
                // and would mis-mark the surface as loading for VoiceOver.
                Text(peek: "Camera preview")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.secondaryLabel)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(theme.tertiaryLabel.opacity(0.35), lineWidth: 1)
        )
        .frame(maxWidth: .infinity)
        .frame(height: size.height)
        .peekTestIdentifier(PeekTestID.cameraPreview)
    }
}

/// The `.cameraLive` command bar: Shutter / Cancel rendered purely from `.cameraLive` descriptors
/// via the shared ``PeekCommandBar`` — no bespoke bar code. Has its OWN dispatch: `.cancel` here
/// means `cancelCameraLive()` (tear down the live session), never the generic `cancel()`.
struct PeekCameraLiveControls: View {
    var orchestrator: SessionOrchestrator

    var body: some View {
        PeekCommandBar(
            placement: .cameraLive,
            layout: .cameraStudy,
            context: commandContext,
            dispatch: { action in
                switch action {
                case .shutter: orchestrator.shutter()
                case .cancel: orchestrator.cancelCameraLive()
                default: break
                }
            }
        )
    }

    /// THE single profile-source rule: the live-camera surface gates against the `camera.study`
    /// profile literal — never the active profile, which stays `screen.default` in v1 (⌘⇧C is
    /// event-scoped). Gating on the active profile would hide Shutter and orphan the live camera.
    /// `isReady` stays true until Camera-TCC readiness lands with the reachability slice (the
    /// surface is unreachable in production until that same slice).
    private var commandContext: CommandBarContext {
        CommandBarContext(
            isReady: true,
            enabledModules: Set(ModuleID.allCases.filter {
                Module.isEnabled($0, in: orchestrator.settings, profile: .cameraStudy)
            })
        )
    }
}
