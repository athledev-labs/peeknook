// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A user-configured tool a profile runs to produce a VERIFIED text leg — a chess engine's FEN + best
/// line, a calculator's result, a code runner's output. The tool is the user's OWN; Peeknook hardcodes
/// none. A tool ground (``Ground/tool``) is its profile's primary ground; the provider (slice 2) runs
/// this spec and folds the result in as primary text, so the model EXPLAINS verified ground truth
/// instead of guessing. **Schema only in slice 1 — no provider runs it yet.**
///
/// Decode is deliberately tolerant (the same reset-bomb discipline as ``GroundProfile`` /
/// ``ProfileModelBinding``): an unknown transport falls back to the SAFE `.http` (loopback), empty
/// endpoints normalize to `nil` (→ ``isUsable`` false → the profile degrades to no tool), the label is
/// capped, and the timeout is clamped — so a malformed or hostile spec never throws and never strands
/// the catalog.
public struct ToolSpec: Equatable, Sendable {
    /// How Peeknook reaches the tool.
    ///
    /// - `http` is the only SHAREABLE transport: it POSTs to a local server the user runs and is routed
    ///   through ``EndpointURLPolicy`` — the SAME HTTPS gate as inference, so a non-loopback `http://`
    ///   is rejected unless the user opts into insecure HTTP.
    /// - `command` shells out to a local binary. It is arbitrary code execution, so it NEVER travels in
    ///   a shared preset (``ProfilePreset`` strips it on import via ``ToolSpec/shareableOrStripped``)
    ///   and is intended for unsandboxed / from-source builds only (the sandboxed app can't exec it).
    public enum Transport: String, Codable, Sendable, CaseIterable {
        case http
        case command
    }

    public static let maxOutputLabelLength = 80
    public static let defaultOutputLabel = "Tool result"
    public static let minTimeoutSeconds: Double = 1
    public static let maxTimeoutSeconds: Double = 30
    public static let defaultTimeoutSeconds: Double = 10

    public let transport: Transport
    /// `http` endpoint, routed through ``EndpointURLPolicy`` before any request. nil/empty ⇒ unusable.
    public let url: String?
    /// `command` executable path. nil/empty ⇒ unusable. Never travels in a shared preset.
    public let command: String?
    public let arguments: [String]
    /// Send the captured screenshot (base64) to the tool as input.
    public let sendsScreenshot: Bool
    /// Send the captured / extracted text to the tool as input.
    public let sendsText: Bool
    /// How the tool's result is labelled in the prompt (the primary-text heading), capped.
    public let outputLabel: String
    /// Hard wall on how long a tool may run before the turn degrades, clamped to a sane band.
    public let timeoutSeconds: Double

    public init(
        transport: Transport,
        url: String? = nil,
        command: String? = nil,
        arguments: [String] = [],
        sendsScreenshot: Bool = true,
        sendsText: Bool = false,
        outputLabel: String = ToolSpec.defaultOutputLabel,
        timeoutSeconds: Double = ToolSpec.defaultTimeoutSeconds
    ) {
        self.transport = transport
        self.url = Self.normalized(url)
        self.command = Self.normalized(command)
        self.arguments = arguments
        self.sendsScreenshot = sendsScreenshot
        self.sendsText = sendsText
        self.outputLabel = Self.sanitizedLabel(outputLabel)
        self.timeoutSeconds = Self.clampedTimeout(timeoutSeconds)
    }

    /// True when the spec has the endpoint its transport needs. An unusable spec means "no tool" — the
    /// provider (slice 2) degrades to the plain capture rather than failing the turn.
    public var isUsable: Bool {
        switch transport {
        case .http:    return url != nil
        case .command: return command != nil
        }
    }

    /// The spec rewritten safe-to-share: a `.command` tool (arbitrary code execution) is dropped to
    /// `nil`, so an imported preset can never bring an executable; an `http` (loopback) tool travels
    /// intact. ``ProfilePreset`` applies this at install time — the single chokepoint into the catalog.
    public var shareableOrStripped: ToolSpec? {
        transport == .command ? nil : self
    }

    private static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func sanitizedLabel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? defaultOutputLabel : trimmed
        return String(base.prefix(maxOutputLabelLength))
    }

    private static func clampedTimeout(_ raw: Double) -> Double {
        guard raw.isFinite else { return defaultTimeoutSeconds }
        return min(max(raw, minTimeoutSeconds), maxTimeoutSeconds)
    }
}

// MARK: - Tolerant Codable

extension ToolSpec: Codable {
    private enum CodingKeys: String, CodingKey {
        case transport, url, command, arguments, sendsScreenshot, sendsText, outputLabel, timeoutSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Unknown/garbage transport falls back to the SAFE loopback HTTP transport, never `.command`.
        let rawTransport = ((try? c.decodeIfPresent(String.self, forKey: .transport)) ?? nil)
        let transport = rawTransport.flatMap(Transport.init(rawValue:)) ?? .http
        let url = ((try? c.decodeIfPresent(String.self, forKey: .url)) ?? nil)
        let command = ((try? c.decodeIfPresent(String.self, forKey: .command)) ?? nil)
        let arguments = ((try? c.decodeIfPresent([String].self, forKey: .arguments)) ?? nil) ?? []
        let sendsScreenshot = ((try? c.decodeIfPresent(Bool.self, forKey: .sendsScreenshot)) ?? nil) ?? true
        let sendsText = ((try? c.decodeIfPresent(Bool.self, forKey: .sendsText)) ?? nil) ?? false
        let outputLabel = ((try? c.decodeIfPresent(String.self, forKey: .outputLabel)) ?? nil) ?? Self.defaultOutputLabel
        let timeout = ((try? c.decodeIfPresent(Double.self, forKey: .timeoutSeconds)) ?? nil) ?? Self.defaultTimeoutSeconds
        self.init(
            transport: transport,
            url: url,
            command: command,
            arguments: arguments,
            sendsScreenshot: sendsScreenshot,
            sendsText: sendsText,
            outputLabel: outputLabel,
            timeoutSeconds: timeout
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(transport.rawValue, forKey: .transport)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(command, forKey: .command)
        if !arguments.isEmpty { try c.encode(arguments, forKey: .arguments) }
        try c.encode(sendsScreenshot, forKey: .sendsScreenshot)
        try c.encode(sendsText, forKey: .sendsText)
        try c.encode(outputLabel, forKey: .outputLabel)
        try c.encode(timeoutSeconds, forKey: .timeoutSeconds)
    }
}
