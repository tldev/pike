import SwiftUI
import MapKit
import CoreLocation

@MainActor
protocol MainMapLocationControlling: AnyObject {
    var currentLocation: CLLocation? { get }
    var effectiveCourse: CLLocationDirection { get }
    func requestPermission()
}

extension LocationManager: MainMapLocationControlling {}

@MainActor
protocol MainMapFeedControlling: AnyObject {
    func loadExitCards(userLocation: CLLocation, userCourse: CLLocationDirection) async
    func resetFeedState()
}

extension ExitService: MainMapFeedControlling {}

struct OnboardingPreferenceStore {
    let defaults: UserDefaults
    let hasSeenKey: String

    init(
        defaults: UserDefaults = .standard,
        hasSeenKey: String = "hasSeenOnboarding"
    ) {
        self.defaults = defaults
        self.hasSeenKey = hasSeenKey
    }

    func hasSeenOnboarding() -> Bool {
        defaults.bool(forKey: hasSeenKey)
    }

    func markSeen() {
        defaults.set(true, forKey: hasSeenKey)
    }
}

@MainActor
final class MainMapViewModel: ObservableObject {
    @Published var selectedPOI: POI?
    @Published var showSettings = false
    @Published var showPOIList = false
    @Published var mapCameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)
    @Published var isFollowingCourse = true
    @Published var focusedExitCard: ExitCard?
    @Published var showOnboarding: Bool
    @Published var showStartupLoading = true

    private let onboardingStore: OnboardingPreferenceStore
    private var didScheduleStartupLoading = false
    private var isUpdatingCamera = false
    private var cameraUpdateGeneration = 0

    init(onboardingStore: OnboardingPreferenceStore = OnboardingPreferenceStore()) {
        self.onboardingStore = onboardingStore
        self.showOnboarding = !onboardingStore.hasSeenOnboarding()
    }

    func handleAppear(locationManager: any MainMapLocationControlling) {
        if !didScheduleStartupLoading {
            didScheduleStartupLoading = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                withAnimation(.easeOut(duration: 0.28)) {
                    self.showStartupLoading = false
                }
            }
        }
        if !showOnboarding {
            locationManager.requestPermission()
        }
        applyFollowMode(.following)
    }

    func handleFocusedExitChange(
        locationManager: any MainMapLocationControlling,
        isTestDriveActive: Bool
    ) {
        guard focusedExitCard != nil else { return }
        applyFollowMode(.following)
        updateCourseCamera(
            locationManager: locationManager,
            isTestDriveActive: isTestDriveActive
        )
    }

    func handleLocationChange(
        locationManager: any MainMapLocationControlling,
        exitService: any MainMapFeedControlling,
        isTestDriveActive: Bool
    ) async {
        if isFollowingCourse {
            updateCourseCamera(
                locationManager: locationManager,
                isTestDriveActive: isTestDriveActive
            )
        }

        guard let location = locationManager.currentLocation else { return }
        await exitService.loadExitCards(
            userLocation: location,
            userCourse: locationManager.effectiveCourse
        )
    }

    func handleTestDriveActivityChange(
        isActive: Bool,
        exitService: any MainMapFeedControlling
    ) {
        if isActive {
            applyFollowMode(.following)
        } else {
            exitService.resetFeedState()
            mapCameraPosition = .userLocation(fallback: .automatic)
            isUpdatingCamera = false
            cameraUpdateGeneration = 0
        }
    }

    func handleMapCameraChange(isTestDriveActive: Bool) {
        let disposition = MainMapCoordinator.cameraChangeDisposition(
            isUpdatingCamera: isUpdatingCamera,
            isTestDriveActive: isTestDriveActive,
            followMode: followMode
        )

        switch disposition {
        case .consumeProgrammaticChange:
            isUpdatingCamera = false
        case .disableFollowMode:
            applyFollowMode(.manual)
        case .keepCurrentMode:
            break
        }
    }

    func toggleFollowMode(
        locationManager: any MainMapLocationControlling,
        isTestDriveActive: Bool
    ) {
        let next = MainMapCoordinator.toggledFollowMode(from: followMode)
        applyFollowMode(next)

        if next.isFollowingCourse {
            updateCourseCamera(
                locationManager: locationManager,
                isTestDriveActive: isTestDriveActive
            )
        }
    }

    func presentPOIList() {
        showPOIList = true
    }

    func presentSettings() {
        showSettings = true
    }

    func selectPOI(_ poi: POI) {
        selectedPOI = poi
    }

    func selectPOIFromList(_ poi: POI) {
        showPOIList = false
        selectedPOI = poi
    }

    func dismissOnboarding(locationManager: any MainMapLocationControlling) {
        withAnimation { showOnboarding = false }
        onboardingStore.markSeen()
        locationManager.requestPermission()
    }

    func shouldShowCustomLocationDot(isTestDriveActive: Bool) -> Bool {
        MainMapCoordinator.shouldShowCustomLocationDot(
            isTestDriveActive: isTestDriveActive
        )
    }

    private var followMode: MainMapCoordinator.FollowMode {
        MainMapCoordinator.FollowMode(isFollowingCourse: isFollowingCourse)
    }

    private func applyFollowMode(_ mode: MainMapCoordinator.FollowMode) {
        isFollowingCourse = mode.isFollowingCourse
    }

    private func updateCourseCamera(
        locationManager: any MainMapLocationControlling,
        isTestDriveActive: Bool
    ) {
        guard let userLocation = locationManager.currentLocation else { return }
        let plan = CourseCameraPlanner.plan(
            userCoordinate: userLocation.coordinate,
            userCourse: locationManager.effectiveCourse,
            focusedExitDistance: focusedExitCard?.exit.distanceFromUser
        )

        let camera = MapCamera(
            centerCoordinate: plan.centerCoordinate,
            distance: plan.distanceMeters,
            heading: plan.heading,
            pitch: plan.pitch
        )

        isUpdatingCamera = true
        cameraUpdateGeneration += 1

        let animationStyle = MainMapCoordinator.cameraAnimationStyle(
            isTestDriveActive: isTestDriveActive
        )

        switch animationStyle {
        case .fastSnap:
            withAnimation(.linear(duration: 0.15)) {
                mapCameraPosition = .camera(camera)
            }
        case .smoothFollow:
            let generation = cameraUpdateGeneration
            withAnimation(.spring(duration: 1.2, bounce: 0)) {
                mapCameraPosition = .camera(camera)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    if self.cameraUpdateGeneration == generation {
                        self.isUpdatingCamera = false
                    }
                }
            }
        }
    }
}
