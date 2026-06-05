// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation

/// On-device usage counters. Everything here is local — nothing is ever sent anywhere,
/// which is itself a stat worth showing.
public struct UsageStats: Codable, Equatable, Sendable {
    public static let defaultsKey = "peeknook.usage.v1"

    public var captures: Int
    public var promptTokens: Int
    public var responseTokens: Int
    public var generationSeconds: Double
    public var imageBytes: Int

    public init(
        captures: Int = 0,
        promptTokens: Int = 0,
        responseTokens: Int = 0,
        generationSeconds: Double = 0,
        imageBytes: Int = 0
    ) {
        self.captures = captures
        self.promptTokens = promptTokens
        self.responseTokens = responseTokens
        self.generationSeconds = generationSeconds
        self.imageBytes = imageBytes
    }

    private enum CodingKeys: String, CodingKey {
        case captures, promptTokens, responseTokens, generationSeconds, imageBytes
    }

    // Tolerant decode so a future field can't reset a user's accumulated totals.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.captures = try c.decodeIfPresent(Int.self, forKey: .captures) ?? 0
        self.promptTokens = try c.decodeIfPresent(Int.self, forKey: .promptTokens) ?? 0
        self.responseTokens = try c.decodeIfPresent(Int.self, forKey: .responseTokens) ?? 0
        self.generationSeconds = try c.decodeIfPresent(Double.self, forKey: .generationSeconds) ?? 0
        self.imageBytes = try c.decodeIfPresent(Int.self, forKey: .imageBytes) ?? 0
    }

    /// Average generation speed across all answers, tokens/sec (0 until the first answer).
    public var averageTokensPerSecond: Double {
        generationSeconds > 0 ? Double(responseTokens) / generationSeconds : 0
    }

    public var imageMegabytes: Double { Double(imageBytes) / 1_000_000 }

    public static func load(from defaults: UserDefaults) -> UsageStats {
        guard let data = defaults.data(forKey: defaultsKey),
              let stats = try? JSONDecoder().decode(UsageStats.self, from: data)
        else { return UsageStats() }
        return stats
    }

    public func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// Accumulates per-inference telemetry into persistent local totals for the Settings stats panel.
@MainActor
@Observable
public final class UsageStore {
    public private(set) var stats: UsageStats
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        self.stats = UsageStats.load(from: defaults)
    }

    public func record(capture: CaptureResult, inference: InferenceStats?) {
        stats.captures += 1
        // base64 → raw byte count (≈ 3/4 of the string length).
        stats.imageBytes += capture.screenshotBase64.map { ($0.count * 3) / 4 } ?? 0
        if let inference {
            stats.promptTokens += inference.promptTokens
            stats.responseTokens += inference.responseTokens
            stats.generationSeconds += inference.generationSeconds
        }
        stats.save(to: defaults)
    }

    /// A follow-up turn reuses the same screenshot, so it adds no capture and no image bytes —
    /// only the model's token/time usage counts.
    public func recordFollowUp(inference: InferenceStats?) {
        guard let inference else { return }
        stats.promptTokens += inference.promptTokens
        stats.responseTokens += inference.responseTokens
        stats.generationSeconds += inference.generationSeconds
        stats.save(to: defaults)
    }

    public func reset() {
        stats = UsageStats()
        stats.save(to: defaults)
    }
}
