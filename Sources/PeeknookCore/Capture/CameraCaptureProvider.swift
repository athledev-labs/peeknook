// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Camera ground provider: ONE object, TWO facets. `CaptureProviding` is the registry arm the
/// orchestrator's untouched capture path calls; `CameraSessionControlling` is the live-preview arm
/// the `.cameraLive` phase drives. One object so the still at shutter provably comes from the
/// session the user previewed.
///
/// The real AVCaptureSession body lands with camera v1's final slice. Until then every entry point
/// fails loudly — and the camera ground is unreachable in production anyway: no built-in profile
/// resolves to it and no hotkey opens it.
@MainActor
public final class CameraCaptureProvider: CameraSessionControlling, CaptureProviding {
    public init() {}

    public func startPreview() async throws {
        throw CaptureError.failed("Camera capture is not available yet.")
    }

    public func stopPreview() {
        // Idempotent no-op until the AVCaptureSession body lands.
    }

    public func captureStill() async throws -> CaptureResult {
        throw CaptureError.failed("Camera capture is not available yet.")
    }

    public func capture(scope: CaptureScope, quick: Bool) async throws -> CaptureResult {
        _ = (scope, quick)   // screen concepts; the camera ground ignores both by design
        return try await captureStill()
    }
}
