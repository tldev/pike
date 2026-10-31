import XCTest
import CoreLocation
@testable import Pike

final class GraphStrategyTests: XCTestCase {

    // MARK: - Helpers

    /// Create a simple edge polyline JSON from two points.
    private func polyline(_ coords: [(Double, Double)]) -> String {
        let arr = coords.map { "[\($0.0), \($0.1)]" }.joined(separator: ", ")
        return "[\(arr)]"
    }

    /// Create a highway edge for testing.
    private func makeEdge(
        highway: String = "I-85",
        corridorId: Int = 0,
        polylineCoords: [(Double, Double)]
    ) -> HighwayEdge {
        HighwayEdge(
            highway: highway,
            corridorId: corridorId,
            polylineJson: polyline(polylineCoords)
        )
    }

    private func makeCorridorRow(exitId: String, ref: String, lat: Double, lon: Double) -> CorridorExitRow {
        CorridorExitRow(exitId: exitId, ref: ref, name: nil, lat: lat, lon: lon)
    }

    // MARK: - Edge Projection Tests

    func testProjectionFindsClosestSegment() {
        // Edge runs south→north from (34.0, -80.0) to (35.0, -80.0).
        let edge = makeEdge(
            polylineCoords: [(34.0, -80.0), (34.5, -80.0), (35.0, -80.0)]
        )

        // User is slightly east of the midpoint.
        let user = CLLocationCoordinate2D(latitude: 34.5, longitude: -79.999)
        let proj = GraphStrategy.project(user: user, course: 0, edge: edge)

        XCTAssertNotNil(proj)
        // Should snap to the midpoint area, very close.
        XCTAssertLessThan(proj!.distanceToEdgeMeters, 200)
    }

    func testProjectionRejectsPerpendicularEdge() {
        // Edge runs clearly east-southeast (bearing well over 90° from north).
        let edge = makeEdge(
            polylineCoords: [(35.0, -81.0), (34.5, -79.0)]
        )

        // User heading north — this edge goes in a direction >90° from north.
        let user = CLLocationCoordinate2D(latitude: 34.75, longitude: -80.0)
        let proj = GraphStrategy.project(user: user, course: 0, edge: edge)

        // Edge bearing is well past 90° from user's course → rejected.
        XCTAssertNil(proj)
    }

    func testProjectionRejectsOppositeDirectionEdge() {
        // Edge polyline goes north→south (bearing ~180°), user heading north (0°).
        // With directed edges, this edge represents the wrong carriageway — should be rejected.
        let edge = makeEdge(
            polylineCoords: [(35.0, -80.0), (34.0, -80.0)]
        )

        let user = CLLocationCoordinate2D(latitude: 34.5, longitude: -80.0)
        let proj = GraphStrategy.project(user: user, course: 0, edge: edge)

        XCTAssertNil(proj, "Should reject edge in opposite direction")
    }

    func testPolylineParsingValid() {
        let json = "[[35.0, -80.0], [35.1, -80.1]]"
        let coords = GraphStrategy.parsePolyline(json)
        XCTAssertNotNil(coords)
        XCTAssertEqual(coords?.count, 2)
        XCTAssertEqual(coords?[0].latitude ?? 0, 35.0, accuracy: 0.001)
    }

    func testPolylineParsingMalformed() {
        let json = "not json"
        let coords = GraphStrategy.parsePolyline(json)
        XCTAssertNil(coords)
    }

    func testPolylineParsingSinglePoint() {
        let json = "[[35.0, -80.0]]"
        let coords = GraphStrategy.parsePolyline(json)
        XCTAssertNil(coords, "Single-point polyline should return nil (needs >= 2)")
    }

    func testPagedCursorSkipsExitsWithoutServices() throws {
        let db = MockExitDatabase()
        db.edges = [
            makeEdge(
                highway: "I-99",
                polylineCoords: [(40.0000, -75.0000), (40.0005, -74.9900)]
            )
        ]
        db.corridorRows = [
            makeCorridorRow(exitId: "node/cursor", ref: "10", lat: 40.0010, lon: -74.9800),
            makeCorridorRow(exitId: "node/no-service", ref: "11", lat: 40.0015, lon: -74.9700),
            makeCorridorRow(exitId: "node/downstream", ref: "12", lat: 40.0020, lon: -74.9400)
        ]
        db.poiRows = [
            "node/downstream": [RawPOIRow(
                poiId: "poi/downstream-gas",
                name: "Pilot",
                lat: 40.0021,
                lon: -74.9396,
                category: "gas",
                distanceMeters: 180
            )],
        ]

        let result = try GraphStrategy.findExits(
            database: db,
            userLocation: CLLocation(latitude: 40.0004, longitude: -74.9950),
            userCourse: 85.0,
            speedMps: 28.0,
            corridorLock: nil,
            lookahead: 1,
            limit: 10,
            afterExitId: "node/cursor",
            afterDistanceM: nil
        )

        XCTAssertEqual(result?.cards.map(\.id), ["exit-node/downstream"])
    }

    func testNoCardsWhenCorridorHasNoExits() throws {
        let db = MockExitDatabase()
        db.edges = [
            makeEdge(
                highway: "I-99",
                polylineCoords: [(40.0000, -75.0000), (40.0005, -74.9900)]
            )
        ]

        let result = try GraphStrategy.findExits(
            database: db,
            userLocation: CLLocation(latitude: 40.0002, longitude: -74.9950),
            userCourse: 85.0,
            speedMps: 27.0,
            corridorLock: nil,
            lookahead: 100_000,
            limit: 10
        )

        XCTAssertEqual(result?.cards.count, 0)
        XCTAssertEqual(result?.corridorSignal.highway, "I-99")
    }
}
