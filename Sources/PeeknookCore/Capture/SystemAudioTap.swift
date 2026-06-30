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
public enum SystemAudioTap {
    /// Build an audio-only `SCStream` over the main display's shareable content (system audio is a
    /// display-scoped capture in ScreenCaptureKit).
    ///
    /// `sampleRate` / `channelCount` are applied to the stream config when provided. The SFSpeech tap
    /// leaves them nil (SCStream's 48 kHz stereo default, which `SFSpeechRecognizer` resamples itself);
    /// the Whisper tap requests 16 kHz mono so the buffers arrive in exactly Whisper's expected format and
    /// no resampling step is needed. `public` so the isolated `PeeknookWhisper` target reuses this one
    /// audio-config choke point rather than duplicating it (a divergence here records the wrong audio).
    public static func makeStream(sampleRate: Int? = nil, channelCount: Int? = nil) async throws -> SCStream {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw CaptureError.failed("No display is available to capture system audio from.")
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true   // don't capture Peeknook's own output
        if let sampleRate { config.sampleRate = sampleRate }
        if let channelCount { config.channelCount = channelCount }
        // Minimal video footprint: audio is what we want, but SCStream requires a video config.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        return SCStream(filter: filter, configuration: config, delegate: nil)
    }

    /// Read linear-PCM Float32 samples (all channels, interleaved) out of an SCStream audio buffer. The
    /// lone piece of untestable device glue both taps share: an unexpected format returns no samples (the
    /// caller reads silence) rather than reinterpreting bytes into a garbage signal. When the stream was
    /// configured mono (the Whisper tap) this is already a mono 16 kHz array ready for `transcribe`.
    public static func floatSamples(from sampleBuffer: CMSampleBuffer) -> [Float] {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
              asbd.mBitsPerChannel == 32 else {
            return []
        }
        let channels = max(1, Int(asbd.mChannelsPerFrame))
        let bufferList = AudioBufferList.allocate(maximumBuffers: channels)
        defer { free(bufferList.unsafeMutablePointer) }
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferList.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: channels),
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, blockBuffer != nil else { return [] }
        var samples: [Float] = []
        for buffer in bufferList {
            guard let data = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let pointer = data.assumingMemoryBound(to: Float.self)
            samples.append(contentsOf: UnsafeBufferPointer(start: pointer, count: count))
        }
        return samples
    }
}

/// Bridges `SCStream`'s audio sample-buffer callback to a closure that feeds a recognizer. The closure
/// runs on the stream's `sampleHandlerQueue`; an adapter that stores this output should capture `self`
/// weakly in `onAudio` so the stream → output → closure chain doesn't retain it past teardown.
public final class AudioStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let onAudio: (CMSampleBuffer) -> Void

    public init(onAudio: @escaping (CMSampleBuffer) -> Void) {
        self.onAudio = onAudio
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, sampleBuffer.dataReadiness == .ready else { return }
        onAudio(sampleBuffer)
    }
}
#endif
