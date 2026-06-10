// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Foundation

/// User-facing JPEG encoding tier for vision captures. Independent of answer depth (`quickMode`):
/// depth still controls the scope×quick pixel table; quality scales that baseline and the JPEG tier.
public enum CaptureQuality: String, Codable, Sendable, CaseIterable, Identifiable {
    case fast
    case balanced
    case high

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fast: "Fast"
        case .balanced: "Balanced"
        case .high: "High"
        }
    }

    public var menuDetail: String {
        switch self {
        case .fast: "Smaller images, faster inference"
        case .balanced: "Default size and clarity"
        case .high: "Sharper text, larger payloads"
        }
    }

    public var barLabel: String {
        switch self {
        case .fast: "Fast"
        case .balanced: "Balanced"
        case .high: "High"
        }
    }

    public var settingsIcon: String {
        switch self {
        case .fast: "hare"
        case .balanced: "slider.horizontal.3"
        case .high: "tortoise"
        }
    }
}

public struct CaptureEncodingParams: Sendable, Equatable {
    public var maxPixel: Int
    public var jpegQuality: CGFloat

    public init(maxPixel: Int, jpegQuality: CGFloat) {
        self.maxPixel = maxPixel
        self.jpegQuality = jpegQuality
    }
}

/// Resolves the JPEG long-edge cap and quality sent to vision models.
public enum CaptureEncodingPolicy {
    public static func resolve(
        scope: CaptureScope,
        quick: Bool,
        quality: CaptureQuality
    ) -> CaptureEncodingParams {
        let baseMaxPixel = baseMaxPixel(scope: scope, quick: quick)
        let scaled = scaledMaxPixel(baseMaxPixel, quality: quality)
        return CaptureEncodingParams(maxPixel: scaled, jpegQuality: jpegQuality(for: quality))
    }

    static func baseMaxPixel(scope: CaptureScope, quick: Bool) -> Int {
        switch (scope, quick) {
        case (.display, false): return 1600
        case (.display, true): return 1152
        case (.window, false): return 1280
        case (.window, true): return 896
        }
    }

    static func scaledMaxPixel(_ base: Int, quality: CaptureQuality) -> Int {
        let multiplier: Double
        switch quality {
        case .fast: multiplier = 0.75
        case .balanced: multiplier = 1.0
        case .high: multiplier = 1.25
        }
        return max(512, Int((Double(base) * multiplier).rounded()))
    }

    static func jpegQuality(for quality: CaptureQuality) -> CGFloat {
        switch quality {
        case .fast: return 0.65
        case .balanced: return 0.82
        case .high: return 0.92
        }
    }
}
