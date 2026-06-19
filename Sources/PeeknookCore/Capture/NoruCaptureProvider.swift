// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Foundation

/// Consume Noru Flow as a capture/perception SIDECAR over its loopback host API
/// (Noru's docs/host-api.md + docs/third-party-integration-architecture.md). Peeknook
/// stays a separate product: this talks to Noru over HTTP and NEVER links Noru's
/// Rust/Tauri code (CLAUDE.md invariant 6). Two sandbox-legal channels make it work
/// without reaching Noru's private 0700 dir:
///   - discovery + token: a shared App Group container (same Apple Team) holding
///     `noru-host.json` (token + actual port + identity);
///   - pixels: Noru's opt-in `include:"image_base64"` returns inline base64, so this
///     sandboxed app never has to `open()` a path outside its container.
/// Both apps MUST sign under the SAME Apple Team and declare the
/// `T74YFYUA35.com.noruflow.shared` App Group (com.apple.security.application-groups).
///
/// DRAFT (Noru host-api.md §10 H2): the App Group resolution + loopback reach need
/// on-device verification on a signed build; the request/response shaping is unit-tested
/// through the injected seams below. Not wired into the active capture registry yet, so
/// it changes no runtime behavior until an operator opts in.
public struct NoruHostEndpoint: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var token: String

    public init(host: String = "127.0.0.1", port: Int, token: String) {
        self.host = host
        self.port = port
        self.token = token
    }
}

/// Resolves the loopback endpoint + per-install token. Injected so tests need no real
/// App Group container.
public protocol NoruHostLocating: Sendable {
    func locate() throws -> NoruHostEndpoint
}

/// Default locator: read the discovery handshake Noru publishes into the shared App
/// Group container. The sandboxed app reaches it via
/// `containerURL(forSecurityApplicationGroupIdentifier:)` (legal; needs the matching
/// `application-groups` entitlement), never Noru's 0700 dir.
public struct AppGroupNoruHostLocator: NoruHostLocating, Sendable {
    public static let appGroup = "T74YFYUA35.com.noruflow.shared"
    public static let handshakeFile = "noru-host.json"

    private let appGroup: String

    public init(appGroup: String = AppGroupNoruHostLocator.appGroup) {
        self.appGroup = appGroup
    }

    private struct Handshake: Decodable {
        let token: String
        let port: Int
        let bundleId: String?
        let apiVersion: Int?
    }

    public func locate() throws -> NoruHostEndpoint {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        else {
            throw CaptureError.failed(
                "Noru App Group \(appGroup) is unavailable. Sign Peeknook under the same Apple Team and add the application-groups entitlement.")
        }
        let url = container.appendingPathComponent(Self.handshakeFile)
        guard let data = try? Data(contentsOf: url) else {
            throw CaptureError.failed("Noru is not sharing a host handshake yet. Open Noru and enable its host engine.")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let handshake: Handshake
        do {
            handshake = try decoder.decode(Handshake.self, from: data)
        } catch {
            throw CaptureError.failed("Noru host handshake was unreadable: \(error.localizedDescription)")
        }
        guard !handshake.token.isEmpty, handshake.port > 0 else {
            throw CaptureError.failed("Noru host handshake is incomplete (token/port missing).")
        }
        return NoruHostEndpoint(port: handshake.port, token: handshake.token)
    }
}

/// The loopback HTTP seam (injected for tests). Returns the raw body + HTTP status.
public protocol NoruHostHTTP: Sendable {
    func postCapture(url: URL, token: String, body: Data, timeoutSeconds: Double) async throws -> (Data, Int)
}

public struct URLSessionNoruHostHTTP: NoruHostHTTP, Sendable {
    public init() {}

    public func postCapture(url: URL, token: String, body: Data, timeoutSeconds: Double) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        // URLSession sets a loopback Host header from the URL (Noru's DNS-rebind guard
        // accepts 127.0.0.1[:port]) and adds no Origin, so Noru's request_guard passes.
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, status)
    }
}

