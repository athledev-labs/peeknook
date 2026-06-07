// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation

/// One inference event for timeline charts — appended on each completed answer.
public struct UsageEvent: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var recordedAt: Date
    public var modelTag: String
    public var promptTokens: Int
    public var responseTokens: Int
    public var generationSeconds: Double
    public var didCapture: Bool
    /// Estimated screenshot bytes when ``didCapture`` is true.
    public var imageBytes: Int

    public init(
        id: UUID = UUID(),
        recordedAt: Date = Date(),
        modelTag: String,
        promptTokens: Int,
        responseTokens: Int,
        generationSeconds: Double,
        didCapture: Bool,
        imageBytes: Int = 0
    ) {
        self.id = id
        self.recordedAt = recordedAt
        self.modelTag = modelTag
        self.promptTokens = promptTokens
        self.responseTokens = responseTokens
        self.generationSeconds = generationSeconds
        self.didCapture = didCapture
        self.imageBytes = imageBytes
    }

    private enum CodingKeys: String, CodingKey {
        case id, recordedAt, modelTag, promptTokens, responseTokens, generationSeconds, didCapture, imageBytes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.recordedAt = try c.decodeIfPresent(Date.self, forKey: .recordedAt) ?? Date()
        self.modelTag = try c.decodeIfPresent(String.self, forKey: .modelTag) ?? "unknown"
        self.promptTokens = try c.decodeIfPresent(Int.self, forKey: .promptTokens) ?? 0
        self.responseTokens = try c.decodeIfPresent(Int.self, forKey: .responseTokens) ?? 0
        self.generationSeconds = try c.decodeIfPresent(Double.self, forKey: .generationSeconds) ?? 0
        self.didCapture = try c.decodeIfPresent(Bool.self, forKey: .didCapture) ?? false
        self.imageBytes = try c.decodeIfPresent(Int.self, forKey: .imageBytes) ?? 0
    }
}

/// Date window for filtering usage analytics.
public enum UsageDateRange: String, CaseIterable, Sendable {
    case allTime
    case today
    case last7Days
    case last30Days

    public var label: String {
        switch self {
        case .allTime: "All time"
        case .today: "Today"
        case .last7Days: "7 days"
        case .last30Days: "30 days"
        }
    }

    /// Title-case labels for the stats command-bar date filter.
    public var filterLabel: String {
        switch self {
        case .allTime: "All Time"
        case .today: "Today"
        case .last7Days: "7 Days"
        case .last30Days: "30 Days"
        }
    }

    public func contains(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch self {
        case .allTime:
            return true
        case .today:
            return calendar.isDate(date, inSameDayAs: now)
        case .last7Days:
            guard let start = calendar.date(byAdding: .day, value: -7, to: now) else { return false }
            return date >= start
        case .last30Days:
            guard let start = calendar.date(byAdding: .day, value: -30, to: now) else { return false }
            return date >= start
        }
    }
}

/// Aggregated usage for a date range — built from the event log, or legacy totals for all-time
/// when no events exist yet.
public struct UsageWindow: Equatable, Sendable {
    public var captures: Int
    public var promptTokens: Int
    public var responseTokens: Int
    public var generationSeconds: Double
    public var imageBytes: Int
    public var events: [UsageEvent]
    public var persistedModels: [ModelUsageSummary]

    public var averageTokensPerSecond: Double {
        generationSeconds > 0 ? Double(responseTokens) / generationSeconds : 0
    }

    public var imageMegabytes: Double { Double(imageBytes) / 1_000_000 }

    public var hasData: Bool {
        captures > 0 || promptTokens > 0 || responseTokens > 0
    }

    public var modelTags: [String] {
        var seen = Set<String>()
        var tags: [String] = []
        for event in events.reversed() where seen.insert(event.modelTag).inserted {
            tags.append(event.modelTag)
        }
        return tags
    }

