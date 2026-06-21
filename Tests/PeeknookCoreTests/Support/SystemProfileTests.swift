// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// Locks the headroom-aware RAM tiers: a resident vision model is the dominant memory cost, so the
/// recommended tag must leave room for macOS + other apps, not merely fit. Only a truly tight Mac
/// (<16 GB) gets e2b; 16–31 GB defaults to Qwen2.5-VL 7B (accurate at detailed screens, ~6 GB
/// resident, fits where e4b couldn't); e4b only at ≥32 GB and 26b only at ≥48 GB.
final class SystemProfileTests: XCTestCase {
    func testVeryTightRAMStaysOnE2B() {
        // Below 16 GB even a 7B vision model crowds the system, so the lightest tier (e2b) holds.
        for gb in [4, 8, 12, 15] {
            XCTAssertEqual(
                SystemProfile.recommendedModel(forPhysicalMemoryGB: gb),
                "gemma4:e2b",
                "\(gb) GB should recommend e2b"
            )
        }
    }

    func testCommonMacsGetQwenVLNotTheImageShyE2B() {
        // The 16/18/24 GB Macs that used to default to e2b — which misreads detailed screens — now
        // get Qwen2.5-VL 7B, which reads them well and still fits with headroom.
        for gb in [16, 18, 24, 31] {
            XCTAssertEqual(
                SystemProfile.recommendedModel(forPhysicalMemoryGB: gb),
                "qwen2.5vl:7b",
                "\(gb) GB should recommend Qwen2.5-VL 7B"
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
        // 15 → e2b, 16 → Qwen (the threshold); 31 → Qwen, 32 → e4b; 47 → e4b, 48 → 26b.
        XCTAssertEqual(SystemProfile.recommendedModel(forPhysicalMemoryGB: 15), "gemma4:e2b")
        XCTAssertEqual(SystemProfile.recommendedModel(forPhysicalMemoryGB: 16), "qwen2.5vl:7b")
        XCTAssertEqual(SystemProfile.recommendedModel(forPhysicalMemoryGB: 31), "qwen2.5vl:7b")
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
