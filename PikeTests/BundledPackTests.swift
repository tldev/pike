import XCTest
import CoreLocation
@testable import Pike

final class BundledPackTests: XCTestCase {

    func testBundledPackOpensWithLabel() throws {
        let db = try BundledPack.open()
        XCTAssertNotNil(BundledPack.generatedAtLabel(for: db))
    }

    func testFeedFromBundledPack() throws {
        let db = try BundledPack.open()
        // I-85 South in northeast Georgia.
        let location = CLLocation(latitude: 34.496, longitude: -83.005)
        let result = try GraphStrategy.findExits(
            database: db,
            userLocation: location,
            userCourse: 200,
            speedMps: 30,
            corridorLock: nil,
            lookahead: 50_000,
            limit: 10
        )
        XCTAssertFalse(try XCTUnwrap(result).cards.isEmpty)
    }

    func testTestDriveRoutesFromBundledPack() throws {
        let db = try BundledPack.open()
        let location = CLLocationCoordinate2D(latitude: 34.496, longitude: -83.005)
        XCTAssertFalse(try db.testDriveRouteChoices(near: location, limit: 5).isEmpty)
    }
}
