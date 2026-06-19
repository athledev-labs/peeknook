// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// Locks the headroom-aware RAM tiers: a resident vision model is the dominant memory cost, so the
/// recommended tag must leave room for macOS + other apps, not merely fit. e4b (~10 GB resident)
/// only at ≥32 GB and 26b (~18 GB) only at ≥48 GB; everything below gets e2b.
final class SystemProfileTests: XCTestCase {
    func testLowAndMidRAMGetsE2B() {
        // The 16/18/24 GB Macs that previously got e4b and could swap-thrash now stay on e2b.
        for gb in [4, 8, 16, 18, 24, 31] {
            XCTAssertEqual(
                SystemProfile.recommendedModel(forPhysicalMemoryGB: gb),
                "gemma4:e2b",
                "\(gb) GB should recommend e2b"
            )
        }
    }

    func testE4BNeedsAtLeast32GB() {
        XCTAssertEqual(SystemProfile.recommendedModel(forPhysicalMemoryGB: 32), "gemma4:e4b")
        XCTAssertEqual(SystemProfile.recommendedModel(forPhysicalMemoryGB: 36), "gemma4:e4b")
        XCTAssertEqual(SystemProfile.recommendedModel(forPhysicalMemoryGB: 47), "gemma4:e4b")
    }

    func test26BNeedsAtLeast48GB() {
        XCTAssertEqual(SystemProfile.recommendedModel(forPhysicalMemoryGB: 48), "gemma4:26b")
        XCTAssertEqual(SystemProfile.recommendedModel(forPhysicalMemoryGB: 64), "gemma4:26b")
        XCTAssertEqual(SystemProfile.recommendedModel(forPhysicalMemoryGB: 128), "gemma4:26b")
    }

    func testTierBoundariesAreInclusiveLowerExclusiveUpper() {
        // 31 → e2b, 32 → e4b (the threshold) and 47 → e4b, 48 → 26b.
        XCTAssertEqual(SystemProfile.recommendedModel(forPhysicalMemoryGB: 31), "gemma4:e2b")
        XCTAssertEqual(SystemProfile.recommendedModel(forPhysicalMemoryGB: 32), "gemma4:e4b")
        XCTAssertEqual(SystemProfile.recommendedModel(forPhysicalMemoryGB: 47), "gemma4:e4b")
        XCTAssertEqual(SystemProfile.recommendedModel(forPhysicalMemoryGB: 48), "gemma4:26b")
    }

    func testCurrentReadsRealRAMAndStaysConsistent() {
        let profile = SystemProfile.current()
        XCTAssertGreaterThanOrEqual(profile.physicalMemoryGB, 1)
        XCTAssertEqual(
            profile.suggestedTextModel,
            SystemProfile.recommendedModel(forPhysicalMemoryGB: profile.physicalMemoryGB)
        )
    }
}
