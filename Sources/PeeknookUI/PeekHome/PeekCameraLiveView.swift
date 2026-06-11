// SPDX-License-Identifier: Apache-2.0

import PeeknookCore
import PeeknookDesign
import SwiftUI
#if canImport(AVFoundation)
import AVFoundation
#endif

/// The `.cameraLive` preview surface. Sized by the PURE, width-keyed
/// `PeekPanelLayout.cameraPreviewSize(forWidth:aspect:)` — never `visibleFrame.height` (a live
/// preview layer has no intrinsic SwiftUI size; deriving height from the screen would grow the
/// panel past the notch and evict the host top bar). Renders the live `AVCaptureSession` when the
/// active controller exposes one (`CameraPreviewLayerProviding`), else the placeholder face (the
/// stub session in test builds, or the brief moment before the session is configured).
struct PeekCameraLiveView: View {
    var orchestrator: SessionOrchestrator

    @Environment(\.nookResolvedTheme) private var theme

    var body: some View {
        let size = PeekPanelLayout.cameraPreviewSize(
            forWidth: PeekPanelLayout.cameraPreviewUsableWidth,
            aspect: previewAspect
        )
        ZStack {
            #if canImport(AVFoundation)
            if let session = previewSession {
                CameraPreviewLayer(session: session)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                placeholder
            }
            #else
            placeholder
            #endif
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(theme.tertiaryLabel.opacity(0.35), lineWidth: 1)
        )
        .frame(maxWidth: .infinity)
        .frame(height: size.height)
        .peekAction(
            label: PeekLocalized("Camera preview"),
            hint: PeekLocalized("Capture a photo from the camera")
        )
        .peekTestIdentifier(PeekTestID.cameraPreview)
    }

    private var placeholder: some View {
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
    }

    #if canImport(AVFoundation)
    private var previewSession: AVCaptureSession? {
        (orchestrator.activeCameraSession as? CameraPreviewLayerProviding)?.previewCaptureSession
    }
    #endif

    private var previewAspect: CGFloat {
        #if canImport(AVFoundation)
        (orchestrator.activeCameraSession as? CameraPreviewLayerProviding)?.previewAspect ?? 16.0 / 9.0
        #else
        16.0 / 9.0
        #endif
    }
}

#if canImport(AVFoundation)
/// Hosts an `AVCaptureVideoPreviewLayer` as the view's backing layer so it tracks the SwiftUI
/// frame for free — the EXPLICIT `.frame(height:)` above is the only thing sizing it.
private struct CameraPreviewLayer: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let layer = nsView.layer as? AVCaptureVideoPreviewLayer else { return }
        if layer.session !== session { layer.session = session }
    }
}
#endif

/// The `.cameraLive` command bar: Shutter / Cancel rendered purely from `.cameraLive` descriptors
/// via the shared ``PeekCommandBar`` — no bespoke bar code. Has its OWN dispatch: `.cancel` here
/// means `cancelCameraLive()` (tear down the live session), never the generic `cancel()`.
struct PeekCameraLiveControls: View {
    var orchestrator: SessionOrchestrator

    var body: some View {
        PeekCommandBar(
            placement: .cameraLive,
            layout: .cameraStudy,
            overrides: orchestrator.resolvedCommandOverrides(for: .cameraLive),
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
