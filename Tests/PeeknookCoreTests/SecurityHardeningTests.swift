// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import XCTest
@testable import PeeknookCore

final class SecurityHardeningTests: XCTestCase {
    // MARK: - Workstream A

    func testInferenceImageReplayDefaultsAndRoundTrips() throws {
        let legacy = Data("""
        {"mode":"general","textModel":"gemma4:e4b","ollamaBaseURL":"http://127.0.0.1:11434"}
        """.utf8)
        let decoded = try JSONDecoder().decode(PeeknookSettings.self, from: legacy)
        XCTAssertEqual(decoded.inferenceImageReplay, .latestOnly)

        let custom = PeeknookSettings(textModel: "x", inferenceImageReplay: .lastTwo)
        let back = try JSONDecoder().decode(PeeknookSettings.self, from: JSONEncoder().encode(custom))
        XCTAssertEqual(back.inferenceImageReplay, .lastTwo)
        XCTAssertEqual(back.inferenceImageReplay.maxImagePayloads, 2)
    }

    // MARK: - Workstream B

    func testArchiveEncryptsAndDecryptsRoundTrip() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peeknook-crypto-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let protection = FixedKeyArchiveProtection()
        let store = ConversationArchiveStore(directory: dir, protection: protection)
        let thread = ConversationThread(turns: [ChatTurn(id: 1, kind: .user("hello"))])

        let saveResult = await store.save(thread)
        XCTAssertTrue(saveResult.isSuccess)

        let raw = try Data(contentsOf: dir.appendingPathComponent("\(thread.id.uuidString).json"))
        XCTAssertTrue(ArchiveEnvelope.isEncrypted(raw))

        let loaded = await store.load(id: thread.id)
        XCTAssertEqual(loaded?.turns.count, 1)
    }

    func testArchiveMigratesPlaintextToEncryptedOnSave() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peeknook-migrate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let thread = ConversationThread(turns: [ChatTurn(id: 1, kind: .user("legacy"))])
        let plaintext = try JSONEncoder().encode(thread)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try plaintext.write(to: dir.appendingPathComponent("\(thread.id.uuidString).json"))

        let protection = FixedKeyArchiveProtection()
        let store = ConversationArchiveStore(directory: dir, protection: protection)
        let loaded = await store.load(id: thread.id)
        XCTAssertEqual(loaded?.turns.first?.kind, .user("legacy"))

        _ = await store.save(thread)
        let raw = try Data(contentsOf: dir.appendingPathComponent("\(thread.id.uuidString).json"))
        XCTAssertTrue(ArchiveEnvelope.isEncrypted(raw))
    }

    // MARK: - Workstream C

    func testOllamaURLPolicyLoopbackAndHTTPS() {
        XCTAssertFalse(OllamaURLPolicy.usesRemoteOllama("http://127.0.0.1:11434"))
        XCTAssertFalse(OllamaURLPolicy.usesRemoteOllama("http://localhost:11434"))
        XCTAssertFalse(OllamaURLPolicy.usesRemoteOllama("http://[::1]:11434"))
        XCTAssertTrue(OllamaURLPolicy.usesRemoteOllama("http://192.168.1.10:11434"))

        XCTAssertEqual(
            OllamaURLPolicy.validate("http://127.0.0.1:11434", acceptInsecureRemote: false),
            .valid(URL(string: "http://127.0.0.1:11434")!)
        )
        XCTAssertEqual(
            OllamaURLPolicy.validate("http://192.168.1.10:11434", acceptInsecureRemote: false),
            .insecureRemoteHTTP
        )
        XCTAssertEqual(
            OllamaURLPolicy.validate("https://192.168.1.10:11434", acceptInsecureRemote: false),
            .valid(URL(string: "https://192.168.1.10:11434")!)
        )
        XCTAssertEqual(
            OllamaURLPolicy.validate("ftp://127.0.0.1:11434", acceptInsecureRemote: false),
            .unsupportedScheme
        )
    }

    func testStreamRejectsInsecureRemoteHTTP() async {
        let engine = OllamaInferenceEngine(session: URLSession(configuration: .ephemeral))
        let request = InferenceRequest(
            mode: .general,
            messages: [.init(role: .user, text: "x", imageBase64: nil)],
            model: "gemma4:e4b",
            ollamaBaseURL: "http://192.168.1.10:11434",
            acceptInsecureRemoteOllama: false
        )

        do {
            for try await _ in engine.stream(request: request) {}
            XCTFail("Expected insecureRemoteHTTP")
        } catch let error as InferenceError {
            if case .insecureRemoteHTTP = error {} else {
                XCTFail("Expected insecureRemoteHTTP, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Workstream D

    func testSensitiveTextHeuristicsBlocksKnownPatterns() {
        XCTAssertTrue(SensitiveTextHeuristics.looksSensitive("sk-live-abcdefghijklmnopqrstuvwxyz"))
        XCTAssertTrue(SensitiveTextHeuristics.looksSensitive("Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxIn0.sig"))
        XCTAssertTrue(SensitiveTextHeuristics.looksSensitive("-----BEGIN PRIVATE KEY-----"))
        XCTAssertFalse(SensitiveTextHeuristics.looksSensitive("What does this kanji mean?"))
        XCTAssertTrue(SensitiveTextHeuristics.shouldSkipWebLookup(
            text: "ghp_1234567890abcdefghijklmnopqrstuvwxyz",
            windowTitle: nil,
            appName: nil
        ))
    }

    func testWebSearchQuerySkipsSensitiveText() {
        let capture = CaptureResult(
            text: "sk-test-abcdefghijklmnopqrstuvwxyz1234567890",
            sourceLabel: "test",
            screenshotBase64: "x"
        )
        XCTAssertNil(WebSearchClient.query(from: capture))
    }

    // MARK: - Workstream E

    func testCaptureAccessibilityPolicySkipsSecureFields() {
        XCTAssertTrue(CaptureAccessibilityPolicy.isSecureSubrole("AXSecureTextField"))
        XCTAssertTrue(CaptureAccessibilityPolicy.isSecureRoleDescription("password"))
        XCTAssertFalse(CaptureAccessibilityPolicy.shouldSkipAccessibilityText(subrole: nil, roleDescription: "text field"))
    }
}

// MARK: - Manual QA checklist (release video)
//
// Hotkey setup feedback: ⌘⇧P before setup complete → setup incomplete failure (not silent no-op)
// On-device speech: voice input with unavailable on-device model → voiceInputIssue banner
// Archive save surfacing: block archive dir → PeekArchivePersistenceBanner after answer
// Inference replay setting: 3 captures with “Latest two” → 2 image payloads in request
// Archive encryption: enable Save conversations → thread files start with PKNKENC1 magic
// Remote HTTPS gate: http://LAN without opt-in → failure; https:// or opt-in → proceeds
// Web lookup secrets: enable web lookup + capture sk-… text → no DuckDuckGo POST
// AX secure fields: focused password field without selection → no capture.text
