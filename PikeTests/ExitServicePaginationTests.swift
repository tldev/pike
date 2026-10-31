import XCTest
@testable import Pike
import CoreGraphics

final class ExitServicePaginationTests: XCTestCase {

    func testFirstNoProgressPageDoesNotExhaust() {
        let next = ExitService.nextNoProgressState(
            noProgressPageCount: 0,
            pagingExhausted: false
        )

        XCTAssertEqual(next.noProgressPageCount, 1)
        XCTAssertFalse(next.pagingExhausted)
    }

    func testSecondNoProgressPageExhaustsPaging() {
        let next = ExitService.nextNoProgressState(
            noProgressPageCount: 1,
            pagingExhausted: false
        )

        XCTAssertEqual(next.noProgressPageCount, 2)
        XCTAssertTrue(next.pagingExhausted)
    }

    func testAlreadyExhaustedStateRemainsExhausted() {
        let next = ExitService.nextNoProgressState(
            noProgressPageCount: 1,
            pagingExhausted: true
        )

        XCTAssertEqual(next.noProgressPageCount, 2)
        XCTAssertTrue(next.pagingExhausted)
    }
}

final class ExitBrowserLogicTests: XCTestCase {
    func testVisibleCardIndicesAroundCurrentIndex() {
        XCTAssertEqual(
            ExitBrowserLogic.visibleCardIndices(total: 6, currentIndex: 3, visibleWindow: 1),
            [2, 3, 4]
        )
        XCTAssertEqual(
            ExitBrowserLogic.visibleCardIndices(total: 6, currentIndex: 0, visibleWindow: 1),
            [0, 1]
        )
    }

    func testVisibleCardIndicesClampsOutOfBoundsCurrentIndex() {
        XCTAssertEqual(
            ExitBrowserLogic.visibleCardIndices(total: 6, currentIndex: -10, visibleWindow: 1),
            [0, 1]
        )
        XCTAssertEqual(
            ExitBrowserLogic.visibleCardIndices(total: 6, currentIndex: 99, visibleWindow: 1),
            [4, 5]
        )
    }

    func testVisibleCardIndicesTreatsNegativeWindowAsZero() {
        XCTAssertEqual(
            ExitBrowserLogic.visibleCardIndices(total: 6, currentIndex: 3, visibleWindow: -3),
            [3]
        )
    }

    func testBoundedDragOffsetAppliesEdgeResistance() {
        XCTAssertEqual(
            ExitBrowserLogic.boundedDragOffset(
                translation: 100,
                currentIndex: 0,
                totalCards: 4
            ),
            32,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ExitBrowserLogic.boundedDragOffset(
                translation: -100,
                currentIndex: 2,
                totalCards: 4
            ),
            -100,
            accuracy: 0.001
        )
    }

    func testIndicatorPageIndicesShowsThreePageWindow() {
        XCTAssertEqual(
            ExitBrowserLogic.indicatorPageIndices(total: 8, currentIndex: 0),
            [0, 1, 2]
        )
        XCTAssertEqual(
            ExitBrowserLogic.indicatorPageIndices(total: 8, currentIndex: 4),
            [3, 4, 5]
        )
        XCTAssertEqual(
            ExitBrowserLogic.indicatorPageIndices(total: 8, currentIndex: 7),
            [5, 6, 7]
        )
    }
}

final class OnboardingPreferenceStoreTests: XCTestCase {
    func testMarkSeenPersistsFlag() {
        let suiteName = "OnboardingPreferenceStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = OnboardingPreferenceStore(
            defaults: defaults,
            hasSeenKey: "onboardingSeen"
        )
        XCTAssertFalse(store.hasSeenOnboarding())
        store.markSeen()
        XCTAssertTrue(store.hasSeenOnboarding())
    }
}
