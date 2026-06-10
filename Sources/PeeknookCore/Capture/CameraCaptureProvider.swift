// SPDX-License-Identifier: Apache-2.0

import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

#if canImport(AVFoundation)
/// UI render seam: the live-preview layer needs the raw `AVCaptureSession`, which deliberately
/// stays OFF `CameraSessionControlling` (the orchestrator's seam is render-free). The camera view
/// downcasts the active session to this; the unit-test stub does not conform, so test builds render
/// the placeholder face.
@MainActor
public protocol CameraPreviewLayerProviding: AnyObject {
    /// The running session for an `AVCaptureVideoPreviewLayer`, or nil before configuration.
    var previewCaptureSession: AVCaptureSession? { get }
    /// Width/height of the active camera format, feeding the pure width-keyed height function.
    var previewAspect: CGFloat { get }
}
#endif

/// Camera ground provider: ONE object, TWO facets. `CaptureProviding` is the registry arm the
/// orchestrator's untouched capture path calls; `CameraSessionControlling` is the live-preview arm
/// the `.cameraLive` phase drives. One object so the still at shutter provably comes from the
/// session the user previewed.
@MainActor
public final class CameraCaptureProvider: CameraSessionControlling, CaptureProviding {
    #if canImport(AVFoundation)
    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private var isConfigured = false
    /// Strong-held bridge for the in-flight still — `AVCapturePhotoOutput` keeps only a weak ref.
    private var photoDelegate: PhotoCaptureDelegate?
    #endif

    public init() {}

    public func startPreview() async throws {
        #if canImport(AVFoundation)
        // Explicit preflight: the orchestrator gates on readiness first, but never let
        // AVFoundation's implicit consent prompt race the phase transition.
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw CaptureError.permissionRequired(CapturePermission.camera.displayName)
        }
        if !isConfigured {
            try configureSession()
            isConfigured = true
        }
        guard !session.isRunning else { return }   // idempotent
        // startRunning() blocks; hop off the main actor so the notch never freezes.
        let box = SessionBox(session)
        await Task.detached { box.session.startRunning() }.value
        #else
        throw CaptureError.failed("Camera capture requires AVFoundation.")
        #endif
    }

    public func stopPreview() {
        #if canImport(AVFoundation)
        guard session.isRunning else { return }    // idempotent — exit path + collapse may both fire
        let box = SessionBox(session)
        Task.detached { box.session.stopRunning() }   // blocking call; the camera light goes out with it
        #endif
    }

    public func captureStill() async throws -> CaptureResult {
        #if canImport(AVFoundation)
        guard session.isRunning else { throw CaptureError.failed("Camera preview is not running.") }
        let base64 = try await capturePhotoJPEGBase64()
        guard !base64.isEmpty else {
            throw CaptureError.failed("Captured a camera frame but couldn't encode it. Try again.")
        }
        return CaptureResult(
            text: nil,
            sourceLabel: "Camera (live)",
            screenshotBase64: base64,
            ground: .camera
        )
        #else
        throw CaptureError.failed("Camera capture requires AVFoundation.")
        #endif
    }

    public func capture(scope: CaptureScope, quick: Bool) async throws -> CaptureResult {
        _ = (scope, quick)   // screen concepts; the camera ground ignores both by design
        return try await captureStill()
    }

    #if canImport(AVFoundation)
    private func configureSession() throws {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            throw CaptureError.failed("No camera is available on this Mac.")
        }
        session.beginConfiguration()
        session.sessionPreset = .photo
        guard session.canAddInput(input), session.canAddOutput(photoOutput) else {
            session.commitConfiguration()
            throw CaptureError.failed("The camera could not be configured.")
        }
        session.addInput(input)
        session.addOutput(photoOutput)
        session.commitConfiguration()
    }

    /// The still, already JPEG-encoded on the delegate's queue (same `CaptureImageEncoder` and
    /// 1280px cap as screen captures) so only a `String` ever crosses back to the main actor.
    private func capturePhotoJPEGBase64() async throws -> String {
        defer { photoDelegate = nil }
        return try await withCheckedThrowingContinuation { continuation in
            let delegate = PhotoCaptureDelegate { result in
                continuation.resume(with: result)
            }
            photoDelegate = delegate
            photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: delegate)
        }
    }
    #endif
}

#if canImport(AVFoundation)
extension CameraCaptureProvider: CameraPreviewLayerProviding {
    public var previewCaptureSession: AVCaptureSession? {
        isConfigured ? session : nil
    }

    public var previewAspect: CGFloat {
        let formats = session.inputs.compactMap { ($0 as? AVCaptureDeviceInput)?.device.activeFormat }
        guard let format = formats.first else { return 16.0 / 9.0 }
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        guard dims.height > 0 else { return 16.0 / 9.0 }
        return CGFloat(dims.width) / CGFloat(dims.height)
    }
}

/// `AVCaptureSession` start/stop must run off the main actor but the type predates Sendable;
/// the session is only ever touched by one call at a time through the @MainActor provider.
private struct SessionBox: @unchecked Sendable {
    let session: AVCaptureSession
    init(_ session: AVCaptureSession) { self.session = session }
}

/// Bridges `AVCapturePhotoOutput`'s delegate callback (arbitrary queue) to async/await, encoding
/// the JPEG before resuming so no image type crosses an isolation boundary.
private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let completion: (Result<String, Error>) -> Void

    init(completion: @escaping (Result<String, Error>) -> Void) {
        self.completion = completion
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            completion(.failure(error))
            return
        }
        guard let cgImage = photo.cgImageRepresentation(),
              let base64 = CaptureImageEncoder.jpegBase64(from: cgImage) else {
            completion(.failure(CaptureError.failed("The camera returned an empty frame.")))
            return
        }
        completion(.success(base64))
    }
}
#endif
