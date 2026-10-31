import XCTest
import CoreLocation
@testable import Pike

@MainActor
final class MainMapCoordinatorTests: XCTestCase {
    func testFollowModeToggleSwitchesBetweenFollowingAndManual() {
        let following = MainMapCoordinator.FollowMode.following
        let manual = MainMapCoordinator.toggledFollowMode(from: following)
        XCTAssertEqual(manual, .manual)

        let toggledBack = MainMapCoordinator.toggledFollowMode(from: manual)
        XCTAssertEqual(toggledBack, .following)
    }

    func testCameraChangeDispositionConsumesProgrammaticUpdate() {
        let disposition = MainMapCoordinator.cameraChangeDisposition(
            isUpdatingCamera: true,
            isTestDriveActive: false,
            followMode: .following
        )

        XCTAssertEqual(disposition, .consumeProgrammaticChange)
    }

    func testCameraChangeDispositionDisablesFollowOnManualMove() {
        let disposition = MainMapCoordinator.cameraChangeDisposition(
            isUpdatingCamera: false,
            isTestDriveActive: false,
            followMode: .following
        )

        XCTAssertEqual(disposition, .disableFollowMode)
    }

    func testCameraChangeDispositionKeepsModeDuringTestDrive() {
        let disposition = MainMapCoordinator.cameraChangeDisposition(
            isUpdatingCamera: false,
            isTestDriveActive: true,
            followMode: .following
        )

        XCTAssertEqual(disposition, .keepCurrentMode)
    }

    func testCameraAnimationStyleUsesFastSnapForTestDrive() {
        XCTAssertEqual(
            MainMapCoordinator.cameraAnimationStyle(isTestDriveActive: true),
            .fastSnap
        )
        XCTAssertEqual(
            MainMapCoordinator.cameraAnimationStyle(isTestDriveActive: false),
            .smoothFollow
        )
    }

    func testCustomDotVisibilityMatchesTestDriveState() {
        XCTAssertTrue(MainMapCoordinator.shouldShowCustomLocationDot(isTestDriveActive: true))
        XCTAssertFalse(MainMapCoordinator.shouldShowCustomLocationDot(isTestDriveActive: false))
    }
}

@MainActor
final class MainMapViewModelTests: XCTestCase {
    func testDismissOnboardingMarksSeenAndRequestsPermission() {
        let suiteName = "MainMapViewModelTests.Onboarding.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = OnboardingPreferenceStore(defaults: defaults, hasSeenKey: "seen")
        let viewModel = MainMapViewModel(onboardingStore: store)
        let location = MockLocationController()

        viewModel.dismissOnboarding(locationManager: location)

        XCTAssertFalse(viewModel.showOnboarding)
        XCTAssertEqual(location.requestPermissionCalls, 1)
        XCTAssertTrue(store.hasSeenOnboarding())
    }

    func testSelectPOIFromListDismissesSheetAndSetsSelection() {
        let viewModel = MainMapViewModel()
        viewModel.showPOIList = true

        let poi = makePOI(id: "poi-1")
        viewModel.selectPOIFromList(poi)

        XCTAssertFalse(viewModel.showPOIList)
        XCTAssertEqual(viewModel.selectedPOI?.id, "poi-1")
    }

    func testHandleLocationChangeRequestsExitLoad() async {
        let viewModel = MainMapViewModel()
        let location = MockLocationController()
        location.currentLocation = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 35.0, longitude: -80.0),
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: 45,
            speed: 30,
            timestamp: Date()
        )
        location.effectiveCourse = 45

        let feed = MockFeedController()
        await viewModel.handleLocationChange(
            locationManager: location,
            exitService: feed,
            isTestDriveActive: false
        )

        XCTAssertEqual(feed.loadRequests.count, 1)
        XCTAssertEqual(feed.loadRequests[0].course, 45, accuracy: 0.001)
    }

    func testHandleTestDriveStopResetsFeed() {
        let viewModel = MainMapViewModel()
        let feed = MockFeedController()

        viewModel.handleTestDriveActivityChange(isActive: false, exitService: feed)

        XCTAssertEqual(feed.resetCalls, 1)
        XCTAssertTrue(
            String(describing: viewModel.mapCameraPosition).contains("userLocation"),
            "Expected user-location camera mode after test drive stop"
        )
    }

    func testHandleMapCameraChangeDisablesFollowOnManualMove() {
        let viewModel = MainMapViewModel()

        viewModel.handleMapCameraChange(isTestDriveActive: false)

        XCTAssertFalse(viewModel.isFollowingCourse)
    }

    func testProgrammaticCameraChangeIsConsumedWithoutDisablingFollow() {
        let viewModel = MainMapViewModel()
        let location = MockLocationController()
        location.currentLocation = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 35.0, longitude: -80.0),
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: 90,
            speed: 30,
            timestamp: Date()
        )
        location.effectiveCourse = 90

        viewModel.focusedExitCard = makeExitCard(distanceFromUser: 12_000)
        viewModel.handleFocusedExitChange(
            locationManager: location,
            isTestDriveActive: false
        )
        viewModel.handleMapCameraChange(isTestDriveActive: false)

        XCTAssertTrue(viewModel.isFollowingCourse)
    }

    private func makePOI(id: String) -> POI {
        POI(
            id: id,
            name: "Test POI",
            coordinate: CLLocationCoordinate2D(latitude: 35.0, longitude: -80.0),
            category: .food,
            distanceFromExit: 100,
            estimatedDriveDistanceFromExit: 200,
            estimatedDriveTimeFromExit: 60
        )
    }

    private func makeExitCard(distanceFromUser: CLLocationDistance) -> ExitCard {
        let exit = Exit(
            id: "exit-1",
            exitNumber: "1",
            name: "Main St",
            coordinate: CLLocationCoordinate2D(latitude: 35.01, longitude: -80.01),
            distanceFromUser: distanceFromUser,
            estimatedTimeToExit: 60
        )
        return ExitCard(exit: exit)
    }
}

@MainActor
private final class MockLocationController: MainMapLocationControlling {
    var currentLocation: CLLocation?
    var effectiveCourse: CLLocationDirection = 0
    private(set) var requestPermissionCalls = 0

    func requestPermission() {
        requestPermissionCalls += 1
    }
}

@MainActor
private final class MockFeedController: MainMapFeedControlling {
    struct LoadRequest {
        let location: CLLocation
        let course: CLLocationDirection
    }

    private(set) var loadRequests: [LoadRequest] = []
    private(set) var resetCalls = 0

    func loadExitCards(userLocation: CLLocation, userCourse: CLLocationDirection) async {
        loadRequests.append(LoadRequest(location: userLocation, course: userCourse))
    }

    func resetFeedState() {
        resetCalls += 1
    }
}
