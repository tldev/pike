//
//  CorridorLock.swift
//  Pike
//
//  Highway corridor lock with distance-based stickiness.
//  Prevents the feed from jumping between adjacent corridors at interchanges.
//

import Foundation
import CoreLocation

struct CorridorKey: Equatable {
    let corridorId: Int
    let highway: String
}

struct CorridorLockState {
    var key: CorridorKey
    var pending: CorridorKey?
    var pendingCount: Int
    var lastConfirmedAt: Date
    var accumulatedMeters: Double = 0
    var lastLocation: CLLocationCoordinate2D?

    /// Bonus in meters subtracted from projection score for the locked corridor.
    /// Grows with accumulated distance via exponential saturation curve.
    var lockBonus: Double {
        let baseBonus: Double = 15
        let accrualCap: Double = 85
        let halfLifeKm: Double = 8
        let km = accumulatedMeters / 1000.0
        return baseBonus + accrualCap * (1 - exp(-km / halfLifeKm))
    }

    /// Number of consecutive signals needed to switch corridors.
    /// Increases with accumulated distance so long drives are harder to dislodge.
    var switchThreshold: Int {
        let base = 3
        let extra = Int(accumulatedMeters / 10_000) // +1 per 10 km
        return min(base + extra, 8)
    }
}

enum CorridorLock {
    /// Hard expiry: if the lock has not been confirmed in this many seconds, it is cleared.
    private static let hardExpirySeconds: TimeInterval = 300

    /// Staleness threshold before exponential decay begins.
    private static let decayOnsetSeconds: TimeInterval = 30

    /// Half-life of accumulated distance decay once stale (seconds).
    private static let decayHalfLifeSeconds: TimeInterval = 60

    /// Maximum per-step distance accumulation to avoid GPS jumps inflating the accumulator.
    private static let maxStepMeters: Double = 500

    static func update(
        lock: inout CorridorLockState?,
        signal: CorridorKey,
        userCoord: CLLocationCoordinate2D,
        now: Date
    ) {
        // Decay accumulated distance based on time since last confirmation.
        // This handles gaps where the lock stops being confirmed but the car is still driving.
        if var existing = lock {
            let staleness = now.timeIntervalSince(existing.lastConfirmedAt)
            if staleness > hardExpirySeconds {
                lock = nil
            } else if staleness > decayOnsetSeconds {
                let decayFactor = pow(0.5, (staleness - decayOnsetSeconds) / decayHalfLifeSeconds)
                existing.accumulatedMeters *= decayFactor
                lock = existing
            }
        }

        if lock == nil {
            lock = CorridorLockState(
                key: signal, pending: nil, pendingCount: 0,
                lastConfirmedAt: now, accumulatedMeters: 0,
                lastLocation: userCoord
            )
            return
        }

        guard var current = lock else { return }

        // Accumulate distance when the signal confirms the current lock
        if current.key == signal {
            if let prev = current.lastLocation {
                let delta = CLLocation(latitude: userCoord.latitude, longitude: userCoord.longitude)
                    .distance(from: CLLocation(latitude: prev.latitude, longitude: prev.longitude))
                current.accumulatedMeters += min(delta, maxStepMeters)
            }
            current.lastLocation = userCoord
            current.lastConfirmedAt = now
            current.pending = nil
            current.pendingCount = 0
            lock = current
            return
        }

        // Signal differs from current lock — count toward a potential switch
        if current.pending == signal {
            current.pendingCount += 1
        } else {
            current.pending = signal
            current.pendingCount = 1
        }

        if current.pendingCount >= current.switchThreshold {
            // Switch to the new corridor, resetting accumulated distance
            current.key = signal
            current.lastConfirmedAt = now
            current.pending = nil
            current.pendingCount = 0
            current.accumulatedMeters = 0
            current.lastLocation = userCoord
        }

        lock = current
    }
}
