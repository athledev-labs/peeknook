// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest
@testable import PeeknookCore

final class NoruCaptureProviderTests: XCTestCase {
    // MARK: - Stubs

    private struct StubLocator: NoruHostLocating {
        var endpoint: NoruHostEndpoint
        func locate() throws -> NoruHostEndpoint { endpoint }
    }

    private struct ThrowingLocator: NoruHostLocating {
        func locate() throws -> NoruHostEndpoint { throw CaptureError.failed("no app group") }
    }

    private final class StubHTTP: NoruHostHTTP, @unchecked Sendable {
        let response: (Data, Int)
        var capturedURL: URL?
        var capturedToken: String?
        var capturedBody: Data?
        init(response: (Data, Int)) { self.response = response }
        func postCapture(url: URL, token: String, body: Data, timeoutSeconds: Double) async throws -> (Data, Int) {
            capturedURL = url
            capturedToken = token
            capturedBody = body
            return response
        }
    }

    private func encoding() -> CaptureEncodingParams {
        CaptureEncodingParams(maxPixel: 1568, jpegQuality: 0.82)
    }

    // MARK: - Request shaping

    func testRequestBodyMapsScopeAndEncoding() throws {
        let windowData = try NoruCaptureProvider.requestBody(scope: .window, encoding: encoding())
        let window = try XCTUnwrap(JSONSerialization.jsonObject(with: windowData) as? [String: Any])
        XCTAssertEqual(window["mode"] as? String, "window_under_cursor")
        XCTAssertEqual(window["served_max_edge"] as? Int, 1568)
        XCTAssertEqual(window["format"] as? String, "jpeg")
        XCTAssertEqual(window["jpeg_quality"] as? Int, 82)
        XCTAssertEqual(window["include"] as? [String], ["image_base64"])

        let displayData = try NoruCaptureProvider.requestBody(scope: .display, encoding: encoding())
        let display = try XCTUnwrap(JSONSerialization.jsonObject(with: displayData) as? [String: Any])
        XCTAssertEqual(display["mode"] as? String, "fullscreen")
    }

    func testJpegQualityClampsIntoNoruRange() throws {
        let low = try NoruCaptureProvider.requestBody(
            scope: .window, encoding: CaptureEncodingParams(maxPixel: 1024, jpegQuality: 0))
        let lowObj = try XCTUnwrap(JSONSerialization.jsonObject(with: low) as? [String: Any])
        XCTAssertEqual(lowObj["jpeg_quality"] as? Int, 1, "0.0 clamps up to Noru's floor of 1")

        let high = try NoruCaptureProvider.requestBody(
            scope: .window, encoding: CaptureEncodingParams(maxPixel: 1024, jpegQuality: 1))
        let highObj = try XCTUnwrap(JSONSerialization.jsonObject(with: high) as? [String: Any])
        XCTAssertEqual(highObj["jpeg_quality"] as? Int, 100)
    }

    // MARK: - Response decoding

    func testDecodeSuccessBundleBuildsCaptureResult() throws {
        let json = #"""
        {"ok":true,"schema_version":1,"id":"host_x","captured_at":"2026-06-19T00:00:00.000Z","platform":"macos","ocr_status":"none","files":[{"id":"f1","media_type":"screenshot","source_width":120,"source_height":80,"served_width":120,"served_height":80,"served_max_edge":1568,"downscaled_from":null,"bytes":4,"image_base64":"AAEC","image_mime_type":"image/jpeg","source":{"app_name":"Safari","window_title":"peeknook.com"}}]}
        """#.data(using: .utf8)!
        let result = try NoruCaptureProvider.decode(data: json, status: 200, scope: .window)
        XCTAssertEqual(result.screenshotBase64, "AAEC")
        XCTAssertEqual(result.appName, "Safari")
        XCTAssertEqual(result.windowTitle, "peeknook.com")
        XCTAssertTrue(result.hasVision)
        XCTAssertEqual(result.ground, .screen)
    }

    func testDecodeErrorEnvelopeThrowsFailed() {
        let json = #"{"ok":false,"error":{"code":"unauthorized","message":"unauthorized","hint":"Provide the per-install host token."}}"#
            .data(using: .utf8)!
        XCTAssertThrowsError(try NoruCaptureProvider.decode(data: json, status: 401, scope: .window)) { error in
            guard case let CaptureError.failed(message) = error else {
                return XCTFail("expected .failed, got \(error)")
            }
            XCTAssertTrue(message.contains("unauthorized"), "surfaces the wire code/message: \(message)")
        }
    }

    func testDecodePermissionDeniedMapsToPermissionRequired() {
        let json = #"{"ok":false,"error":{"code":"permission_denied","message":"denied","hint":"Grant it."}}"#
            .data(using: .utf8)!
        XCTAssertThrowsError(try NoruCaptureProvider.decode(data: json, status: 403, scope: .window)) { error in
            guard case CaptureError.permissionRequired = error else {
                return XCTFail("expected .permissionRequired, got \(error)")
            }
        }
    }

    func testMissingInlineImageThrows() {
        let json = #"{"ok":true,"files":[{"id":"f1","media_type":"screenshot","source_width":1,"source_height":1,"served_width":1,"served_height":1,"served_max_edge":1568,"bytes":0,"source":{}}]}"#
            .data(using: .utf8)!
        XCTAssertThrowsError(try NoruCaptureProvider.decode(data: json, status: 200, scope: .window))
    }

    // MARK: - End to end through the injected seams

    func testCaptureComposesLocatorAndHTTP() async throws {
        let bundle = #"{"ok":true,"files":[{"id":"f1","media_type":"screenshot","source_width":10,"source_height":10,"served_width":10,"served_height":10,"served_max_edge":1568,"bytes":4,"image_base64":"AAEC","image_mime_type":"image/jpeg","source":{"app_name":"Xcode"}}]}"#
            .data(using: .utf8)!
        let http = StubHTTP(response: (bundle, 200))
        let provider = NoruCaptureProvider(
            locator: StubLocator(endpoint: NoruHostEndpoint(port: 6678, token: "tok")),
            http: http)
        let result = try await provider.capture(scope: .window, quick: false, encoding: encoding())
        XCTAssertEqual(result.screenshotBase64, "AAEC")
        XCTAssertEqual(result.appName, "Xcode")
        XCTAssertEqual(http.capturedToken, "tok")
        XCTAssertEqual(http.capturedURL?.absoluteString, "http://127.0.0.1:6678/capture")
        let body = try XCTUnwrap(http.capturedBody)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(obj["mode"] as? String, "window_under_cursor")
    }

    func testLocatorFailurePropagates() async {
        let provider = NoruCaptureProvider(locator: ThrowingLocator(), http: StubHTTP(response: (Data(), 200)))
        do {
            _ = try await provider.capture(scope: .window, quick: false, encoding: encoding())
            XCTFail("expected locate() failure to propagate")
        } catch {
            // expected
        }
    }
}
