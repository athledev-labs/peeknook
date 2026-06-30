// SPDX-License-Identifier: Apache-2.0

import Foundation

#if canImport(ScreenCaptureKit) && canImport(AVFoundation)
import AVFoundation
import ScreenCaptureKit

/// Shared ScreenCaptureKit glue for the two system-audio taps — the bounded one-shot
/// ``ScreenCaptureKitSystemAudioTranscriber`` and the continuous ``RotatingSFSpeechTranscriber``.
/// Centralized so the audio-only stream configuration (`excludesCurrentProcessAudio`, the minimal video
/// footprint SCStream still requires) can never drift between them; a divergence here is how a tap ends
/// up recording the wrong process's audio. Internal + device-gated. No DECISIONS live here — this is
/// pure device glue, the thin shell both adapters share.
enum SystemAudioTap {
    /// Build an audio-only `SCStream` over the main display's shareable content (system audio is a
    /// display-scoped capture in ScreenCaptureKit).
    static func makeStream() async throws -> SCStream {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw CaptureError.failed("No display is available to capture system audio from.")
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true   // don't capture Peeknook's own output
        // Minimal video footprint: audio is what we want, but SCStream requires a video config.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        return SCStream(filter: filter, configuration: config, delegate: nil)
    }
}

/// Bridges `SCStream`'s audio sample-buffer callback to a closure that feeds a recognizer. The closure
/// runs on the stream's `sampleHandlerQueue`; an adapter that stores this output should capture `self`
/// weakly in `onAudio` so the stream → output → closure chain doesn't retain it past teardown.
final class AudioStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let onAudio: (CMSampleBuffer) -> Void

    init(onAudio: @escaping (CMSampleBuffer) -> Void) {
        self.onAudio = onAudio
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, sampleBuffer.dataReadiness == .ready else { return }
        onAudio(sampleBuffer)
    }
}
#endif
