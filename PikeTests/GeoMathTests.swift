import XCTest
import CoreLocation
@testable import Pike

final class GeoMathTests: XCTestCase {

    // MARK: - Bearing Tests

    func testBearingNorth() {
        // Point directly north
        let from = CLLocationCoordinate2D(latitude: 40.0, longitude: -74.0)
        let to = CLLocationCoordinate2D(latitude: 41.0, longitude: -74.0)
        let bearing = GeoMath.bearing(from: from, to: to)
        XCTAssertEqual(bearing, 0, accuracy: 1.0, "Bearing should be ~0° (north)")
    }

    func testBearingEast() {
        let from = CLLocationCoordinate2D(latitude: 40.0, longitude: -74.0)
        let to = CLLocationCoordinate2D(latitude: 40.0, longitude: -73.0)
        let bearing = GeoMath.bearing(from: from, to: to)
        XCTAssertEqual(bearing, 90, accuracy: 2.0, "Bearing should be ~90° (east)")
    }

    func testBearingSouth() {
        let from = CLLocationCoordinate2D(latitude: 41.0, longitude: -74.0)
        let to = CLLocationCoordinate2D(latitude: 40.0, longitude: -74.0)
        let bearing = GeoMath.bearing(from: from, to: to)
        XCTAssertEqual(bearing, 180, accuracy: 1.0, "Bearing should be ~180° (south)")
    }

    func testBearingWest() {
        let from = CLLocationCoordinate2D(latitude: 40.0, longitude: -73.0)
        let to = CLLocationCoordinate2D(latitude: 40.0, longitude: -74.0)
        let bearing = GeoMath.bearing(from: from, to: to)
        XCTAssertEqual(bearing, 270, accuracy: 2.0, "Bearing should be ~270° (west)")
    }

    // MARK: - Angle Difference Tests

    func testAngleDifferenceNormal() {
        XCTAssertEqual(GeoMath.angleDifference(90, 45), 45, accuracy: 0.001)
        XCTAssertEqual(GeoMath.angleDifference(45, 90), -45, accuracy: 0.001)
    }

    func testAngleDifferenceWrapAround() {
        // 350° to 10° should be -20° (10 is 20° clockwise from 350)
        XCTAssertEqual(GeoMath.angleDifference(350, 10), -20, accuracy: 0.001)
        // 10° to 350° should be 20°
        XCTAssertEqual(GeoMath.angleDifference(10, 350), 20, accuracy: 0.001)
    }

    func testAbsoluteAngleDifference() {
        XCTAssertEqual(GeoMath.absoluteAngleDifference(10, 350), 20, accuracy: 0.001)
        XCTAssertEqual(GeoMath.absoluteAngleDifference(350, 10), 20, accuracy: 0.001)
        XCTAssertEqual(GeoMath.absoluteAngleDifference(90, 270), 180, accuracy: 0.001)
    }

    // MARK: - Distance Tests

    func testHaversineDistance() {
        // NYC to Philadelphia: ~130km
        let nyc = CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)
        let philly = CLLocationCoordinate2D(latitude: 39.9526, longitude: -75.1652)
        let distance = GeoMath.haversineDistance(from: nyc, to: philly)
        XCTAssertEqual(distance, 130_000, accuracy: 5000, "NYC-Philly should be ~130km")
    }

    // MARK: - Point Projection Tests

    func testProjectNorth() {
        let origin = CLLocationCoordinate2D(latitude: 40.0, longitude: -74.0)
        let projected = GeoMath.project(from: origin, bearing: 0, distanceMeters: 1000)

        XCTAssertGreaterThan(projected.latitude, origin.latitude, "Projecting north should increase latitude")
        XCTAssertEqual(projected.longitude, origin.longitude, accuracy: 0.001, "Projecting north shouldn't change longitude much")
    }

    func testProjectEast() {
        let origin = CLLocationCoordinate2D(latitude: 40.0, longitude: -74.0)
        let projected = GeoMath.project(from: origin, bearing: 90, distanceMeters: 1000)

        XCTAssertEqual(projected.latitude, origin.latitude, accuracy: 0.001, "Projecting east shouldn't change latitude much")
        XCTAssertGreaterThan(projected.longitude, origin.longitude, "Projecting east should increase longitude")
    }

    // MARK: - Course Camera Planning

    func testCourseCameraPlannerUsesFocusedExitDistanceWhenAvailable() {
        let plan = CourseCameraPlanner.plan(
            userCoordinate: CLLocationCoordinate2D(latitude: 35.0, longitude: -80.0),
            userCourse: 90,
            focusedExitDistance: 10_000
        )

        XCTAssertEqual(plan.distanceMeters, 26_000, accuracy: 0.001)
        XCTAssertEqual(plan.heading, 90, accuracy: 0.001)
    }

    func testCourseCameraPlannerFallsBackToDefaultLookAhead() {
        let plan = CourseCameraPlanner.plan(
            userCoordinate: CLLocationCoordinate2D(latitude: 35.0, longitude: -80.0),
            userCourse: 0,
            focusedExitDistance: nil
        )

        XCTAssertEqual(plan.distanceMeters, 32_000, accuracy: 0.001)
    }
}
