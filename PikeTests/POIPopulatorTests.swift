import XCTest
import CoreLocation
@testable import Pike

final class POIPopulatorTests: XCTestCase {

    private func makeDB(pois: [String: [RawPOIRow]]) -> MockExitDatabase {
        let db = MockExitDatabase()
        db.poiRows = pois
        return db
    }

    func testExitWithPOIsReturnsPopulatedCard() throws {
        let db = makeDB(pois: [
            "exit-1": [
                RawPOIRow(poiId: "p1", name: "Shell", lat: 35.0, lon: -80.0, category: "gas", distanceMeters: 100),
                RawPOIRow(poiId: "p2", name: "McDonald's", lat: 35.0, lon: -80.001, category: "food", distanceMeters: 200),
            ]
        ])

        let card = try POIPopulator.buildExitCard(
            exitIdRaw: "exit-1",
            ref: "42",
            name: "Test Exit",
            coordinate: CLLocationCoordinate2D(latitude: 35.0, longitude: -80.0),
            distance: 5000,
            speedMps: 30,
            database: db
        )

        XCTAssertNotNil(card)
        XCTAssertEqual(card?.gasPOIs.count, 1)
        XCTAssertEqual(card?.foodPOIs.count, 1)
        XCTAssertEqual(card?.gasPOIs.first?.name, "Shell")
    }

    func testExitWithNoPOIsReturnsNil() throws {
        let db = makeDB(pois: [:])

        let card = try POIPopulator.buildExitCard(
            exitIdRaw: "exit-empty",
            ref: "100",
            name: "Empty Exit",
            coordinate: CLLocationCoordinate2D(latitude: 35.0, longitude: -80.0),
            distance: 5000,
            speedMps: 30,
            database: db
        )

        XCTAssertNil(card, "Exit with no POIs should return nil")
    }

    func testCategoryStringMapping() throws {
        let db = makeDB(pois: [
            "exit-1": [
                RawPOIRow(poiId: "p1", name: "Pilot", lat: 35.0, lon: -80.0, category: "gas", distanceMeters: 100),
                RawPOIRow(poiId: "p2", name: "Subway", lat: 35.0, lon: -80.0, category: "food", distanceMeters: 100),
                RawPOIRow(poiId: "p3", name: "Hampton Inn", lat: 35.0, lon: -80.0, category: "lodging", distanceMeters: 100),
                RawPOIRow(poiId: "p4", name: "Rest Area", lat: 35.0, lon: -80.0, category: "restArea", distanceMeters: 100),
                RawPOIRow(poiId: "p5", name: "ChargePoint", lat: 35.0, lon: -80.0, category: "evCharging", distanceMeters: 100),
                RawPOIRow(poiId: "p6", name: "Restroom", lat: 35.0, lon: -80.0, category: "restroom", distanceMeters: 100),
            ]
        ])

        let card = try POIPopulator.buildExitCard(
            exitIdRaw: "exit-1",
            ref: "1",
            name: nil,
            coordinate: CLLocationCoordinate2D(latitude: 35.0, longitude: -80.0),
            distance: 1000,
            speedMps: 30,
            database: db
        )

        XCTAssertNotNil(card)
        XCTAssertEqual(card?.gasPOIs.count, 1)
        XCTAssertEqual(card?.foodPOIs.count, 1)
        XCTAssertEqual(card?.lodgingPOIs.count, 1)
        XCTAssertEqual(card?.restAreaPOIs.count, 1)
        XCTAssertEqual(card?.evChargingPOIs.count, 1)
        XCTAssertEqual(card?.restroomPOIs.count, 1)
    }
}

final class POISorterAndFilterStoreTests: XCTestCase {
    func testPOISorterPrefersKnownDriveTimeAndKeepsStableOrder() {
        let baseCoordinate = CLLocationCoordinate2D(latitude: 35.0, longitude: -80.0)
        let poiA = POI(
            id: "a",
            name: "A",
            coordinate: baseCoordinate,
            category: .food,
            distanceFromExit: 100,
            estimatedDriveDistanceFromExit: nil,
            estimatedDriveTimeFromExit: nil
        )
        let poiB = POI(
            id: "b",
            name: "B",
            coordinate: baseCoordinate,
            category: .food,
            distanceFromExit: 100,
            estimatedDriveDistanceFromExit: 300,
            estimatedDriveTimeFromExit: 60
        )
        let poiC = POI(
            id: "c",
            name: "C",
            coordinate: baseCoordinate,
            category: .food,
            distanceFromExit: 100,
            estimatedDriveDistanceFromExit: 500,
            estimatedDriveTimeFromExit: 120
        )

        let sorted = POISorter.byEstimatedDriveTime([poiA, poiC, poiB])
        XCTAssertEqual(sorted.map(\.id), ["b", "c", "a"])
    }

