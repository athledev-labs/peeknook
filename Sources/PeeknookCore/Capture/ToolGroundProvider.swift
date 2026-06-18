// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The tool arm of a capture provider: run the active profile's ``ToolSpec`` over a fresh capture and
/// return the tool's verified output as a `.tool` text leg. Kept OFF
/// `CaptureProviding.capture(scope:quick:encoding:)` because a tool needs the profile's `ToolSpec`,
/// which that seam has no slot for (the same reason file import lives on ``FileImporting`` and camera
/// preview on ``CameraSessionControlling``, not on the bare capture seam). The coordinator routes a
/// `.tool`-primary profile here.
public protocol ToolGrounding: Sendable {
    func runTool(
        _ spec: ToolSpec,
        scope: CaptureScope,
        quick: Bool,
        encoding: CaptureEncodingParams
    ) async throws -> CaptureResult
}

/// The payload sent to a tool endpoint. The screenshot rides as JPEG base64 (pixels, redaction out of
/// scope); the text is the capture's extracted text, already redacted by the provider when the tool is
/// remote. `Equatable` so a test can assert exactly what was sent.
public struct ToolRequest: Sendable, Equatable {
    public let screenshotBase64: String?
    public let text: String?
    public let scope: CaptureScope

    public init(screenshotBase64: String?, text: String?, scope: CaptureScope) {
        self.screenshotBase64 = screenshotBase64
        self.text = text
        self.scope = scope
    }
}

/// The HTTP seam for a tool call, isolated so the provider stays unit-testable without a network. The
/// URL is already validated through ``EndpointURLPolicy`` (the HTTPS gate) by the caller.
public protocol ToolHTTPClient: Sendable {
    func runTool(_ request: ToolRequest, url: URL, timeoutSeconds: Double) async throws -> String
}

/// Tool ground provider (HTTP-loopback, slice 2). Composes the screen provider to get the frame the
/// tool reads, POSTs `{screenshot?, text?, scope}` to the configured endpoint, and folds the verified
/// response as a `.tool` text leg the prompt builder treats as primary, authoritative text. A failure
/// degrades through the normal capture-failure ladder rather than blocking.
public struct ToolGroundProvider: CaptureProviding, ToolGrounding, Sendable {
    private let screenProvider: any CaptureProviding
    private let http: any ToolHTTPClient

    public init(screenProvider: any CaptureProviding, http: any ToolHTTPClient = URLSessionToolHTTPClient()) {
        self.screenProvider = screenProvider
        self.http = http
    }

    /// Registry arm, unreachable in the shipped flow: a tool needs a `ToolSpec`, which the bare capture
    /// seam has no slot for, so the coordinator routes a `.tool` profile through ``runTool(_:scope:quick:encoding:)``.
    /// Mirrors ``FileImportCaptureProvider/capture(scope:quick:encoding:)``.
    public func capture(scope: CaptureScope, quick: Bool, encoding: CaptureEncodingParams) async throws -> CaptureResult {
        _ = (scope, quick, encoding)
        throw CaptureError.failed("A tool profile must run through its configured tool.")
    }

    public func runTool(
        _ spec: ToolSpec,
        scope: CaptureScope,
        quick: Bool,
        encoding: CaptureEncodingParams
    ) async throws -> CaptureResult {
        // Slice 2 ships the HTTP-loopback transport only; a `.command` tool is rejected here (and never
        // travels in a shared preset — see ``ToolSpec/shareableOrStripped``).
        guard spec.transport == .http else {
            throw CaptureError.failed("This build supports only local HTTP tools.")
        }
        guard spec.isUsable, let urlString = spec.url else {
            throw CaptureError.failed("This profile's tool has no endpoint configured.")
        }
        // The SAME HTTPS gate as inference: a non-loopback http:// tool is rejected. ToolSpec carries no
        // insecure-HTTP opt-in, so a remote tool must use HTTPS.
        let url: URL
        switch EndpointURLPolicy.validate(urlString, acceptInsecureRemote: false) {
        case .valid(let resolved):
            url = resolved
        case .invalidURL, .unsupportedScheme:
            throw CaptureError.failed("The tool URL is not valid.")
        case .insecureRemoteHTTP:
            throw CaptureError.failed("A remote tool must use HTTPS.")
        }
        let isRemote = EndpointURLPolicy.usesRemoteHost(urlString)

        var screenshotBase64: String?
        var text: String?
        if spec.sendsScreenshot || spec.sendsText {
            let frame = try await screenProvider.capture(scope: scope, quick: quick, encoding: encoding)
            if spec.sendsScreenshot { screenshotBase64 = frame.screenshotBase64 }
            if spec.sendsText, let frameText = frame.text, !frameText.isEmpty {
                // Redact the text SENT to a remote tool, mirroring the inference redaction rule. The
                // screenshot pixels are out of scope (documented). A loopback tool receives it verbatim.
                text = isRemote
                    ? SensitiveContentPolicy().redactedForRemoteInference(text: frameText).text
                    : frameText
            }
        }
        try Task.checkCancellation()
        let request = ToolRequest(screenshotBase64: screenshotBase64, text: text, scope: scope)
        let output = try await http.runTool(request, url: url, timeoutSeconds: spec.timeoutSeconds)
        try Task.checkCancellation()
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CaptureError.noContent }
        // A `.tool` leg is primary text (no image): the FEN/result IS the content. `sourceLabel` is the
        // user-named label so the prompt heading reads e.g. "Chess engine analysis".
        return CaptureResult(text: trimmed, sourceLabel: spec.outputLabel, ground: .tool)
    }
}

/// Production `ToolHTTPClient`: a plain JSON POST. Stores no `URLSession` so the struct is trivially
/// `Sendable`; the request timeout comes from the spec.
public struct URLSessionToolHTTPClient: ToolHTTPClient {
    public init() {}

    public func runTool(_ request: ToolRequest, url: URL, timeoutSeconds: Double) async throws -> String {
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeoutSeconds
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        var body: [String: Any] = ["scope": request.scope.rawValue]
        if let screenshotBase64 = request.screenshotBase64 { body["screenshot"] = screenshotBase64 }
        if let text = request.text { body["text"] = text }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw CaptureError.failed("Couldn't reach the tool: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw CaptureError.failed("The tool gave an unexpected response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CaptureError.failed("The tool returned an error (status \(http.statusCode)).")
        }
        return Self.parseResult(from: data)
    }

    /// A tool may answer with `{"text": "..."}` (also accepting `result`/`output`) or a plain-text body.
    /// Tolerant by design: the tool is the user's own program, so a non-JSON body is read as the result.
    static func parseResult(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["text", "result", "output"] {
                if let value = object[key] as? String { return value }
            }
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Deterministic `ToolHTTPClient` double for `PeeknookDependencies.testing()`: returns a fixed result
/// and never touches the network, so the `.tool` registry entry is present and safe in tests.
public struct StubToolHTTPClient: ToolHTTPClient {
    public let result: String
    public init(result: String = "Tool result.") { self.result = result }
    public func runTool(_ request: ToolRequest, url: URL, timeoutSeconds: Double) async throws -> String {
        _ = (request, url, timeoutSeconds)
        return result
    }
}
