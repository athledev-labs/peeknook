// SPDX-License-Identifier: Apache-2.0

import Foundation

// Tool-profile editing helpers: URL validation for the editor's inline note and a user-triggered
// reachability probe. Both route the URL through the SAME HTTPS gate as inference (``EndpointURLPolicy``);
// a tool spec carries no insecure-HTTP opt-in, so a remote http:// tool is always rejected.
@MainActor
extension PeekSettingsController {
    /// Validity of a tool URL for the editor's inline note. An empty string is `.empty` (an in-progress
    /// edit, allowed to persist but unusable); a remote `http://` URL is `.insecureRemote`; a malformed
    /// or non-http(s) URL is `.invalid`.
    public func toolURLValidity(_ url: String) -> ToolURLValidity {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        switch EndpointURLPolicy.validate(trimmed, acceptInsecureRemote: false) {
        case .valid:
            return .valid
        case .insecureRemoteHTTP:
            return .insecureRemote
        case .invalidURL, .unsupportedScheme:
            return .invalid
        }
    }

    /// User-triggered reachability probe for a tool. Routes the URL through ``EndpointURLPolicy`` FIRST
    /// (remote requires HTTPS), then asks the injected prober whether the endpoint answers. It never runs
    /// the tool or takes a capture; a button drives it, never an ambient timer.
    public func toolReachable(_ spec: ToolSpec) async -> ToolHealth {
        guard spec.transport == .http, let urlString = spec.url else { return .unconfigured }
        switch EndpointURLPolicy.validate(urlString, acceptInsecureRemote: false) {
        case .valid(let url):
            return await toolProbe.probe(url: url, timeoutSeconds: spec.timeoutSeconds) ? .reachable : .unreachable
        case .invalidURL, .unsupportedScheme, .insecureRemoteHTTP:
            return .rejected
        }
    }
}
