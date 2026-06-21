// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// The pre-flight RAM fit-check: does a model's resident footprint fit the memory that's actually
/// free? Drives the "needs ~N GB, you have ~M GB free" warning and the skip-proactive-warm guard.
final class ModelMemoryPolicyTests: XCTestCase {
    private let GB: Int64 = 1_000_000_000

    private func snapshot(physicalGB: Int64, availableGB: Int64) -> SystemMemorySnapshot {
        SystemMemorySnapshot(physicalBytes: physicalGB * GB, availableBytes: availableGB * GB)
    }

    func testFitsWhenAmpleFreeMemory() {
        // e2b (~7 GB → ~8.4 GB working set) on a Mac with 20 GB free: comfortable.
        let fit = ModelMemoryPolicy.fit(modelBytes: 7 * GB, snapshot: snapshot(physicalGB: 32, availableGB: 20))
        XCTAssertEqual(fit, .fits)
    }

    func testInsufficientReproducesTheReportedFreeze() {
        // e4b (~10 GB → ~12 GB working set) with only ~6 GB free, as measured during the crash.
        let fit = ModelMemoryPolicy.fit(modelBytes: 10 * GB, snapshot: snapshot(physicalGB: 18, availableGB: 6))
        XCTAssertEqual(fit, .insufficient)
    }

    func testTightWhenItFitsButWithoutReserve() {
        // 10 GB → 12 GB required; 13 GB free clears `required` but not `required + 3 GB reserve`.
        let fit = ModelMemoryPolicy.fit(modelBytes: 10 * GB, snapshot: snapshot(physicalGB: 18, availableGB: 13))
        XCTAssertEqual(fit, .tight)
    }

    func testUnknownSizeSkipsTheCheck() {
        XCTAssertNil(ModelMemoryPolicy.fit(modelBytes: nil, snapshot: snapshot(physicalGB: 18, availableGB: 2)))
        XCTAssertNil(ModelMemoryPolicy.fit(modelBytes: 0, snapshot: snapshot(physicalGB: 18, availableGB: 2)))
    }

    func testWarningGigabytesReportCatalogSizeAndTotalRAM() {
        let gb = ModelMemoryPolicy.warningGigabytes(
            modelBytes: 10 * GB,
            snapshot: snapshot(physicalGB: 18, availableGB: 6)
        )
        XCTAssertEqual(gb.needGB, 10)  // catalog footprint, not the internal +20%
        XCTAssertEqual(gb.totalGB, 18) // total RAM, not the fluctuating instantaneously-free figure
    }

    func testCurrentSnapshotIsSane() {
        let snap = SystemMemorySnapshot.current()
        XCTAssertGreaterThan(snap.physicalBytes, 0)
        XCTAssertGreaterThan(snap.availableBytes, 0)
        XCTAssertLessThanOrEqual(snap.availableBytes, snap.physicalBytes)
    }
}
