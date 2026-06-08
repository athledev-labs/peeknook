// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Controls how display conversation maps to model requests. UI/archive keep all screenshots;
/// inference replays a bounded subset to control context and bandwidth.
public struct InferenceReplayPolicy: Sendable, Equatable {
    public var maxImagePayloads: Int

    public init(maxImagePayloads: Int) {
        self.maxImagePayloads = maxImagePayloads
    }

    public static let inference = InferenceReplayPolicy(maxImagePayloads: 1)
    public static let suggestions = InferenceReplayPolicy(maxImagePayloads: 0)
}
