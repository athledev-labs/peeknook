// SPDX-License-Identifier: Apache-2.0

import Foundation
#if DEBUG
import os
#endif

/// Debug-only inference telemetry (image counts, not payloads).
public enum InferenceDebugLog {
    #if DEBUG
    private static let logger = Logger(subsystem: "com.peeknook.app", category: "inference")
    #endif

    public static func recordImagePayloadCount(_ count: Int, model: String) {
        #if DEBUG
        logger.debug("Ollama request: \(count, privacy: .public) image payload(s), model=\(model, privacy: .public)")
        #endif
    }
}
