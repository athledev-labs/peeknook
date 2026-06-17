// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// The clipboard ground ("read what you copied"): a new perception surface that reads the text the user
/// has copied and folds it into a TEXT leg — no image, so it never trips the vision gate, fully local
/// and zero-permission (the copy itself is the consent). These tests cover everything except the live
/// `NSPasteboard` read (platform-only); that path is isolated behind ``ClipboardReading`` and faked
/// here with ``StubClipboardReader``.
final class ClipboardGroundTests: XCTestCase {
    private static let encoding = CaptureEncodingPolicy.resolve(scope: .window, quick: false, quality: .balanced)

    // MARK: - Ground value + permissions

    func testClipboardGroundHasStableRawValue() {
        XCTAssertEqual(Ground.clipboard.rawValue, "clipboard")
        XCTAssertEqual(Ground(rawValue: "clipboard"), .clipboard)
        XCTAssertTrue(Ground.allCases.contains(.clipboard))
    }

    func testClipboardRequiresNoPermissions() {
        // The user already copied the text — that copy is the consent. No TCC gate.
        XCTAssertEqual(Ground.clipboard.requiredPermissions, [])
    }

    func testClipboardIsFoldableAndATextOnlyLeg() {
        XCTAssertTrue(Ground.multiGroundEligible.contains(.clipboard), "a profile can fold in the clipboard")
        XCTAssertTrue(Ground.textOnlyLegs.contains(.clipboard), "the clipboard carries text, not an image")
    }

    // MARK: - Provider policy (text leg, no vision)

    func testProviderReturnsCopiedTextLegWithNoImage() async throws {
        let provider = ClipboardCaptureProvider(
            reader: StubClipboardReader(scriptedString: "git rebase --onto main feature")
        )
        let result = try await provider.capture(scope: .window, quick: false, encoding: Self.encoding)

        XCTAssertEqual(result.ground, .clipboard)
        XCTAssertEqual(result.text, "git rebase --onto main feature")
        XCTAssertNil(result.screenshotBase64, "copied text carries no image")
        XCTAssertNil(result.screenshotBlobID)
        XCTAssertFalse(result.hasVision, "no image means the vision gate must never engage")
    }

    func testProviderThrowsNoContentOnEmptyClipboard() async {
        let provider = ClipboardCaptureProvider(reader: StubClipboardReader(scriptedString: "   "))
        do {
            _ = try await provider.capture(scope: .window, quick: false, encoding: Self.encoding)
            XCTFail("an empty clipboard must throw, not ship a blank leg")
        } catch {
            XCTAssertEqual(error as? CaptureError, .noContent)
        }
    }

    func testProviderThrowsNoContentWhenClipboardHoldsNoText() async {
        let provider = ClipboardCaptureProvider(reader: StubClipboardReader(scriptedString: nil))
        do {
            _ = try await provider.capture(scope: .window, quick: false, encoding: Self.encoding)
            XCTFail("a non-text clipboard must throw, not ship a blank leg")
        } catch {
            XCTAssertEqual(error as? CaptureError, .noContent)
        }
    }

    // MARK: - Modality resolution

    func testClipboardResolvesAsTranscriptModality() {
        XCTAssertEqual(MediaPayload.Kind.resolved(for: .clipboard), .transcript)
    }

    // MARK: - Registry wiring

    func testTestingDependenciesRegisterClipboardProvider() async throws {
        let deps = await PeeknookDependencies.testing()
        let provider = try deps.captureRegistry.resolve(.clipboard)
        XCTAssertTrue(provider is ClipboardCaptureProvider)
        let result = try await provider.capture(scope: .window, quick: false, encoding: Self.encoding)
        XCTAssertEqual(result.ground, .clipboard)
        XCTAssertFalse(result.hasVision)
    }

    // MARK: - Single-leg prompt (copied text, not a screenshot)

