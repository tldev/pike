//
//  ExitStabilizer.swift
//  Pike
//
//  Holds recently-shown exits for a few cycles to prevent UI jitter
//  when consecutive refreshes return slightly different exits.
//

import Foundation
import CoreLocation

struct ExitStabilizer {

    private var recent: [String: (card: ExitCard, lastSeen: Date, missCount: Int)] = [:]

    /// Merge new cards with recently-seen ones to stabilize the UI.
    /// An exit that was visible on recent refreshes stays in the list for a few
    /// cycles even if the current query didn't find it, as long as it's
    /// still ahead of the user.
    mutating func stabilize(
        _ newCards: [ExitCard],
        userLocation: CLLocation,
        userCourse: CLLocationDirection,
        limit: Int
    ) -> [ExitCard] {
        let now = Date()
        let newIds = Set(newCards.map(\.id))

        // Update tracking: mark every new card as freshly seen.
        for card in newCards {
            recent[card.id] = (card: card, lastSeen: now, missCount: 0)
        }

        // Increment miss count for cards not in this refresh.
        for (id, entry) in recent where !newIds.contains(id) {
            recent[id] = (card: entry.card, lastSeen: entry.lastSeen, missCount: entry.missCount + 1)
        }

        // Evict entries that are stale, behind the user, or missed too often.
        let maxMisses = 3
        let maxStaleAge: TimeInterval = 30
        recent = recent.filter { _, entry in
            if entry.missCount > maxMisses { return false }
            if now.timeIntervalSince(entry.lastSeen) > maxStaleAge { return false }
            // For holdover entries (not freshly seen), check if the exit is behind us
            if entry.missCount > 0 {
                let coord = entry.card.exit.coordinate
                let bearing = GeoMath.bearing(from: userLocation.coordinate, to: coord)
                let angle = GeoMath.absoluteAngleDifference(bearing, userCourse)
                if angle > 90 { return false }
                let dist = userLocation.distance(from: CLLocation(latitude: coord.latitude, longitude: coord.longitude))
                if dist < 160 { return false }
            }
            return true
        }

        // Build final list: fresh cards first (already sorted by route distance),
        // then holdovers appended at the end sorted among themselves by straight-line.
        var result = newCards
        let resultIds = Set(result.map(\.id))
        var holdovers: [ExitCard] = []
        for (_, entry) in recent where !resultIds.contains(entry.card.id) {
            var held = entry.card
            let dist = userLocation.distance(from: CLLocation(latitude: held.exit.coordinate.latitude, longitude: held.exit.coordinate.longitude))
            held.exit.distanceFromUser = dist
            holdovers.append(held)
        }
        holdovers.sort { $0.exit.distanceFromUser < $1.exit.distanceFromUser }
        result.append(contentsOf: holdovers)

        return Array(result.prefix(limit))
    }

    /// Reset all tracked exits.
    mutating func reset() {
        recent = [:]
    }
}
