// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Synchronous verdict on a tool URL the profile editor draws an inline note from. The same HTTPS gate
/// as inference: a remote `http://` tool is always rejected because a ``ToolSpec`` carries no
/// insecure-HTTP opt-in. `.empty` is an in-progress edit, allowed to persist but leaving the spec
/// ``ToolSpec/isUsable`` false.
public enum ToolURLValidity: Equatable, Sendable {
    case empty
    case valid
    case invalid
    case insecureRemote
}

/// The outcome of a user-triggered tool reachability probe.
/// - `unconfigured`: the spec has no HTTP endpoint to probe.
/// - `rejected`: the URL failed the ``EndpointURLPolicy`` gate (malformed, or a remote http:// tool).
/// - `reachable`: the endpoint answered with an HTTP response.
/// - `unreachable`: nothing answered (connection refused, DNS failure, or timeout).
public enum ToolHealth: Equatable, Sendable {
    case unconfigured
    case rejected
    case reachable
    case unreachable
}

/// The probe seam for a tool reachability check, isolated so the settings controller is unit-testable
/// without a network. The URL is already validated through ``EndpointURLPolicy`` (the HTTPS gate) by the
/// caller. The probe NEVER runs the tool or takes a capture: it only checks the endpoint answers.
public protocol ToolReachabilityProbing: Sendable {
    func probe(url: URL, timeoutSeconds: Double) async -> Bool
}

/// Production probe: a plain GET with a clamped timeout. Any HTTP response (even an error status) means
/// the local tool is listening; only a transport failure (refused, DNS, timeout) is unreachable. It
/// sends no screenshot or text, so it never triggers the tool's work.
public struct URLSessionToolReachabilityProbe: ToolReachabilityProbing {
    public init() {}

    public func probe(url: URL, timeoutSeconds: Double) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = min(max(timeoutSeconds, ToolSpec.minTimeoutSeconds), ToolSpec.maxTimeoutSeconds)
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return response is HTTPURLResponse
        } catch {
            return false
        }
    }
}

/// Deterministic ``ToolReachabilityProbing`` double for tests: returns a fixed verdict and never touches
/// the network.
public struct StubToolReachabilityProbe: ToolReachabilityProbing {
    public let reachable: Bool
    public init(reachable: Bool) { self.reachable = reachable }
    public func probe(url: URL, timeoutSeconds: Double) async -> Bool {
        _ = (url, timeoutSeconds)
        return reachable
    }
}