    public var modelSummaries: [ModelUsageSummary] {
        var buckets: [String: ModelUsageSummary] = [:]
        for event in events {
            var summary = buckets[event.modelTag] ?? ModelUsageSummary(
                modelTag: event.modelTag,
                promptTokens: 0,
                responseTokens: 0,
                eventCount: 0,
                captures: 0
            )
            summary.absorb(event: event)
            buckets[event.modelTag] = summary
        }
        if !buckets.isEmpty {
            return buckets.values.sorted { $0.totalTokens > $1.totalTokens }
        }
        return persistedModels
    }
}

/// Per-model rollup — persisted in ``UsageStats/modelTotals`` and derived from events.
public struct ModelUsageSummary: Codable, Equatable, Sendable, Identifiable {
    public var modelTag: String
    public var promptTokens: Int
    public var responseTokens: Int
    public var eventCount: Int
    public var captures: Int

    public var id: String { modelTag }
    public var totalTokens: Int { promptTokens + responseTokens }

    public init(
        modelTag: String,
        promptTokens: Int,
        responseTokens: Int,
        eventCount: Int,
        captures: Int
    ) {
        self.modelTag = modelTag
        self.promptTokens = promptTokens
        self.responseTokens = responseTokens
        self.eventCount = eventCount
        self.captures = captures
    }

    public mutating func absorb(event: UsageEvent) {
        promptTokens += event.promptTokens
        responseTokens += event.responseTokens
        eventCount += 1
        if event.didCapture { captures += 1 }
    }
}

/// On-device usage counters. Everything here is local — nothing is ever sent anywhere,
/// which is itself a stat worth showing.
public struct UsageStats: Codable, Equatable, Sendable {
    public static let defaultsKey = "peeknook.usage.v1"
    static let maxEvents = 200

    public var captures: Int
    public var promptTokens: Int
    public var responseTokens: Int
    public var generationSeconds: Double
    public var imageBytes: Int
    /// Rolling inference log for timeline charts (newest last; pruned to ``maxEvents``).
    public var events: [UsageEvent]
    /// Lifetime per-model totals — updated on every recorded answer.
    public var modelTotals: [String: ModelUsageSummary]

    public init(
        captures: Int = 0,
        promptTokens: Int = 0,
        responseTokens: Int = 0,
        generationSeconds: Double = 0,
        imageBytes: Int = 0,
        events: [UsageEvent] = [],
        modelTotals: [String: ModelUsageSummary] = [:]
    ) {
        self.captures = captures
        self.promptTokens = promptTokens
        self.responseTokens = responseTokens
        self.generationSeconds = generationSeconds
        self.imageBytes = imageBytes
        self.events = events
        self.modelTotals = modelTotals
    }

    private enum CodingKeys: String, CodingKey {
        case captures, promptTokens, responseTokens, generationSeconds, imageBytes, events, modelTotals
    }

