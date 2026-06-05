// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation

enum CapturePreviewImage {
    static func nsImage(from base64: String) -> NSImage? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        return NSImage(data: data)
    }
}
