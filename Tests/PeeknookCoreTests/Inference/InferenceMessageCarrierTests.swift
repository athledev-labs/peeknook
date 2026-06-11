// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// `InferenceMessage` widened its image payload from `imageBase64: String?` to `imagesBase64: [String]`
/// (Composite D12 slice 1). Single-image and image-free messages stay byte-identical via the
/// back-compat init; a multi-image message threads every image into one wire message in order.
final class InferenceMessageCarrierTests: XCTestCase {
    private func openAIEndpoint() -> InferenceEndpoint {
        .openAICompatible(
            baseURL: "http://127.0.0.1:1234",
            apiKeyRef: .openAICompatiblePrimary,
            acceptInsecureRemote: false
        )
    }

    func testBackCompatSingleImageWrapsToOneElement() {
        XCTAssertEqual(InferenceMessage(role: .user, text: "x", imageBase64: "AAA").imagesBase64, ["AAA"])
    }

    func testNilOrOmittedImageIsEmpty() {
        XCTAssertTrue(InferenceMessage(role: .assistant, text: "x").imagesBase64.isEmpty)
        XCTAssertTrue(InferenceMessage(role: .user, text: "x", imageBase64: nil).imagesBase64.isEmpty)
    }

    func testMultiImageCarrierPreservesOrder() {
        XCTAssertEqual(
            InferenceMessage(role: .user, text: "x", imagesBase64: ["scr", "cam"]).imagesBase64,
            ["scr", "cam"]
        )
    }

    func testOpenAIWireThreadsBothImagesIntoOneMessageInOrder() throws {
        let req = InferenceRequest(
            mode: .general,
            messages: [InferenceMessage(role: .user, text: "compare", imagesBase64: ["scr", "cam"])],
            model: "m",
            endpoint: openAIEndpoint()
        )
        let wire = OpenAICompatibleInferenceEngine.wireMessages(from: req, systemPrompt: "sys")
        XCTAssertEqual(wire.count, 2, "system + one user message")
        XCTAssertEqual(wire[1].imagesBase64, ["scr", "cam"])
        let content = OpenAIChatMessage.contentValue(text: wire[1].text, imagesBase64: wire[1].imagesBase64)
        let parts = try XCTUnwrap(content as? [[String: Any]])
        XCTAssertEqual(
            parts.filter { $0["type"] as? String == "image_url" }.count, 2,
            "both composite images ride one message as two image_url parts"
        )
    }

    func testOpenAISingleImageStillOneWirePart() throws {
        let req = InferenceRequest(
            mode: .general,
            messages: [InferenceMessage(role: .user, text: "x", imageBase64: "only")],
            model: "m",
            endpoint: openAIEndpoint()
        )
        let wire = OpenAICompatibleInferenceEngine.wireMessages(from: req, systemPrompt: "sys")
        XCTAssertEqual(wire[1].imagesBase64, ["only"], "single-image path is byte-identical")
    }
}
