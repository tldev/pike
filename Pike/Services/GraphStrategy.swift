//
//  GraphStrategy.swift
//  Pike
//
//  Highway-matched corridor strategy: projects user onto highway edge
//  polylines to identify corridor, then emits exits from corridor_exits
//  in topological order.
//

import Foundation
import CoreLocation

// MARK: - Types

struct EdgeProjection {
    let edge: HighwayEdge
    let distanceToEdgeMeters: Double
    let segmentBearing: Double
}

struct GraphResult {
    let cards: [ExitCard]
    let corridorSignal: CorridorKey
}

// MARK: - Strategy

enum GraphStrategy {
    private static let unboundedPagingRadiusMeters: CLLocationDistance = 25_000_000
    private static let corridorAheadAngleDegrees: CLLocationDirection = 95

    /// Find exits ahead using corridor exits after graph-based edge match.
    /// Returns nil if no match is found.
    static func findExits(
        database: any ExitDatabase,
        userLocation: CLLocation,
        userCourse: CLLocationDirection,
        speedMps: CLLocationSpeed,
        corridorLock: CorridorLockState?,
        lookahead: CLLocationDistance,
        limit: Int,
        afterExitId: String? = nil,
        afterDistanceM: Int? = nil
    ) throws -> GraphResult? {
        let hasProgressCursor = afterExitId != nil || (afterDistanceM ?? -1) >= 0
        let effectiveLookahead = hasProgressCursor ? unboundedPagingRadiusMeters : lookahead

        let userCoord = userLocation.coordinate
        let courseForMatch: CLLocationDirection = (speedMps >= 2 ? userCourse : -1)

        // 1) Match the user's location to the best nearby highway edge.
        let matchRadius: Double = 5_000
        let matchBox = BoundingBox.around(
            lat: userCoord.latitude,
            lon: userCoord.longitude,
            radiusMeters: matchRadius
        )

        let nearbyEdges = try database.edgesInBox(matchBox, limit: 4000)
        guard !nearbyEdges.isEmpty else { return nil }

        let projections = nearbyEdges.compactMap { edge in
            project(user: userCoord, course: courseForMatch, edge: edge)
        }

        func projectionScore(_ p: EdgeProjection) -> Double {
            var score = p.distanceToEdgeMeters
            if courseForMatch >= 0 && courseForMatch <= 360 {
                let angle = GeoMath.absoluteAngleDifference(p.segmentBearing, courseForMatch)
                let t = max(0.0, angle - 25.0) / 25.0
                score += (t * t) * 120.0
            }
            if let lock = corridorLock, lock.key.corridorId == p.edge.corridorId {
                score -= lock.lockBonus
            }
            return score
        }

        guard let best = projections.min(by: { projectionScore($0) < projectionScore($1) }) else { return nil }

        if best.distanceToEdgeMeters > 200 {
            return nil
        }

        let signalKey = CorridorKey(corridorId: best.edge.corridorId, highway: best.edge.highway)

        // 2) Fetch corridor exits in topological order
        let corridorExitRows = try database.corridorExits(corridorId: best.edge.corridorId)
        // 3) Compute distances and find pagination start
        let candidates: [(row: CorridorExitRow, distance: Double)] = corridorExitRows.map { row in
            let dist = GeoMath.haversineDistance(
                from: userCoord,
                to: CLLocationCoordinate2D(latitude: row.lat, longitude: row.lon)
            )
            return (row, dist)
        }

        let startIndex = corridorPaginationStartIndex(
            candidates: candidates,
            afterExitId: afterExitId,
            afterDistanceM: afterDistanceM,
            userCoord: userCoord,
            userCourse: userCourse
        )
        let remaining = candidates.dropFirst(startIndex)
        let withinWindow = remaining.filter { $0.distance <= effectiveLookahead + 0.5 }

        // 4) Build exit cards
        var cards: [ExitCard] = []
        cards.reserveCapacity(limit)
        var seenRefKeys = Set<String>()

        for (row, distance) in withinWindow {
            if cards.count >= max(0, limit) { break }

            if let key = normalizedRefKey(row.ref) {
                if !seenRefKeys.insert(key).inserted {
                    continue
                }
            }

            let sanitizedName = sanitizeExitName(row.name, ref: row.ref)

            guard let card = try POIPopulator.buildExitCard(
                exitIdRaw: row.exitId,
                ref: row.ref,
                name: sanitizedName,
                coordinate: CLLocationCoordinate2D(latitude: row.lat, longitude: row.lon),
                distance: distance,
                speedMps: speedMps,
                database: database
            ) else {
                continue
            }

            cards.append(card)
        }

        return GraphResult(cards: cards, corridorSignal: signalKey)
    }

