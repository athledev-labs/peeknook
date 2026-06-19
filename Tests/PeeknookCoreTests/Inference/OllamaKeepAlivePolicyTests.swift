// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// `keep_alive` scales down on low-RAM Macs so a resident multi-GB model isn't pinned for 10 minutes
/// after a single capture, and the in-session warm gate must track it (flip to cold *before* eviction).
final class OllamaKeepAlivePolicyTests: XCTestCase {
    func testKeepAliveScalesWithRAMTier() {
        XCTAssertEqual(OllamaKeepAlivePolicy.keepAlive(forPhysicalMemoryGB: 8), "120s")
        XCTAssertEqual(OllamaKeepAlivePolicy.keepAlive(forPhysicalMemoryGB: 18), "120s")
        XCTAssertEqual(OllamaKeepAlivePolicy.keepAlive(forPhysicalMemoryGB: 24), "300s")
        XCTAssertEqual(OllamaKeepAlivePolicy.keepAlive(forPhysicalMemoryGB: 36), "300s")
        XCTAssertEqual(OllamaKeepAlivePolicy.keepAlive(forPhysicalMemoryGB: 48), "600s")
        XCTAssertEqual(OllamaKeepAlivePolicy.keepAlive(forPhysicalMemoryGB: 128), "600s")
    }

    func testWarmWindowStaysUnderKeepAliveSoItNeverClaimsWarmAfterEviction() {
        for gb in [8, 18, 24, 36, 48, 128] {
            let keepAlive = OllamaKeepAlivePolicy.keepAliveSeconds(forPhysicalMemoryGB: gb)
            let warm = OllamaKeepAlivePolicy.warmWindowSeconds(forPhysicalMemoryGB: gb)
            XCTAssertLessThan(warm, TimeInterval(keepAlive), "\(gb) GB: warm window must be < keep_alive")
            XCTAssertGreaterThanOrEqual(warm, 30, "\(gb) GB: warm window must stay positive")
        }
    }

    func testTopTierPreservesOriginal10mWindowWith9mGate() {
        XCTAssertEqual(OllamaKeepAlivePolicy.keepAliveSeconds(forPhysicalMemoryGB: 64), 600)
        XCTAssertEqual(OllamaKeepAlivePolicy.warmWindowSeconds(forPhysicalMemoryGB: 64), 540) // the prior 9m margin
    }
}
