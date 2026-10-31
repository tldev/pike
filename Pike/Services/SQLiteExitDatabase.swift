//
//  SQLiteExitDatabase.swift
//  Pike
//
//  Concrete ExitDatabase backed by a SQLite data pack file.
//  Not @MainActor — all methods are synchronous, read-only queries.
//

import Foundation
import CoreLocation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLiteExitDatabase: ExitDatabase, @unchecked Sendable {

    private var db: OpaquePointer
    private let dbLock = NSLock()

    init(db: OpaquePointer) {
        self.db = db
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Open

    enum OpenError: LocalizedError {
        case sqliteOpenFailed(String)

        var errorDescription: String? {
            switch self {
            case .sqliteOpenFailed(let msg): return "Failed to open data pack: \(msg)"
            }
        }
    }

    static func open(at url: URL) throws -> SQLiteExitDatabase {
        var dbPtr: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &dbPtr, flags, nil)
        guard rc == SQLITE_OK, let opened = dbPtr else {
            let msg = dbPtr.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 failed"
            if dbPtr != nil { sqlite3_close(dbPtr) }
            throw OpenError.sqliteOpenFailed(msg)
        }
        return SQLiteExitDatabase(db: opened)
    }

    // MARK: - Schema Version

    func schemaVersionChecked() throws -> Int? {
        try withDBLock {
            let sql = "SELECT value FROM meta WHERE key = 'schema_version'"
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            guard let value = columnString(stmt, 0) else { return nil }
            return Int(value)
        }
    }

    func metaValue(forKey key: String) -> String? {
        withDBLock {
            let sql = "SELECT value FROM meta WHERE key = ?1"
            guard let stmt = try? prepareStatement(sql) else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return columnString(stmt, 0)
        }
    }

    // MARK: - ExitDatabase Protocol

    func edgesInBox(_ box: BoundingBox, limit: Int) throws -> [HighwayEdge] {
        try withDBLock {
            let sql = """
                SELECT h.highway, h.corridor_id, h.polyline_json
                FROM highway_edges h
                JOIN highway_edges_rtree r ON r.id = h.rowid
                WHERE r.min_lat <= ? AND r.max_lat >= ? AND r.min_lon <= ? AND r.max_lon >= ?
                LIMIT ?
            """

            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_double(stmt, 1, box.maxLat)
            sqlite3_bind_double(stmt, 2, box.minLat)
            sqlite3_bind_double(stmt, 3, box.maxLon)
            sqlite3_bind_double(stmt, 4, box.minLon)
            sqlite3_bind_int(stmt, 5, Int32(max(1, limit)))

            var rows: [HighwayEdge] = []
            rows.reserveCapacity(min(limit, 2048))

            while sqlite3_step(stmt) == SQLITE_ROW {
                if let edge = parseEdgeRow(stmt) {
                    rows.append(edge)
                }
            }
            return rows
        }
    }

    func corridorExits(corridorId: Int) throws -> [CorridorExitRow] {
        try withDBLock {
            let sql = """
                SELECT exit_id, ref, name, lat, lon
                FROM corridor_exits
                WHERE corridor_id = ?1
                ORDER BY corridor_index
            """

            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int(stmt, 1, Int32(corridorId))

            var rows: [CorridorExitRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let exitId = columnString(stmt, 0) else { continue }

                rows.append(CorridorExitRow(
                    exitId: exitId,
                    ref: columnString(stmt, 1),
                    name: columnString(stmt, 2),
                    lat: sqlite3_column_double(stmt, 3),
                    lon: sqlite3_column_double(stmt, 4)
                ))
            }

            return rows
        }
    }

    func testDriveRouteChoices(near location: CLLocationCoordinate2D?, limit: Int) throws -> [TestDriveRouteChoice] {
        try withDBLock {
            let safeLimit = max(1, limit)
            let highways: [String]

            if let location {
                let sql = """
                    SELECT tr.highway,
                           MIN(((ta.lat - ?1) * (ta.lat - ?1)) + ((ta.lon - ?2) * (ta.lon - ?2))) AS d2
                    FROM test_drive_route_anchors ta
                    JOIN test_drive_routes tr ON tr.id = ta.route_id
                    GROUP BY tr.highway
                    ORDER BY d2 ASC, tr.highway ASC
                    LIMIT ?3
                """
                let stmt = try prepareStatement(sql)
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_double(stmt, 1, location.latitude)
                sqlite3_bind_double(stmt, 2, location.longitude)
                sqlite3_bind_int(stmt, 3, Int32(safeLimit))

                var rows: [String] = []
                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard let highway = columnString(stmt, 0) else { continue }
                    rows.append(highway)
                }
                highways = rows
            } else {
                let sql = """
                    SELECT highway, MAX(distance_m) AS max_distance_m
                    FROM test_drive_routes
                    GROUP BY highway
                    ORDER BY max_distance_m DESC, highway ASC
                    LIMIT ?1
                """
                let stmt = try prepareStatement(sql)
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_int(stmt, 1, Int32(safeLimit))

                var rows: [String] = []
                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard let highway = columnString(stmt, 0) else { continue }
                    rows.append(highway)
                }
                highways = rows
            }

            var choices: [TestDriveRouteChoice] = []
            choices.reserveCapacity(highways.count)
            for highway in highways {
                let directions = try testDriveDirectionsForHighwayLocked(highway, near: location)
                guard !directions.isEmpty else { continue }
                choices.append(TestDriveRouteChoice(highway: highway, directions: directions))
            }
            return choices
        }
    }

    func testDriveRouteById(_ id: String, near location: CLLocationCoordinate2D?) throws -> TestDriveRouteData? {
        try withDBLock {
            let sql = """
                SELECT interval_s, waypoints_json
                FROM test_drive_routes
                WHERE id = ?1
                LIMIT 1
            """
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)

            guard sqlite3_step(stmt) == SQLITE_ROW,
                  let waypointsJSON = columnString(stmt, 1) else {
                return nil
            }

            let waypoints = parseRouteWaypointsJSON(waypointsJSON)
            guard !waypoints.isEmpty else { return nil }

            let startIndex: Int?
            if let location {
                startIndex = nearestWaypointIndex(
                    targetLat: location.latitude,
                    targetLon: location.longitude,
                    waypoints: waypoints
                )
            } else {
                startIndex = nil
            }

            return TestDriveRouteData(
                intervalSeconds: sqlite3_column_double(stmt, 0),
                waypoints: waypoints,
                startIndex: startIndex
            )
        }
    }

    func poisForExit(rawExitId: String) throws -> [RawPOIRow] {
        try withDBLock {
            let sql = """
                SELECT p.id, p.name, p.display_name, p.lat, p.lon, ep.category, ep.distance_m,
                       ep.estimated_drive_m, ep.estimated_drive_s
                FROM exit_pois ep
                JOIN pois p ON p.id = ep.poi_id
                WHERE ep.exit_id = ?
                ORDER BY ep.category,
                         CASE WHEN ep.estimated_drive_s IS NULL THEN 1 ELSE 0 END,
                         ep.estimated_drive_s,
                         ep.rank
            """

            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, rawExitId, -1, SQLITE_TRANSIENT)

            var rows: [RawPOIRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let rawPoiId = columnString(stmt, 0) else { continue }
                let poiName = columnString(stmt, 2) ?? columnString(stmt, 1) ?? "Unknown"
                let lat = sqlite3_column_double(stmt, 3)
                let lon = sqlite3_column_double(stmt, 4)
                let categoryStr = columnString(stmt, 5) ?? ""
                let distanceM = Int(sqlite3_column_int(stmt, 6))
                let estimatedDriveM = sqlite3_column_type(stmt, 7) != SQLITE_NULL
                    ? Int(sqlite3_column_int(stmt, 7))
                    : nil
                let estimatedDriveS = sqlite3_column_type(stmt, 8) != SQLITE_NULL
                    ? Int(sqlite3_column_int(stmt, 8))
                    : nil

                rows.append(RawPOIRow(
                    poiId: rawPoiId,
                    name: poiName,
                    lat: lat,
                    lon: lon,
                    category: categoryStr,
                    distanceMeters: distanceM,
                    estimatedDriveMeters: estimatedDriveM,
                    estimatedDriveSeconds: estimatedDriveS
                ))
            }

            return rows
        }
    }

    // MARK: - Private Helpers

    private enum QueryError: LocalizedError {
        case prepareFailed(sql: String, sqliteMessage: String)

        var errorDescription: String? {
            switch self {
            case let .prepareFailed(sql, sqliteMessage):
                return "SQLite query prepare failed: \(sqliteMessage) [sql=\(sql)]"
            }
        }
    }

    private func prepareStatement(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw QueryError.prepareFailed(sql: sql, sqliteMessage: sqliteErrorMessage())
        }
        return stmt
    }

    private func parseEdgeRow(_ stmt: OpaquePointer) -> HighwayEdge? {
        guard
            let highway = columnString(stmt, 0),
            let poly = columnString(stmt, 2)
        else { return nil }

        return HighwayEdge(
            highway: highway,
            corridorId: Int(sqlite3_column_int(stmt, 1)),
            polylineJson: poly
        )
    }

    private func columnString(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let cStr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cStr)
    }

    private func sqliteErrorMessage() -> String {
        String(cString: sqlite3_errmsg(db))
    }

    private func testDriveDirectionsForHighwayLocked(
        _ highway: String,
        near location: CLLocationCoordinate2D?
    ) throws -> [TestDriveRouteDirection] {
        let sql: String
        if location != nil {
            sql = """
                SELECT tr.id, tr.direction_code, tr.direction_label, tr.variant_rank
                FROM test_drive_routes tr
                LEFT JOIN test_drive_route_anchors ta ON ta.route_id = tr.id
                WHERE tr.highway = ?1
                GROUP BY tr.id, tr.direction_code, tr.direction_label, tr.variant_rank
                ORDER BY tr.direction_code ASC,
                         COALESCE(MIN(((ta.lat - ?2) * (ta.lat - ?2)) + ((ta.lon - ?3) * (ta.lon - ?3))), 1e18) ASC,
                         tr.variant_rank ASC,
                         tr.id ASC
            """
        } else {
            sql = """
                SELECT id, direction_code, direction_label, variant_rank
                FROM test_drive_routes
                WHERE highway = ?1
                ORDER BY direction_code ASC, variant_rank ASC, distance_m DESC
            """
        }
        let stmt = try prepareStatement(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, highway, -1, SQLITE_TRANSIENT)
        if let location {
            sqlite3_bind_double(stmt, 2, location.latitude)
            sqlite3_bind_double(stmt, 3, location.longitude)
        }

        var seen = Set<String>()
        var result: [TestDriveRouteDirection] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let routeId = columnString(stmt, 0),
                  let directionCode = columnString(stmt, 1),
                  let directionLabel = columnString(stmt, 2) else {
                continue
            }
            if seen.contains(directionCode) {
                continue
            }
            seen.insert(directionCode)
            result.append(TestDriveRouteDirection(
                routeId: routeId,
                directionLabel: directionLabel
            ))
        }

        return result
    }

    private func parseRouteWaypointsJSON(_ raw: String) -> [CLLocationCoordinate2D] {
        guard let data = raw.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[Any]] else {
            return []
        }

        var out: [CLLocationCoordinate2D] = []
        out.reserveCapacity(array.count)
        for pair in array {
            guard pair.count >= 2,
                  let latNum = pair[0] as? NSNumber,
                  let lonNum = pair[1] as? NSNumber else {
                continue
            }
            out.append(CLLocationCoordinate2D(latitude: latNum.doubleValue, longitude: lonNum.doubleValue))
        }
        return out
    }

    private func nearestWaypointIndex(
        targetLat: Double,
        targetLon: Double,
        waypoints: [CLLocationCoordinate2D]
    ) -> Int? {
        guard !waypoints.isEmpty else { return nil }
        var bestIndex: Int?
        var bestDistance = Double.greatestFiniteMagnitude
        for (idx, point) in waypoints.enumerated() {
            let dist = GeoMath.haversineDistance(
                from: CLLocationCoordinate2D(latitude: targetLat, longitude: targetLon),
                to: point
            )
            if dist < bestDistance {
                bestDistance = dist
                bestIndex = idx
            }
        }
        return bestIndex
    }

    private func withDBLock<T>(_ body: () throws -> T) rethrows -> T {
        dbLock.lock()
        defer { dbLock.unlock() }
        return try body()
    }
}
