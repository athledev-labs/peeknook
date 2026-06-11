// SPDX-License-Identifier: Apache-2.0

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import PeeknookCore

/// File-import ground: the pure URL→`CaptureResult` decode, the permission-free ground, the prompt
/// language, the idle command's gate-free shape, and the end-to-end commit→answer wiring.
final class FileImportTests: XCTestCase {
    private var tempURLs: [URL] = []
    private let encoding = CaptureEncodingParams(maxPixel: 512, jpegQuality: 0.8)

    override func tearDown() {
        for url in tempURLs { try? FileManager.default.removeItem(at: url) }
        tempURLs = []
        super.tearDown()
    }

    // MARK: Pure decode

    func testDecodesImageFileToFileGroundCapture() throws {
        let url = try writeTempPNG()
        let result = try FileImportCaptureProvider.makeResult(fromFileAt: url, encoding: encoding)
        XCTAssertEqual(result.ground, .file)
        XCTAssertTrue(result.hasVision)
        XCTAssertEqual(result.sourceLabel, "Imported file")
        XCTAssertEqual(result.appName, url.lastPathComponent, "the filename rides in appName for the trust line")
        XCTAssertNil(result.text)
    }

    func testDecodesPDFFirstPage() throws {
        let url = try writeTempPDF()
        let result = try FileImportCaptureProvider.makeResult(fromFileAt: url, encoding: encoding)
        XCTAssertEqual(result.ground, .file)
        XCTAssertTrue(result.hasVision, "the first PDF page should encode to a vision payload")
    }

    func testUnsupportedFileThrows() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("peeknook-test-\(UUID().uuidString).txt")
        try "not an image".write(to: url, atomically: true, encoding: .utf8)
        tempURLs.append(url)
        XCTAssertThrowsError(try FileImportCaptureProvider.makeResult(fromFileAt: url, encoding: encoding))
    }

    func testRegistryCaptureArmThrows() async {
        // The scope/quick capture arm is unreachable in the shipped flow (file import uses the URL arm).
        let provider = FileImportCaptureProvider()
        do {
            _ = try await provider.capture(scope: .window, quick: false, encoding: encoding)
            XCTFail("the capture() arm must throw — there is no file to read")
        } catch {}
    }

    // MARK: Ground + command shape

    func testFileGroundRequiresNoPermission() {
        XCTAssertEqual(Ground.file.requiredPermissions, [], "the open panel grants file access — no TCC gate")
    }

    func testImportFileCommandIsGateFreeAndHideable() {
        let command = CommandLayout.screenDefault.commands.first { $0.id == "idle.importFile" }
        XCTAssertEqual(command?.action, .importFile)
        XCTAssertEqual(command?.requiredPermissions, [])
        XCTAssertEqual(command?.requiredModules, [])
        XCTAssertTrue(command?.isCustomizable ?? false, "Import file can be hidden via Settings → Layout")
    }

    // MARK: Prompt language

    func testPromptUsesImportedFileLanguage() {
        let capture = CaptureResult(
            text: nil, sourceLabel: "Imported file", appName: "Report.pdf",
            screenshotBase64: "QQ==", ground: .file
        )
        let message = PromptBuilder.captureUserMessage(capture: capture, assembly: PromptAssembly(answerDepth: .deep))
        XCTAssertTrue(message.contains("imported file"), "prompt should name the file ground:\n\(message)")
        XCTAssertTrue(message.contains("Report.pdf"), "the filename should appear as the target:\n\(message)")
        XCTAssertFalse(message.contains("A screenshot is attached"), "file ground must not claim a screenshot")
    }

    // MARK: End-to-end wiring

    @MainActor
    func testBeginFileImportCommitsAFileTurnAndAnswers() async throws {
        let url = try writeTempPNG()
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(textModel: "x"),
            captureRegistry: GroundRegistry([
                .screen: StubCaptureProvider(sampleText: "screen"),
                .file: FileImportCaptureProvider(),
            ]),
            inference: MockInferenceEngine(tokens: ["ok"])
        )

        orchestrator.beginFileImport(url: url)

        let phase = await orchestrator.waitForResult("ok")
        guard case .result = phase else { return XCTFail("expected a result, got \(phase)") }
        guard case .image(let capture)? = orchestrator.conversation.first?.kind else {
            return XCTFail("expected the imported file as the first turn")
        }
        XCTAssertEqual(capture.ground, .file)
    }

    // MARK: Fixtures

    private func writeTempPNG(width: Int = 12, height: Int = 12) throws -> URL {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = { () -> CGImage? in
            context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()
        }() else {
            throw FixtureError.render
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("peeknook-test-\(UUID().uuidString).png")
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { throw FixtureError.render }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw FixtureError.render }
        tempURLs.append(url)
        return url
    }

    private func writeTempPDF() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("peeknook-test-\(UUID().uuidString).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 160)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else { throw FixtureError.render }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 20, y: 20, width: 160, height: 120))
        context.endPDFPage()
        context.closePDF()
        tempURLs.append(url)
        return url
    }

    private enum FixtureError: Error { case render }
}
