//
//  ExitDatabase.swift
//  Pike
//
//  Protocol abstracting all database queries needed by the exit feed.
//  Concrete implementation: SQLiteExitDatabase. Tests use MockExitDatabase.
//

import Foundation
import CoreLocation

// MARK: - Shared DB Types

struct HighwayEdge {
    let highway: String
    let corridorId: Int
    let polylineJson: String
}

struct CorridorExitRow {
    let exitId: String
    let ref: String?
    let name: String?
    let lat: Double
    let lon: Double
}

struct RawPOIRow {
    let poiId: String
    let name: String
    let lat: Double
    let lon: Double
    let category: String
    let distanceMeters: Int
    let estimatedDriveMeters: Int?
    let estimatedDriveSeconds: Int?

    init(
        poiId: String,
        name: String,
        lat: Double,
        lon: Double,
        category: String,
        distanceMeters: Int,
        estimatedDriveMeters: Int? = nil,
        estimatedDriveSeconds: Int? = nil
    ) {
        self.poiId = poiId
        self.name = name
        self.lat = lat
        self.lon = lon
        self.category = category
        self.distanceMeters = distanceMeters
        self.estimatedDriveMeters = estimatedDriveMeters
        self.estimatedDriveSeconds = estimatedDriveSeconds
    }
}

struct TestDriveRouteDirection {
    let routeId: String
    let directionLabel: String
}

struct TestDriveRouteChoice {
    let highway: String
    let directions: [TestDriveRouteDirection]
}

struct TestDriveRouteData {
    let intervalSeconds: Double
    let waypoints: [CLLocationCoordinate2D]
    let startIndex: Int?
}

// MARK: - Protocol

protocol ExitDatabase: Sendable {
    func edgesInBox(_ box: BoundingBox, limit: Int) throws -> [HighwayEdge]

    func poisForExit(rawExitId: String) throws -> [RawPOIRow]

    func corridorExits(corridorId: Int) throws -> [CorridorExitRow]
    func testDriveRouteChoices(near location: CLLocationCoordinate2D?, limit: Int) throws -> [TestDriveRouteChoice]
    func testDriveRouteById(_ id: String, near location: CLLocationCoordinate2D?) throws -> TestDriveRouteData?
}