    func testCopiedTextLegPromptDescribesClipboardNotScreenshot() {
        let capture = CaptureResult(
            text: "TODO: file the bug before the demo.",
            sourceLabel: "Clipboard",
            ground: .clipboard
        )
        let message = PromptBuilder.captureUserMessage(capture: capture, assembly: PromptAssembly(answerDepth: .deep))

        XCTAssertTrue(message.contains("Ground: clipboard"), "the clipboard ground is named")
        XCTAssertTrue(message.contains("Copied clipboard text:"), "the text is labelled as copied content")
        XCTAssertTrue(message.contains("TODO: file the bug before the demo."), "the copied text rides in the message")
        XCTAssertFalse(message.contains("A screenshot is attached"), "no screenshot is claimed")
        XCTAssertFalse(message.contains("rely on the screenshot"), "an image-less leg must not point at a screenshot")
        XCTAssertFalse(message.contains("prefer the screenshot"), "the copied text is primary, not supplementary")
    }

    // MARK: - Multi-ground prompt (screen image + clipboard text)

    func testMultiGroundPromptNamesScreenshotAndClipboardCorrectly() {
        let screen = MediaPayload(
            capture: CaptureResult(text: "Failing assertion", sourceLabel: "Xcode", appName: "Xcode", screenshotBase64: "SCRb64", ground: .screen),
            kind: .image,
            imageBase64: "SCRb64"
        )
        let clipboard = MediaPayload(
            capture: CaptureResult(text: "expected 3 but got 4", sourceLabel: "Clipboard", ground: .clipboard),
            kind: .transcript,
            imageBase64: nil
        )
        let message = PromptBuilder.multiGroundUserMessage(
            payloads: [screen, clipboard],
            assembly: PromptAssembly(answerDepth: .deep)
        )

        // Only the screen leg is an image; the clipboard leg contributes text only.
        XCTAssertTrue(message.contains("(1 views, one question)"), "only the one image view is counted")
        XCTAssertTrue(message.contains("SCREENSHOT"), "the screen leg is named as a screenshot")
        XCTAssertTrue(message.contains("Transcript of the copied text:"), "the clipboard leg reads as a text block")
        XCTAssertTrue(message.contains("expected 3 but got 4"), "the copied text is present")
        XCTAssertFalse(
            message.contains("Supplementary extracted text from the copied text"),
            "the copied text must not be framed as supplement-to-image"
        )
    }

    // MARK: - Secret handling (consistent with every other egress path)

    func testCopiedSecretIsGatedFromWebLookupLikeAnyOtherCapture() {
        // A copied API key must never become a search query — the same heuristics that gate a
        // screenshot's text gate a clipboard leg, because the query builder keys off CaptureResult.
        let secret = CaptureResult(
            text: "sk-ABCDEFGHIJKLMNOPQRSTUVWX",
            sourceLabel: "Clipboard",
            ground: .clipboard
        )
        XCTAssertNil(WebSearchClient.query(from: secret), "a copied secret must not leave the Mac as a query")

        // A benign copied string still yields a query, so the gate is the secret, not the ground.
        let benign = CaptureResult(text: "swift actor isolation", sourceLabel: "Clipboard", ground: .clipboard)
        XCTAssertEqual(WebSearchClient.query(from: benign), "swift actor isolation")
    }

    // MARK: - Tolerant decoding (a persisted clipboard leg survives; an unknown ground degrades)

    func testClipboardGroundRoundTripsThroughJSON() throws {
        let capture = CaptureResult(text: "copied note", sourceLabel: "Clipboard", ground: .clipboard)
        let decoded = try JSONDecoder().decode(CaptureResult.self, from: JSONEncoder().encode(capture))
        XCTAssertEqual(decoded.ground, .clipboard)
        XCTAssertEqual(decoded.text, "copied note")
    }

    func testUnknownGroundStillDegradesToScreen() throws {
        let future = Data(#"{"sourceLabel":"Window","ground":"telepathy"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(CaptureResult.self, from: future).ground, .screen)
    }
}
