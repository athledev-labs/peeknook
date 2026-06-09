// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Ground-keyed capture providers. The orchestrator resolves the active profile's primary ground
/// here instead of holding a single `CaptureProviding`, so a second ground (camera) plugs in as a
/// registry entry rather than a widened call site. A struct (not a bare dictionary) so the
/// "no provider registered" policy lives in one place: `resolve(_:)` throws a loud capture failure
/// naming the ground, never a silent fallback to screen.
public struct GroundRegistry: Sendable {
    private let providers: [Ground: any CaptureProviding]

    public init(_ providers: [Ground: any CaptureProviding]) {
        self.providers = providers
    }

    /// The provider for `ground`, or nil when none is registered — the non-throwing peek for
    /// readiness checks and tests. Callers that must capture use ``resolve(_:)``.
    public func provider(for ground: Ground) -> (any CaptureProviding)? {
        providers[ground]
    }

    /// Resolve-or-throw: a profile whose primary ground has no provider is a wiring bug, surfaced
    /// as a recoverable capture failure through the session's existing error path.
    public func resolve(_ ground: Ground) throws -> any CaptureProviding {
        guard let provider = providers[ground] else {
            throw CaptureError.failed("No capture provider is registered for \(ground.rawValue).")
        }
        return provider
    }

    /// The live-preview controller for a ground, when its provider also drives a live session
    /// (camera). Screen's provider returns nil here.
    public func sessionController(for ground: Ground) -> (any CameraSessionControlling)? {
        providers[ground] as? any CameraSessionControlling
    }
}
