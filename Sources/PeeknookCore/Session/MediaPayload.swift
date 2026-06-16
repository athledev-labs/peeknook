// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One leg of a multi-ground turn, assembled in memory for inference.
///
/// A single question can combine several grounds at once — screen + camera today; screen + camera +
/// an imported file or (once "hear" lands) an on-device audio transcript, in any combination. Those
/// legs persist as sibling `.image` ``ChatTurn``s sharing a `compositeGroupID`; at inference time the
/// coordinator projects each leg of a group into a `MediaPayload` so the prompt builder and the wire
/// message can treat an N-ground turn uniformly, in order, instead of hard-coding the screen/camera
/// pair.
///
/// In-memory only — never `Codable`. The archive keeps the per-leg ``CaptureResult``; this is the
/// transient assembly view re-derived each turn (the same discipline as ``InferenceMessage``).
public struct MediaPayload: Sendable, Equatable {
    /// The modality of a leg. Image legs ship as vision payloads; `.transcript` is the forward seam
    /// for an audio ground ("hear"): an on-device transcript that rides as text, never as an image
    /// payload and never over the network.
    public enum Kind: Sendable, Equatable {
        /// A screenshot, camera photo, or imported-file image — rides as a vision payload.
        case image
        /// On-device transcript of an audio leg. Rides as supplementary text, contributes no image.
        case transcript
    }

    /// The source leg: provenance (`sourceLabel` / `appName` / `windowTitle`), supplementary `text`,
    /// and `ground`. The prompt builder describes the leg from this.
    public let capture: CaptureResult
    public let kind: Kind
    /// Resolved JPEG base64 for an `.image` leg that is inside this turn's replay budget; `nil` when
    /// the leg carries no image, is out of the replay budget, or is a non-image modality.
    public let imageBase64: String?

    public var ground: Ground { capture.ground }

    public init(capture: CaptureResult, kind: Kind = .image, imageBase64: String? = nil) {
        self.capture = capture
        self.kind = kind
        self.imageBase64 = imageBase64
    }
}
