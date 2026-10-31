//
//  POIPopulator.swift
//  Pike
//
//  Populates an ExitCard with POIs from the database.
//

import Foundation
import CoreLocation

enum POIPopulator {

    /// Max drive time thresholds in seconds, derived from ceil(p95) of reachability
    /// drive time distributions. POIs exceeding their category's threshold are excluded.
    /// Parks use a higher threshold because they have a larger search radius (1600m vs 800m).
    private static let maxDriveTimeDefaultSeconds = 360  // 6 min — gas, food, lodging, restArea, restroom, evCharging
    private static let maxDriveTimeParkSeconds = 480     // 8 min — park, dogPark

    private static func maxDriveTime(for category: POICategory) -> Int {
        switch category {
        case .park, .dogPark: return maxDriveTimeParkSeconds
        default: return maxDriveTimeDefaultSeconds
        }
    }

    /// Build an ExitCard from exit info, populating POIs from the database.
    /// Returns nil if the exit has no services or is a filtered noref exit.
    static func buildExitCard(
        exitIdRaw: String,
        ref: String?,
        name: String?,
        coordinate: CLLocationCoordinate2D,
        distance: Double,
        speedMps: Double,
        database: any ExitDatabase
    ) throws -> ExitCard? {
        let exit = Exit(
            id: "exit-\(exitIdRaw)",
            exitNumber: ref ?? "",
            name: name,
            coordinate: coordinate,
            distanceFromUser: distance,
            estimatedTimeToExit: (speedMps > 1 ? distance / speedMps : 0)
        )

        var card = ExitCard(exit: exit)
        try populateServices(for: exitIdRaw, into: &card, database: database)

        guard card.hasServices else { return nil }

        // Classify noref exits — may filter them out entirely
        if ref == nil {
            guard let kind = classifyNorefExit(name: name, card: card) else {
                return nil
            }
            card.exit.kind = kind
            // Absorb name into shortTitle for welcome center kinds
            // Rest areas keep the name so the dedicated card can display it
            if kind == .welcomeCenter {
                card.exit.name = nil
            }
        }

        return card
    }

    // MARK: - Noref Classification

    /// Classify an exit with no ref number. Returns nil to filter the exit out entirely.
    static func classifyNorefExit(name: String?, card: ExitCard) -> ExitKind? {
        let lower = name?.lowercased() ?? ""

        // Hide: weigh stations / scales
        if lower.contains("weigh") || lower.contains("scale") {
            return nil
        }
        // Hide: airport ramps
        if lower.contains("airport") || lower.contains("departures") || lower.contains("rental car") {
            return nil
        }
        // Hide: HOV / express lane ramps
        if lower.contains("express lane") || lower.contains("hov") {
            return nil
        }
        // Hide: all POIs are generic/unknown brands (but keep named rest areas)
        if card.allPOIs.allSatisfy({ BrandHelpers.genericPOINames.contains($0.name) }) {
            let hasRestAreaName = lower.contains("rest area") || lower.contains("rest stop")
                || lower.contains("service plaza") || lower.contains("parking area")
                || lower.contains("scenic")
            if !hasRestAreaName {
                return nil
            }
        }

        // Welcome center / visitor info
        if lower.contains("welcome center") || lower.contains("visitor information") || lower.contains("visitor center") {
            return .welcomeCenter
        }

        // Rest area / service plaza
        if lower.contains("rest area") || lower.contains("rest stop") || lower.contains("service plaza")
            || lower.contains("parking area") || lower.contains("scenic") {
            return .restArea
        }

        // Nameless exit with only rest area / restroom POIs → treat as rest area
        if lower.isEmpty && card.isRestAreaOnly {
            return .restArea
        }

        // Everything else: real exit, just unnumbered
        return .unnumbered
    }

    private static func populateServices(
        for rawExitId: String,
        into card: inout ExitCard,
        database: any ExitDatabase
    ) throws {
        let rows = try database.poisForExit(rawExitId: rawExitId)

        for row in rows {
            guard let mappedCategory = POICategory(dbString: row.category) else { continue }

            // Filter POIs that exceed their category's drive time threshold.
            if let driveSeconds = row.estimatedDriveSeconds,
               driveSeconds > maxDriveTime(for: mappedCategory) {
                continue
            }

            let poi = POI(
                id: row.poiId,
                name: row.name,
                coordinate: CLLocationCoordinate2D(latitude: row.lat, longitude: row.lon),
                category: mappedCategory,
                distanceFromExit: CLLocationDistance(row.distanceMeters),
                estimatedDriveDistanceFromExit: row.estimatedDriveMeters.map { CLLocationDistance($0) },
                estimatedDriveTimeFromExit: row.estimatedDriveSeconds.map { TimeInterval($0) }
            )

            switch mappedCategory {
            case .gas:
                card.gasPOIs.append(poi)
            case .food:
                card.foodPOIs.append(poi)
            case .lodging:
                card.lodgingPOIs.append(poi)
            case .restStop:
                card.restAreaPOIs.append(poi)
            case .restroom:
                card.restroomPOIs.append(poi)
            case .evCharging:
                card.evChargingPOIs.append(poi)
            case .park:
                card.parkPOIs.append(poi)
            case .dogPark:
                card.dogParkPOIs.append(poi)
            }
        }
    }
}