public struct NoruCaptureProvider: CaptureProviding, Sendable {
    private let locator: any NoruHostLocating
    private let http: any NoruHostHTTP
    private let timeoutSeconds: Double

    public init(
        locator: any NoruHostLocating = AppGroupNoruHostLocator(),
        http: any NoruHostHTTP = URLSessionNoruHostHTTP(),
        timeoutSeconds: Double = 20
    ) {
        self.locator = locator
        self.http = http
        self.timeoutSeconds = timeoutSeconds
    }

    public func capture(
        scope: CaptureScope,
        quick: Bool,
        encoding: CaptureEncodingParams
    ) async throws -> CaptureResult {
        _ = quick // fidelity is already resolved into `encoding`
        let endpoint = try locator.locate()
        guard let url = URL(string: "http://\(endpoint.host):\(endpoint.port)/capture") else {
            throw CaptureError.failed("Invalid Noru endpoint.")
        }
        let body = try Self.requestBody(scope: scope, encoding: encoding)
        let (data, status) = try await http.postCapture(
            url: url, token: endpoint.token, body: body, timeoutSeconds: timeoutSeconds)
        return try Self.decode(data: data, status: status, scope: scope)
    }

    // MARK: - Pure request/response shaping (unit-tested)

    static func noruMode(for scope: CaptureScope) -> String {
        switch scope {
        case .window: "window_under_cursor"
        case .display: "fullscreen"
        }
    }

    static func requestBody(scope: CaptureScope, encoding: CaptureEncodingParams) throws -> Data {
        // Peeknook's quality is 0...1 (ImageIO); Noru wants an integer 1...100.
        let quality = max(1, min(100, Int((encoding.jpegQuality * 100).rounded())))
        let spec: [String: Any] = [
            "mode": noruMode(for: scope),
            "served_max_edge": encoding.maxPixel,
            // image_base64 = self-contained pixels the sandbox reads without a path;
            // jpeg keeps the payload small for a local (non-Claude) model.
            "include": ["image_base64"],
            "format": "jpeg",
            "jpeg_quality": quality,
        ]
        return try JSONSerialization.data(withJSONObject: spec)
    }

    private struct HostSource: Decodable {
        let appName: String?
        let windowTitle: String?
    }

    private struct HostFile: Decodable {
        let imageBase64: String?
        let imageMimeType: String?
        let ocrText: String?
        let source: HostSource?
    }

    private struct HostBundle: Decodable {
        let ok: Bool?
        let files: [HostFile]?
    }

    private struct HostErrorBody: Decodable {
        let code: String?
        let message: String?
        let hint: String?
    }

    private struct HostErrorEnvelope: Decodable {
        let ok: Bool?
        let error: HostErrorBody?
    }

    static func decode(data: Data, status: Int, scope: CaptureScope) throws -> CaptureResult {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        if status != 200 {
            if let env = try? decoder.decode(HostErrorEnvelope.self, from: data), let err = env.error {
                let code = err.code ?? "error"
                let message = err.message ?? "Noru capture failed"
                if code == "permission_denied" {
                    throw CaptureError.permissionRequired("Screen Recording (grant it to Noru)")
                }
                throw CaptureError.failed("Noru: \(message) [\(code)]")
            }
            throw CaptureError.failed("Noru capture failed (HTTP \(status)).")
        }

        guard let bundle = try? decoder.decode(HostBundle.self, from: data),
              let file = bundle.files?.first
        else {
            throw CaptureError.failed("Noru returned an unreadable bundle.")
        }
        guard let base64 = file.imageBase64, !base64.isEmpty else {
            throw CaptureError.failed("Noru returned no inline image. Request include:\"image_base64\".")
        }
        let label = scope == .display ? "Noru, whole screen (vision)" : "Noru, window (vision)"
        return CaptureResult(
            text: file.ocrText,
            sourceLabel: label,
            appName: file.source?.appName,
            windowTitle: file.source?.windowTitle,
            screenshotBase64: base64,
            ground: .screen
        )
    }
}
