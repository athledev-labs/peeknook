// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// `num_ctx` must be large enough that a capture's image tokens don't overflow Ollama's 4096 default
/// (the `exceed_context_size_error` crash), and it scales with RAM so a tight Mac doesn't pin an
/// oversized KV cache on top of an already-large resident vision model.
final class OllamaContextPolicyTests: XCTestCase {
    func testContextScalesWithRAMTier() {
        XCTAssertEqual(OllamaContextPolicy.contextTokens(forPhysicalMemoryGB: 8), 8_192)
        XCTAssertEqual(OllamaContextPolicy.contextTokens(forPhysicalMemoryGB: 18), 8_192)
        XCTAssertEqual(OllamaContextPolicy.contextTokens(forPhysicalMemoryGB: 24), 16_384)
        XCTAssertEqual(OllamaContextPolicy.contextTokens(forPhysicalMemoryGB: 36), 16_384)
        XCTAssertEqual(OllamaContextPolicy.contextTokens(forPhysicalMemoryGB: 48), 32_768)
        XCTAssertEqual(OllamaContextPolicy.contextTokens(forPhysicalMemoryGB: 128), 32_768)
    }

    func testEveryTierClearsThe4096DefaultThatCausedTheCrash() {
        for gb in [8, 18, 24, 36, 48, 128] {
            XCTAssertGreaterThan(
                OllamaContextPolicy.contextTokens(forPhysicalMemoryGB: gb), 4_096,
                "\(gb) GB: num_ctx must exceed Ollama's 4096 default that the capture overflowed"
            )
        }
    }
}
