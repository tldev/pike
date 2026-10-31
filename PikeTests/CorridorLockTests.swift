import XCTest
import CoreLocation
@testable import Pike

final class CorridorLockTests: XCTestCase {

    private let coord1 = CLLocationCoordinate2D(latitude: 35.0, longitude: -80.0)
    private let coord2 = CLLocationCoordinate2D(latitude: 35.001, longitude: -80.0)
    private let key1 = CorridorKey(corridorId: 0, highway: "I-85")
    private let key2 = CorridorKey(corridorId: 1, highway: "I-77")
    private let now = Date(timeIntervalSince1970: 10_000)

    func testFirstSignalCreatesLock() {
        var lock: CorridorLockState? = nil
        CorridorLock.update(lock: &lock, signal: key1, userCoord: coord1, now: now)
        XCTAssertNotNil(lock)
        XCTAssertEqual(lock?.key, key1)
    }

    func testConfirmingSignalAccumulatesDistance() {
        var lock: CorridorLockState? = CorridorLockState(
            key: key1, pending: nil, pendingCount: 0,
            lastConfirmedAt: now, accumulatedMeters: 0, lastLocation: coord1
        )

        // Move ~111m north.
        CorridorLock.update(lock: &lock, signal: key1, userCoord: coord2, now: now.addingTimeInterval(3))
        XCTAssertNotNil(lock)
        XCTAssertGreaterThan(lock!.accumulatedMeters, 50)
    }

    func testDifferentSignalIncrementsPendingCount() {
        var lock: CorridorLockState? = CorridorLockState(
            key: key1, pending: nil, pendingCount: 0,
            lastConfirmedAt: now, accumulatedMeters: 0, lastLocation: coord1
        )

        CorridorLock.update(lock: &lock, signal: key2, userCoord: coord1, now: now.addingTimeInterval(3))
        XCTAssertEqual(lock?.pending, key2)
        XCTAssertEqual(lock?.pendingCount, 1)
        XCTAssertEqual(lock?.key, key1, "Should not switch yet")
    }

    func testSwitchAfterThresholdReached() {
        var lock: CorridorLockState? = CorridorLockState(
            key: key1, pending: nil, pendingCount: 0,
            lastConfirmedAt: now, accumulatedMeters: 0, lastLocation: coord1
        )

        // Default switchThreshold is 3 (base 3 + 0 extra at 0 accumulated km).
        for i in 0..<3 {
            CorridorLock.update(lock: &lock, signal: key2, userCoord: coord1, now: now.addingTimeInterval(Double(i + 1) * 3))
        }

        XCTAssertEqual(lock?.key, key2, "Should switch after threshold consecutive signals")
        XCTAssertEqual(lock?.accumulatedMeters, 0, "Should reset accumulated distance on switch")
    }

    func testSwitchThresholdIncreasesWithDistance() {
        // With 20km accumulated, threshold should be 3 + floor(20_000/10_000) = 5.
        let state = CorridorLockState(
            key: key1, pending: nil, pendingCount: 0,
            lastConfirmedAt: now, accumulatedMeters: 20_000, lastLocation: coord1
        )
        XCTAssertEqual(state.switchThreshold, 5)
    }

    func testLockBonusExponentialSaturation() {
        let state0 = CorridorLockState(
            key: key1, pending: nil, pendingCount: 0,
            lastConfirmedAt: now, accumulatedMeters: 0, lastLocation: nil
        )
        // At 0m: bonus = 15 + 85 * (1 - 1) = 15.
        XCTAssertEqual(state0.lockBonus, 15.0, accuracy: 0.1)

        let stateHigh = CorridorLockState(
            key: key1, pending: nil, pendingCount: 0,
            lastConfirmedAt: now, accumulatedMeters: 50_000, lastLocation: nil
        )
        // At 50km: bonus ≈ 15 + 85 * (1 - e^(-50/8)) ≈ 15 + 85 * 0.998 ≈ 99.8.
        XCTAssertGreaterThan(stateHigh.lockBonus, 95)
        XCTAssertLessThanOrEqual(stateHigh.lockBonus, 100)
    }

    func testHardExpiryAt300s() {
        var lock: CorridorLockState? = CorridorLockState(
            key: key1, pending: nil, pendingCount: 0,
            lastConfirmedAt: now, accumulatedMeters: 5000, lastLocation: coord1
        )

        // 301 seconds later — should expire the lock.
        CorridorLock.update(lock: &lock, signal: key2, userCoord: coord1, now: now.addingTimeInterval(301))
        // After expiry, the signal creates a new lock.
        XCTAssertEqual(lock?.key, key2, "Should create fresh lock with new signal after hard expiry")
        XCTAssertEqual(lock?.accumulatedMeters, 0, "Fresh lock should have zero accumulated")
    }

    func testDecayReducesAccumulatedDistanceAfterStaleness() {
        var lock: CorridorLockState? = CorridorLockState(
            key: key1, pending: nil, pendingCount: 0,
            lastConfirmedAt: now, accumulatedMeters: 10_000, lastLocation: coord1
        )

        // 90 seconds later: 60s beyond 30s onset. decay = 0.5^(60/60) = 0.5.
        CorridorLock.update(lock: &lock, signal: key1, userCoord: coord1, now: now.addingTimeInterval(90))
        // The decay happens first, then confirming signal accumulates a tiny delta (0 since same coord).
        // accumulatedMeters should be around 5000 (decayed from 10000).
        XCTAssertNotNil(lock)
        XCTAssertLessThan(lock!.accumulatedMeters, 6000)
        XCTAssertGreaterThan(lock!.accumulatedMeters, 4000)
    }

    func testMaxStepPreventsGPSJumps() {
        var lock: CorridorLockState? = CorridorLockState(
            key: key1, pending: nil, pendingCount: 0,
            lastConfirmedAt: now, accumulatedMeters: 0, lastLocation: coord1
        )

        // Jump 10km away — should cap at 500m per step.
        let farCoord = CLLocationCoordinate2D(latitude: 35.1, longitude: -80.0)
        CorridorLock.update(lock: &lock, signal: key1, userCoord: farCoord, now: now.addingTimeInterval(3))
        XCTAssertLessThanOrEqual(lock!.accumulatedMeters, 500)
    }
}