    private static func corridorPaginationStartIndex(
        candidates: [(row: CorridorExitRow, distance: Double)],
        afterExitId: String?,
        afterDistanceM: Int?,
        userCoord: CLLocationCoordinate2D,
        userCourse: CLLocationDirection
    ) -> Int {
        if let afterExitId,
           let idx = candidates.firstIndex(where: { $0.row.exitId == afterExitId }) {
            return idx + 1
        }

        if let afterDistanceM, afterDistanceM >= 0 {
            let threshold = Double(afterDistanceM) + 0.5
            if let idx = candidates.firstIndex(where: { $0.distance > threshold }) {
                return idx
            }
            return candidates.count
        }

        if userCourse >= 0 && userCourse <= 360 {
            let ahead = candidates.enumerated().filter { _, item in
                let bearing = GeoMath.bearing(
                    from: userCoord,
                    to: CLLocationCoordinate2D(latitude: item.row.lat, longitude: item.row.lon)
                )
                let angle = GeoMath.absoluteAngleDifference(bearing, userCourse)
                return angle <= corridorAheadAngleDegrees
            }
            if let nearestAhead = ahead.min(by: { $0.element.distance < $1.element.distance }) {
                return nearestAhead.offset
            }
        }

        if let nearest = candidates.enumerated().min(by: { $0.element.distance < $1.element.distance }) {
            return nearest.offset
        }

        return 0
    }

    private static func normalizedRefKey(_ ref: String?) -> String? {
        guard let ref else { return nil }
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Only dedup on refs that look like exit numbers (contain at least one digit).
        // Name-like refs such as "Rest Area" should not trigger dedup.
        guard trimmed.contains(where: \.isNumber) else { return nil }
        return trimmed.uppercased()
    }

    private static func normalizeLabelValue(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func isOSMIdentifierLabel(_ value: String) -> Bool {
        let lowered = value.lowercased()
        for prefix in ["node/", "way/", "relation/"] {
            if lowered.hasPrefix(prefix) {
                let suffix = lowered.dropFirst(prefix.count)
                if !suffix.isEmpty && suffix.allSatisfy({ $0.isNumber }) {
                    return true
                }
            }
        }
        return false
    }

    private static func sanitizeExitName(_ name: String?, ref: String?) -> String? {
        guard let name else { return nil }
        let cleaned = normalizeLabelValue(name.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !cleaned.isEmpty else { return nil }
        guard !isOSMIdentifierLabel(cleaned) else { return nil }

        if let refKey = normalizedRefKey(ref) {
            let lower = cleaned.lowercased()
            let refLower = refKey.lowercased()
            if lower == refLower || lower == "exit \(refLower)" {
                return nil
            }
        }
        return cleaned
    }

    // MARK: - Edge Projection

    static func project(
        user: CLLocationCoordinate2D,
        course: CLLocationDirection,
        edge: HighwayEdge
    ) -> EdgeProjection? {
        guard let poly = parsePolyline(edge.polylineJson) else { return nil }

        var bestDist = Double.greatestFiniteMagnitude
        var bestBearing = 0.0

        for i in 0..<(poly.count - 1) {
            let a = poly[i]
            let b = poly[i + 1]
            if GeoMath.haversineDistance(from: a, to: b) <= 0.1 { continue }

            let midLat = ((a.latitude + b.latitude) / 2).degreesToRadians
            let cosLat = cos(midLat)
            let ax = a.longitude * cosLat
            let ay = a.latitude
            let bx = b.longitude * cosLat
            let by = b.latitude
            let px = user.longitude * cosLat
            let py = user.latitude

            let abx = bx - ax
            let aby = by - ay
            let apx = px - ax
            let apy = py - ay
            let ab2 = abx * abx + aby * aby
            if ab2 <= 0 { continue }

            var t = (apx * abx + apy * aby) / ab2
            t = max(0, min(1, t))

            let projLon = (ax + t * abx) / cosLat
            let projLat = ay + t * aby
            let proj = CLLocationCoordinate2D(latitude: projLat, longitude: projLon)

            let dist = GeoMath.haversineDistance(from: user, to: proj)
            if dist < bestDist {
                bestDist = dist
                bestBearing = GeoMath.bearing(from: a, to: b)
            }
        }

        // With directed edges, the polyline bearing IS the travel direction.
        // If the user's course differs by >=90°, this edge goes the wrong way — skip it.
        if course >= 0 && course <= 360 {
            let angle = GeoMath.absoluteAngleDifference(bestBearing, course)
            if angle >= 90 { return nil }
        }

        return EdgeProjection(
            edge: edge,
            distanceToEdgeMeters: bestDist,
            segmentBearing: bestBearing
        )
    }

    // MARK: - Polyline Parsing

    static func parsePolyline(_ json: String) -> [CLLocationCoordinate2D]? {
        guard let data = json.data(using: .utf8) else { return nil }
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        var coords: [CLLocationCoordinate2D] = []
        coords.reserveCapacity(raw.count)
        for item in raw {
            guard let pair = item as? [Any], pair.count >= 2 else { continue }
            guard
                let latNum = pair[0] as? NSNumber,
                let lonNum = pair[1] as? NSNumber
            else { continue }
            coords.append(CLLocationCoordinate2D(latitude: latNum.doubleValue, longitude: lonNum.doubleValue))
        }
        return coords.count >= 2 ? coords : nil
    }
}