    func testPOIListFilterStoreRoundTripsSavedState() {
        let suiteName = "POIListFilterStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = POIListFilterStore(defaults: defaults, storageKey: "filter")
        let loadedDefault = store.load()
        XCTAssertEqual(loadedDefault, POIListFilter())

        var saved = POIListFilter()
        saved.enabledCategories = [.gas, .food]
        store.save(saved)

        XCTAssertEqual(store.load(), saved)
    }
}

final class BrandHelpersTests: XCTestCase {
    func testBrandKeyFoldsAccents() {
        XCTAssertEqual(BrandHelpers.brandKey(from: "Café Zupas"), "cafe_zupas")
        XCTAssertEqual(BrandHelpers.brandKey(from: "Nékter Juice Bar"), "nekter_juice_bar")
        XCTAssertEqual(BrandHelpers.brandKey(from: "Fogo de Chão"), "fogo_de_chao")
        XCTAssertEqual(BrandHelpers.brandKey(from: "Zoës Kitchen"), "zoes_kitchen")
    }

    func testBrandKeyAppliesAliases() {
        XCTAssertEqual(BrandHelpers.brandKey(from: "Love's Travel Stop"), "loves")
    }
}

final class ExitCardCategoryVisibilityTests: XCTestCase {
    func testVisibilityUsesDefaultsWhenMaskIsZero() {
        let visibility = ExitCardCategoryVisibility(mask: 0)
        XCTAssertEqual(visibility.mask, ExitCardCategoryVisibility.defaultMask)
        XCTAssertFalse(visibility.isEnabled(.parks))
        XCTAssertFalse(visibility.isEnabled(.dogParks))
    }

    func testVisibilityPreventsDisablingLastEnabledCategory() {
        var visibility = ExitCardCategoryVisibility(mask: ExitCardCategoryVisibility.fullMask)
        let allCategories = ExitCardServiceCategory.allCases

        for category in allCategories.dropLast() {
            visibility.set(category, enabled: false)
        }

        guard let lastCategory = allCategories.last else {
            XCTFail("Expected at least one service category")
            return
        }

        XCTAssertTrue(visibility.isEnabled(lastCategory))
        XCTAssertEqual(visibility.enabledCategories.count, 1)

        visibility.set(lastCategory, enabled: false)

        XCTAssertTrue(visibility.isEnabled(lastCategory))
        XCTAssertEqual(visibility.enabledCategories.count, 1)
    }

