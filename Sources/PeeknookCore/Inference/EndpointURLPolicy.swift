// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Validates inference endpoint URLs: http/https only, HTTPS required for non-loopback unless
/// opted in. Backend-neutral — every HTTP backend must route its base URL through this policy
/// before issuing its first request.
public enum EndpointURLPolicy: Sendable {
    public enum ValidationResult: Equatable, Sendable {
        case valid(URL)
        case invalidURL
        case unsupportedScheme
        case insecureRemoteHTTP
    }

    /// True when the endpoint targets a host other than local loopback.
    public static func usesRemoteHost(_ urlString: String) -> Bool {
        guard let url = normalizedURL(from: urlString), let host = url.host else {
            return !isLoopbackSubstring(in: urlString)
        }
        return !isLoopbackHost(host)
    }

    public static func validate(_ string: String, acceptInsecureRemote: Bool) -> ValidationResult {
        guard let url = normalizedURL(from: string) else { return .invalidURL }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .unsupportedScheme
        }
        guard let host = url.host else { return .invalidURL }
        if scheme == "http", !isLoopbackHost(host), !acceptInsecureRemote {
            return .insecureRemoteHTTP
        }
        return .valid(url)
    }

    public static func resolveOrThrow(_ string: String, acceptInsecureRemote: Bool) throws -> URL {
        switch validate(string, acceptInsecureRemote: acceptInsecureRemote) {
        case .valid(let url):
            return url
        case .invalidURL, .unsupportedScheme:
            throw InferenceError.invalidBaseURL
        case .insecureRemoteHTTP:
            throw InferenceError.insecureRemoteHTTP
        }
    }

    public static func isLoopbackHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "127.0.0.1" || h == "localhost" || h == "::1" { return true }
        if h.hasPrefix("[") && h.hasSuffix("]") {
            return h.dropFirst().dropLast().lowercased() == "::1"
        }
        return false
    }

    private static func normalizedURL(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    private static func isLoopbackSubstring(in string: String) -> Bool {
        let lower = string.lowercased()
        return lower.contains("127.0.0.1") || lower.contains("localhost") || lower.contains("[::1]")
    }
}

/// Transitional alias from the pre-rename type name.
public typealias OllamaURLPolicy = EndpointURLPolicy

/// Shared, audience-aware copy for "Ollama isn't reachable yet". The shipped DMG (a Release build)
/// never mentions Terminal; the from-source contributor build (Debug) keeps the `ollama serve` hint
/// since `swift run` users do start the server by hand. Plain English — localization happens at the
/// UI render site via `Text(peek:)`. Both the setup health probe and the live-inference probe share
/// this one definition so the copy can never drift between the two surfaces.
public enum OllamaUnreachableCopy: Sendable {
    public static var notRunning: String {
        #if DEBUG
        return "Ollama isn't running yet. Open the Ollama app (or run `ollama serve`) and Peeknook will connect automatically."
        #else
        return "Ollama isn't running yet. Open the Ollama app and Peeknook will connect automatically."
        #endif
    }
}