    // Tolerant decode so a future field can't reset a user's accumulated totals.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.captures = try c.decodeIfPresent(Int.self, forKey: .captures) ?? 0
        self.promptTokens = try c.decodeIfPresent(Int.self, forKey: .promptTokens) ?? 0
        self.responseTokens = try c.decodeIfPresent(Int.self, forKey: .responseTokens) ?? 0
        self.generationSeconds = try c.decodeIfPresent(Double.self, forKey: .generationSeconds) ?? 0
        self.imageBytes = try c.decodeIfPresent(Int.self, forKey: .imageBytes) ?? 0
        self.events = try c.decodeIfPresent([UsageEvent].self, forKey: .events) ?? []
        self.modelTotals = try c.decodeIfPresent([String: ModelUsageSummary].self, forKey: .modelTotals) ?? [:]
    }

    public var sortedModelTotals: [ModelUsageSummary] {
        modelTotals.values.sorted { $0.totalTokens > $1.totalTokens }
    }

    /// Average generation speed across all answers, tokens/sec (0 until the first answer).
    public var averageTokensPerSecond: Double {
        generationSeconds > 0 ? Double(responseTokens) / generationSeconds : 0
    }

    public var imageMegabytes: Double { Double(imageBytes) / 1_000_000 }

    /// Usage rolled up for a date range. All-time keeps legacy lifetime totals for the summary
    /// (captures before the event log still count) while charts read from ``events``. Narrower
    /// ranges aggregate from the event log only.
    public func window(for range: UsageDateRange, now: Date = Date()) -> UsageWindow {
        switch range {
        case .allTime where events.isEmpty:
            return UsageWindow(
                captures: captures,
                promptTokens: promptTokens,
                responseTokens: responseTokens,
                generationSeconds: generationSeconds,
                imageBytes: imageBytes,
                events: [],
                persistedModels: sortedModelTotals
            )
        case .allTime:
            return UsageWindow(
                captures: captures,
                promptTokens: promptTokens,
                responseTokens: responseTokens,
                generationSeconds: generationSeconds,
                imageBytes: imageBytes,
                events: events,
                persistedModels: sortedModelTotals
            )
        default:
            let filtered = events.filter { range.contains($0.recordedAt, now: now) }
            return Self.aggregate(events: filtered)
        }
    }

    static func aggregate(events: [UsageEvent]) -> UsageWindow {
        var captures = 0
        var promptTokens = 0
        var responseTokens = 0
        var generationSeconds = 0.0
        var imageBytes = 0
        for event in events {
            promptTokens += event.promptTokens
            responseTokens += event.responseTokens
            generationSeconds += event.generationSeconds
            imageBytes += event.imageBytes
            if event.didCapture { captures += 1 }
        }
        return UsageWindow(
            captures: captures,
            promptTokens: promptTokens,
            responseTokens: responseTokens,
            generationSeconds: generationSeconds,
            imageBytes: imageBytes,
            events: events,
            persistedModels: []
        )
    }

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

    public func record(capture: CaptureResult, inference: InferenceStats?, modelTag: String) {
        stats.captures += 1
        // base64 → raw byte count (≈ 3/4 of the string length).
        let bytes = capture.screenshotBase64.map { ($0.count * 3) / 4 } ?? 0
        stats.imageBytes += bytes
        if let inference {
            stats.promptTokens += inference.promptTokens
            stats.responseTokens += inference.responseTokens
            stats.generationSeconds += inference.generationSeconds
            appendEvent(
                modelTag: modelTag,
                inference: inference,
                didCapture: true,
                imageBytes: bytes
            )
        }
        stats.save(to: defaults)
    }

    /// A follow-up turn reuses the same screenshot, so it adds no capture and no image bytes —
    /// only the model's token/time usage counts.
    public func recordFollowUp(inference: InferenceStats?, modelTag: String) {
        guard let inference else { return }
        stats.promptTokens += inference.promptTokens
        stats.responseTokens += inference.responseTokens
        stats.generationSeconds += inference.generationSeconds
        appendEvent(
            modelTag: modelTag,
            inference: inference,
            didCapture: false
        )
        stats.save(to: defaults)
    }

    public func reset() {
        stats = UsageStats()
        stats.save(to: defaults)
    }

    private func appendEvent(
        modelTag: String,
        inference: InferenceStats,
        didCapture: Bool,
        imageBytes: Int = 0
    ) {
        let tag = modelTag.trimmingCharacters(in: .whitespacesAndNewlines)
        let event = UsageEvent(
            modelTag: tag.isEmpty ? "unknown" : tag,
            promptTokens: inference.promptTokens,
            responseTokens: inference.responseTokens,
            generationSeconds: inference.generationSeconds,
            didCapture: didCapture,
            imageBytes: imageBytes
        )
        stats.events.append(event)
        if stats.events.count > UsageStats.maxEvents {
            stats.events.removeFirst(stats.events.count - UsageStats.maxEvents)
        }
        var summary = stats.modelTotals[event.modelTag] ?? ModelUsageSummary(
            modelTag: event.modelTag,
            promptTokens: 0,
            responseTokens: 0,
            eventCount: 0,
            captures: 0
        )
        summary.absorb(event: event)
        stats.modelTotals[event.modelTag] = summary
    }
}
