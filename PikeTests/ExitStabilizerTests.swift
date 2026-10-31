import XCTest
import CoreLocation
@testable import Pike

final class ExitStabilizerTests: XCTestCase {

    private func makeCard(id: String, lat: Double = 35.0, lon: Double = -80.0, distance: Double = 5000) -> ExitCard {
        let exit = Exit(
            id: id,
            exitNumber: id,
            name: "Test Exit \(id)",
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            distanceFromUser: distance,
            estimatedTimeToExit: 60
        )
        var card = ExitCard(exit: exit)
        card.gasPOIs = [POI(
            id: "poi-\(id)",
            name: "Shell",
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            category: .gas
        )]
        return card
    }

    private let userLocation = CLLocation(latitude: 34.9, longitude: -80.0)
    private let userCourse: CLLocationDirection = 0 // heading north

    func testNewCardsPassThroughUnchanged() {
        var stabilizer = ExitStabilizer()
        let cards = [makeCard(id: "1"), makeCard(id: "2")]
        let result = stabilizer.stabilize(cards, userLocation: userLocation, userCourse: userCourse, limit: 10)
        XCTAssertEqual(result.map(\.id), ["1", "2"])
    }

    func testHoldoverRetainedForOneMiss() {
        var stabilizer = ExitStabilizer()
        let initial = [makeCard(id: "1"), makeCard(id: "2")]
        _ = stabilizer.stabilize(initial, userLocation: userLocation, userCourse: userCourse, limit: 10)

        // Second refresh only has card "1" — card "2" should be held over.
        let result = stabilizer.stabilize([makeCard(id: "1")], userLocation: userLocation, userCourse: userCourse, limit: 10)
        let ids = result.map(\.id)
        XCTAssertTrue(ids.contains("1"))
        XCTAssertTrue(ids.contains("2"))
    }

    func testHoldoverRetainedForTwoMisses() {
        var stabilizer = ExitStabilizer()
        _ = stabilizer.stabilize([makeCard(id: "1"), makeCard(id: "2")], userLocation: userLocation, userCourse: userCourse, limit: 10)
        _ = stabilizer.stabilize([makeCard(id: "1")], userLocation: userLocation, userCourse: userCourse, limit: 10)
        let result = stabilizer.stabilize([makeCard(id: "1")], userLocation: userLocation, userCourse: userCourse, limit: 10)
        XCTAssertTrue(result.map(\.id).contains("2"))
    }

    func testHoldoverEvictedAfterFourMisses() {
        var stabilizer = ExitStabilizer()
        _ = stabilizer.stabilize([makeCard(id: "1"), makeCard(id: "2")], userLocation: userLocation, userCourse: userCourse, limit: 10)
        for _ in 0..<4 {
            _ = stabilizer.stabilize([makeCard(id: "1")], userLocation: userLocation, userCourse: userCourse, limit: 10)
        }
        let result = stabilizer.stabilize([makeCard(id: "1")], userLocation: userLocation, userCourse: userCourse, limit: 10)
        XCTAssertFalse(result.map(\.id).contains("2"))
    }

    func testHoldoverEvictedWhenBehindUser() {
        var stabilizer = ExitStabilizer()
        // Card "2" is south of user who is heading north → it's behind us.
        let behindCard = makeCard(id: "2", lat: 34.8, lon: -80.0)
        _ = stabilizer.stabilize([makeCard(id: "1"), behindCard], userLocation: userLocation, userCourse: userCourse, limit: 10)

        let result = stabilizer.stabilize([makeCard(id: "1")], userLocation: userLocation, userCourse: userCourse, limit: 10)
        XCTAssertFalse(result.map(\.id).contains("2"))
    }

    func testHoldoverEvictedWhenVeryClose() {
        var stabilizer = ExitStabilizer()
        // Card "2" is extremely close to user (< 160m).
        let closeCard = makeCard(id: "2", lat: 34.9005, lon: -80.0, distance: 50)
        _ = stabilizer.stabilize([makeCard(id: "1"), closeCard], userLocation: userLocation, userCourse: userCourse, limit: 10)

        let result = stabilizer.stabilize([makeCard(id: "1")], userLocation: userLocation, userCourse: userCourse, limit: 10)
        XCTAssertFalse(result.map(\.id).contains("2"))
    }

    func testHoldoversAppendedAfterFreshCards() {
        var stabilizer = ExitStabilizer()
        _ = stabilizer.stabilize([makeCard(id: "1"), makeCard(id: "2"), makeCard(id: "3")], userLocation: userLocation, userCourse: userCourse, limit: 10)

        // "2" and "3" become holdovers.
        let result = stabilizer.stabilize([makeCard(id: "1")], userLocation: userLocation, userCourse: userCourse, limit: 10)
        XCTAssertEqual(result.first?.id, "1", "Fresh card should be first")
    }

    func testMultipleHoldoversSortedByDistance() {
        var stabilizer = ExitStabilizer()
        let farCard = makeCard(id: "far", lat: 35.1, lon: -80.0, distance: 20000)
        let nearCard = makeCard(id: "near", lat: 35.0, lon: -80.0, distance: 10000)
        _ = stabilizer.stabilize([makeCard(id: "1"), farCard, nearCard], userLocation: userLocation, userCourse: userCourse, limit: 10)

        let result = stabilizer.stabilize([makeCard(id: "1")], userLocation: userLocation, userCourse: userCourse, limit: 10)
        let holdoverIds = result.dropFirst().map(\.id)
        // Both holdovers should be present, near before far.
        XCTAssertTrue(holdoverIds.contains("near"))
        XCTAssertTrue(holdoverIds.contains("far"))
        if let nearIdx = holdoverIds.firstIndex(of: "near"),
           let farIdx = holdoverIds.firstIndex(of: "far") {
            XCTAssertLessThan(nearIdx, farIdx)
        }
    }

    func testOutputTrimmedToLimit() {
        var stabilizer = ExitStabilizer()
        let many = (1...15).map { makeCard(id: "\($0)") }
        let result = stabilizer.stabilize(many, userLocation: userLocation, userCourse: userCourse, limit: 5)
        XCTAssertEqual(result.count, 5)
    }
}
