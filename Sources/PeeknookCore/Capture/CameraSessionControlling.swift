// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Live-preview control seam for the camera ground. A sibling of `CaptureProviding` — the one-shot
/// `capture(scope:quick:)` cannot express a running camera session, so the orchestrator drives the
/// pre-capture live feed through this protocol while the registry's untouched capture arm handles
/// everything post-shutter. `@MainActor` because session start/stop must serialize with the UI
/// lifecycle; `AnyObject` because teardown is identity-based (the orchestrator must stop exactly
/// the session it started).
@MainActor
public protocol CameraSessionControlling: AnyObject {
    /// Build and start the live session. Throws when the camera is unavailable or not authorized.
    func startPreview() async throws
    /// Stop the live session and turn the camera off. MUST be idempotent: the session's exit path
    /// and the host's nook-collapse teardown can both fire for the same exit.
    func stopPreview()
    /// Capture a still from the running session as a `CaptureResult` with `ground == .camera`.
    func captureStill(encoding: CaptureEncodingParams) async throws -> CaptureResult
}

// MARK: - Test-only stub

/// Deterministic camera double for unit tests and the UI test host, mirroring `StubCaptureProvider`.
/// Conforms to both camera facets so it can stand in for `CameraCaptureProvider` everywhere.
@MainActor
public final class StubCameraSession: CameraSessionControlling, CaptureProviding {
    public private(set) var startPreviewCount = 0
    public private(set) var stopPreviewCount = 0
    public private(set) var captureStillCount = 0
    public private(set) var isPreviewing = false
    /// When set, `startPreview()` throws it (permission-denied / device-missing simulation).
    public var startPreviewError: Error?
    /// When set, `captureStill()` throws it.
    public var captureStillError: Error?
    /// When set, `captureStill()` awaits this long first (for cancellation-race tests).
    public var captureDelayNanoseconds: UInt64?
    public var stillBase64: String

    public init(stillBase64: String = StubCaptureProvider.defaultScreenshotBase64) {
        self.stillBase64 = stillBase64
    }

    public func startPreview() async throws {
        startPreviewCount += 1
        if let startPreviewError { throw startPreviewError }
        isPreviewing = true
    }

    public func stopPreview() {
        // Counts every call so tests can assert idempotence as state, not crash on a double stop.
        stopPreviewCount += 1
        isPreviewing = false
    }

    public func captureStill(encoding: CaptureEncodingParams) async throws -> CaptureResult {
        _ = encoding
        captureStillCount += 1
        if let captureStillError { throw captureStillError }
        if let captureDelayNanoseconds {
            try await Task.sleep(nanoseconds: captureDelayNanoseconds)
            try Task.checkCancellation()
        }
        guard isPreviewing else { throw CaptureError.failed("Camera preview is not running.") }
        return CaptureResult(
            text: nil,
            sourceLabel: "Camera (live)",
            screenshotBase64: stillBase64,
            ground: .camera
        )
    }

    public func capture(
        scope: CaptureScope,
        quick: Bool,
        encoding: CaptureEncodingParams
    ) async throws -> CaptureResult {
        _ = (scope, quick)   // screen concepts; the camera ground ignores both by design
        return try await captureStill(encoding: encoding)
    }
}
