// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Per-ground prompt copy — the single source of truth for how a ground is *described to the model*,
/// alongside its permissions and modality on the same type. Every property below is an exhaustive
/// `switch self` with NO `default:` arm, so adding a ``Ground`` is a compile error here, not a silent
/// fallback to screenshot wording. ``PromptBuilder`` sources only the *wording* from these; whether a
/// leg actually carries an image stays with ``MediaPayload/Kind/resolved(for:)`` and the builder's
/// `hasVision` / `leg.kind` gates.
extension Ground {
    /// The "Ground: <x> …" disambiguation sentence in the single-leg capture block. `nil` for
    /// `.screen` (the default modality needs no qualifier). The camera/file/system-audio copy is the
    /// exact text used before this was centralized; the never-shipped grounds get honest forward copy.
    var promptGroundLine: String? {
        switch self {
        case .screen:
            return nil
        case .camera:
            return "Ground: camera — the attached image is a photo from the Mac's camera (paper, whiteboard, book, or a physical object), not a screenshot of the display."
        case .file:
            return "Ground: imported file — the attached image is a page or image from a file the user opened from disk (e.g. a PDF page or a saved image), not a live capture of the current screen."
        case .systemAudio:
            return "Ground: system audio — the text below is an on-device transcript of what was playing through the Mac (a meeting, video, or call). There is NO image; answer from the transcript."
        case .selectedText:
            return "Ground: selected text — the text below is what the user selected on screen. There is NO image; answer from the selected text."
        case .voiceInput:
            return "Ground: voice input — the text below is an on-device transcript of the user's own dictation. There is NO image; answer from the dictation."
        case .agent:
            return "Ground: agent — the text below is the result from a sidecar agent the user ran. There is NO image; answer from the agent's result."
        }
    }

    /// The "A <x> is attached … (vision)." sentence, used only when the leg actually carries an image
    /// (the builder gates this on `hasVision`). Text-only grounds return a no-image phrasing for the
    /// rare case a caller emits it without the vision gate; they should never be reached through the
    /// gate today.
    var promptVisionAttachmentSentence: String {
        switch self {
        case .screen:
            return "A screenshot is attached to this message (vision)."
        case .camera:
            return "A camera photo is attached to this message (vision)."
        case .file:
            return "An image from the imported file is attached to this message (vision)."
        case .systemAudio:
            return "No image is attached — the system-audio transcript below is the content."
        case .selectedText:
            return "No image is attached — the selected text below is the content."
        case .voiceInput:
            return "No image is attached — the dictation transcript below is the content."
        case .agent:
            return "No image is attached — the agent result below is the content."
        }
    }

    /// How a leg's image is described in a multi-ground prompt ("Image N is <x>"). Text-only grounds
    /// still get an honest phrasing for completeness; they contribute no image leg in practice, so this
    /// is not reached for them through the image enumeration.
    var promptImageDescription: String {
        switch self {
        case .screen:
            return "a SCREENSHOT of the Mac display"
        case .camera:
            return "a CAMERA PHOTO from the Mac's camera (paper, whiteboard, book, or a physical object), NOT a screenshot of the display"
        case .file:
            return "an image from an imported FILE (e.g. a PDF page or a saved image), not a live capture of the current screen"
        case .systemAudio:
            return "an on-device transcript of the system audio (no image)"
        case .selectedText:
            return "text the user selected on screen (no image)"
        case .voiceInput:
            return "an on-device transcript of the user's dictation (no image)"
        case .agent:
            return "a result from a sidecar agent (no image)"
        }
    }

    /// Short noun phrase naming a leg's source, for the supplementary-text / transcript label in a
    /// multi-ground prompt (e.g. "Transcript of <x>" or "Supplementary extracted text from <x>").
    var promptShortLabel: String {
        switch self {
        case .screen:       return "the screenshot"
        case .camera:       return "the camera photo"
        case .file:         return "the imported file"
        case .selectedText: return "the selected text"
        case .systemAudio:  return "the system audio"
        case .voiceInput:   return "the dictation"
        case .agent:        return "the agent result"
        }
    }
}
