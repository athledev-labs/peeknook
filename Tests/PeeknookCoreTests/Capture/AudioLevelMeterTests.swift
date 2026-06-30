// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// The pure level-meter policy: RMS energy, the dBFS → 0...1 normalization, the attack/decay ballistics,
/// and the perceptible-change gate. Clock-free, so it pins the meter's behavior (including "silence reads
/// 0", the no-fake-pulse invariant) apart from the device-only audio tap.
final class AudioLevelMeterTests: XCTestCase {

    func testSumOfSquaresOfEmptyBufferIsZero() {
        XCTAssertEqual(AudioLevelMeter.sumOfSquares([]), 0)
    }

    func testSumOfSquaresAccumulatesEnergy() {
        XCTAssertEqual(AudioLevelMeter.sumOfSquares([1, -1]), 2, accuracy: 1e-6)
        XCTAssertEqual(AudioLevelMeter.sumOfSquares([0.5]), 0.25, accuracy: 1e-6)
    }

    func testNormalizedSilenceIsZero() {
        XCTAssertEqual(AudioLevelMeter.normalized(meanSquare: 0), 0)
    }

    func testNormalizedFullScaleIsOne() {
        // RMS 1.0 -> 0 dBFS -> top of the meter.
        XCTAssertEqual(AudioLevelMeter.normalized(meanSquare: 1), 1, accuracy: 1e-6)
    }

    func testNormalizedBelowFloorIsZero() {
        // -60 dBFS sits under the -50 dB floor -> reads as silence, not a permanent glow.
        let meanSquare = pow(Float(10), -60 / 10)   // rms = 10^(-60/20); meanSquare = rms^2 = 10^(-60/10)
        XCTAssertEqual(AudioLevelMeter.normalized(meanSquare: meanSquare), 0)
    }

    func testNormalizedAtFloorIsZeroAndIsMonotonic() {
        let atFloor = pow(Float(10), -50 / 10)
        XCTAssertEqual(AudioLevelMeter.normalized(meanSquare: atFloor), 0, accuracy: 1e-5)
        let quiet = AudioLevelMeter.normalized(meanSquare: pow(Float(10), -30 / 10))
        let loud = AudioLevelMeter.normalized(meanSquare: pow(Float(10), -10 / 10))
        XCTAssertGreaterThan(loud, quiet)
        XCTAssertGreaterThan(quiet, 0)
    }

    func testSmoothingRisesFasterThanItFalls() {
        let rising = AudioLevelMeter.smoothed(previous: 0, target: 1)
        let falling = AudioLevelMeter.smoothed(previous: 1, target: 0)
        // attack closes half the gap; decay closes a fifth -> the meter chases up faster than down.
        XCTAssertEqual(rising, AudioLevelMeter.attack, accuracy: 1e-6)
        XCTAssertEqual(falling, 1 - AudioLevelMeter.decay, accuracy: 1e-6)
        XCTAssertGreaterThan(rising, 1 - falling)
    }

    func testSmoothingSnapsToZeroBelowRestFloor() {
        // Decaying through the rest floor settles the meter at exactly empty.
        XCTAssertEqual(AudioLevelMeter.smoothed(previous: 0.01, target: 0), 0)
    }

    func testSmoothingClampsToUnitRange() {
        XCTAssertLessThanOrEqual(AudioLevelMeter.smoothed(previous: 1, target: 5), 1)
        XCTAssertGreaterThanOrEqual(AudioLevelMeter.smoothed(previous: 0, target: -5), 0)
    }

    func testPerceptibleChangeGatesTinyAndSteadyUpdates() {
        XCTAssertFalse(AudioLevelMeter.isPerceptibleChange(from: 0, to: 0))
        XCTAssertFalse(AudioLevelMeter.isPerceptibleChange(from: 0.5, to: 0.505))
        XCTAssertTrue(AudioLevelMeter.isPerceptibleChange(from: 0, to: 0.2))
    }
}
