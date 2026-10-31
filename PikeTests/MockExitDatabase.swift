import Foundation
import CoreLocation
@testable import Pike

/// In-memory mock for testing strategies without SQLite.
final class MockExitDatabase: ExitDatabase, @unchecked Sendable {

    var edges: [HighwayEdge] = []
    var poiRows: [String: [RawPOIRow]] = [:]
    var corridorRows: [CorridorExitRow] = []

    func edgesInBox(_ box: BoundingBox, limit: Int) throws -> [HighwayEdge] {
        Array(edges.prefix(limit))
    }

    func poisForExit(rawExitId: String) throws -> [RawPOIRow] {
        poiRows[rawExitId] ?? []
    }

    func corridorExits(corridorId: Int) throws -> [CorridorExitRow] {
        corridorRows
    }

    func testDriveRouteChoices(near location: CLLocationCoordinate2D?, limit: Int) throws -> [TestDriveRouteChoice] {
        []
    }

    func testDriveRouteById(_ id: String, near location: CLLocationCoordinate2D?) throws -> TestDriveRouteData? {
        nil
    }
}