    func testDisplayedServiceCategoriesRespectsVisibility() {
        var card = ExitCard(exit: makeExit())
        card.gasPOIs = [makePOI(id: "gas-1", category: .gas)]
        card.evChargingPOIs = [makePOI(id: "ev-1", category: .evCharging)]
        card.restAreaPOIs = [makePOI(id: "rest-1", category: .restStop)]

        let visible = Set<ExitCardServiceCategory>([.gas, .restAreas])
        let rows = card.displayedServiceCategories(visibleCategories: visible)

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].map(\.id), ["gas-1"])
        XCTAssertEqual(rows[1].map(\.id), ["rest-1"])
    }

    func testDisplayedServiceCategoriesUsesConfiguredDisplayOrder() {
        var card = ExitCard(exit: makeExit())
        card.foodPOIs = [makePOI(id: "food-1", category: .food)]
        card.gasPOIs = [makePOI(id: "gas-1", category: .gas)]
        card.restAreaPOIs = [makePOI(id: "rest-1", category: .restStop)]
        card.lodgingPOIs = [makePOI(id: "lodging-1", category: .lodging)]
        card.evChargingPOIs = [makePOI(id: "ev-1", category: .evCharging)]

        let rows = card.displayedServiceCategories(
            visibleCategories: Set(ExitCardServiceCategory.allCases)
        )

        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows[0].map(\.id), ["food-1"])
        XCTAssertEqual(rows[1].map(\.id), ["gas-1"])
        XCTAssertEqual(rows[2].map(\.id), ["rest-1"])
        XCTAssertEqual(rows[3].map(\.id), ["lodging-1"])
        XCTAssertEqual(rows[4].map(\.id), ["ev-1"])
    }

    func testRestAreaOnlyCardFallsBackToStandardHeightWhenRestAreasHidden() {
        var card = ExitCard(exit: makeExit())
        card.restAreaPOIs = [makePOI(id: "rest-1", category: .restStop)]

        let visible = Set<ExitCardServiceCategory>([.gas])
        let height = card.estimatedCardHeight(visibleCategories: visible)

        XCTAssertNotEqual(height, ExitCard.restAreaCardHeight)
    }

    func testMaxBadgeRowsPerCategoryUsesRequestedScalingRules() {
        let foodOnly: Set<ExitCardServiceCategory> = [.food]
        XCTAssertEqual(
            ExitCard.maxBadgeRowsPerCategory(for: .food, shownCategories: foodOnly),
            6
        )

        let foodAndGas: Set<ExitCardServiceCategory> = [.food, .gas]
        XCTAssertEqual(
            ExitCard.maxBadgeRowsPerCategory(for: .food, shownCategories: foodAndGas),
            3
        )
        XCTAssertEqual(
            ExitCard.maxBadgeRowsPerCategory(for: .gas, shownCategories: foodAndGas),
            3
        )

        let foodGasLodging: Set<ExitCardServiceCategory> = [.food, .gas, .lodging]
        XCTAssertEqual(
            ExitCard.maxBadgeRowsPerCategory(for: .food, shownCategories: foodGasLodging),
            2
        )

        let foodAndRestArea: Set<ExitCardServiceCategory> = [.food, .restAreas]
        XCTAssertEqual(
            ExitCard.maxBadgeRowsPerCategory(for: .food, shownCategories: foodAndRestArea),
            6
        )
        XCTAssertEqual(
            ExitCard.maxBadgeRowsPerCategory(for: .restAreas, shownCategories: foodAndRestArea),
            1
        )

        let foodGasAndRestArea: Set<ExitCardServiceCategory> = [.food, .gas, .restAreas]
        XCTAssertEqual(
            ExitCard.maxBadgeRowsPerCategory(for: .food, shownCategories: foodGasAndRestArea),
            3
        )
        XCTAssertEqual(
            ExitCard.maxBadgeRowsPerCategory(for: .gas, shownCategories: foodGasAndRestArea),
            3
        )
        XCTAssertEqual(
            ExitCard.maxBadgeRowsPerCategory(for: .restAreas, shownCategories: foodGasAndRestArea),
            1
        )
    }

    func testEmptySelectedCategoriesDoNotReduceShownCategoryRows() {
        var card = ExitCard(exit: makeExit())
        card.gasPOIs = (1...18).map { index in
            makePOI(id: "gas-\(index)", category: .gas)
        }

        let oneShownCategoryHeight = card.estimatedCardHeight(visibleCategories: [.gas])
        let withEmptyCategoriesEnabledHeight = card.estimatedCardHeight(
            visibleCategories: [.gas, .food, .lodging, .restAreas]
        )

        XCTAssertEqual(oneShownCategoryHeight, withEmptyCategoriesEnabledHeight)
    }

    private func makeExit() -> Exit {
        Exit(
            id: "exit-1",
            exitNumber: "1",
            name: "Main St",
            coordinate: CLLocationCoordinate2D(latitude: 35.0, longitude: -80.0),
            distanceFromUser: 1200,
            estimatedTimeToExit: 60
        )
    }

    private func makePOI(id: String, category: POICategory) -> POI {
        POI(
            id: id,
            name: id,
            coordinate: CLLocationCoordinate2D(latitude: 35.0, longitude: -80.0),
            category: category,
            distanceFromExit: 100,
            estimatedDriveDistanceFromExit: nil,
            estimatedDriveTimeFromExit: nil
        )
    }
}
