import Foundation
import CoreLocation

/// Manages location updates, course tracking, and travel state.
/// Uses CLLocation.course (NOT heading) for direction of travel.
@MainActor
final class LocationManager: NSObject, ObservableObject {

    static let shared = LocationManager()

    // MARK: - Published State

    @Published var currentLocation: CLLocation?
    @Published var smoothedCourse: CLLocationDirection = 0

    private var testDriveLocation: CLLocation?
    private var lastGPSLocation: CLLocation?

    private var isTestDriving: Bool {
        testDriveLocation != nil
    }

    // MARK: - Internal

    private let clManager = CLLocationManager()
    private let courseFilter = CourseKalmanFilter()

    /// Previous location for computing course from movement.
    private var previousLocation: CLLocation?

    #if targetEnvironment(simulator)
    private static let simulatorFallbackCoordinate = CLLocationCoordinate2D(
        latitude: 34.496,
        longitude: -83.005
    )
    #endif

    private override init() {
        super.init()
        clManager.delegate = self
        clManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        clManager.distanceFilter = 10
        clManager.activityType = .automotiveNavigation
    }

    // MARK: - Public API

    func requestPermission() {
        let status = clManager.authorizationStatus
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            startTracking()
            return
        }
        clManager.requestWhenInUseAuthorization()
    }

    func startTracking() {
        clManager.startUpdatingLocation()
        #if targetEnvironment(simulator)
        applySimulatorFallbackLocationIfNeeded()
        #endif
    }

    /// Feed a simulated location from the test drive player.
    func applyTestDriveLocation(_ loc: CLLocation) {
        testDriveLocation = loc
        processTestDriveLocation(loc)
    }

    /// Stop test drive and resume normal GPS.
    func clearTestDriveLocation() {
        testDriveLocation = nil
        restoreLocationAfterTestDrive()
    }

    /// The last filtered course value.
    var effectiveCourse: CLLocationDirection {
        smoothedCourse
    }

    /// Best available non-test-drive coordinate for route discovery/start placement.
    var routeDiscoveryCoordinate: CLLocationCoordinate2D? {
        if !isTestDriving, let currentLocation {
            return currentLocation.coordinate
        }

        if let coordinate = clManager.location?.coordinate ?? lastGPSLocation?.coordinate ?? currentLocation?.coordinate {
            return coordinate
        }
        #if targetEnvironment(simulator)
        return Self.simulatorFallbackCoordinate
        #else
        return nil
        #endif
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationManager: CLLocationManagerDelegate {

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        Task { @MainActor in
            // Suppress real GPS during test drive
            guard testDriveLocation == nil else { return }
            processLocation(location)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                self.startTracking()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // GPS loss — keep using last known course from Kalman filter
    }
}

// MARK: - Location Processing

extension LocationManager {

    private func processLocation(_ location: CLLocation) {
        // Filter out stale or inaccurate readings
        guard location.horizontalAccuracy >= 0,
              location.horizontalAccuracy < 100,
              abs(location.timestamp.timeIntervalSinceNow) < 10 else {
            return
        }

        lastGPSLocation = location
        currentLocation = location

        // Use CLLocation.course when available; fall back to computing from movement.
        if location.course >= 0 {
            smoothedCourse = courseFilter.update(measurement: location.course)
        } else if let prev = previousLocation {
            // Compute course from consecutive positions
            let dist = location.distance(from: prev)
            if dist > 5 { // At least 5m movement to compute a bearing
                let computed = GeoMath.bearing(
                    from: prev.coordinate,
                    to: location.coordinate
                )
                smoothedCourse = courseFilter.update(measurement: computed)
            }
        }

        previousLocation = location
    }

    /// Process a test drive location without filtering stale timestamps.
    private func processTestDriveLocation(_ location: CLLocation) {
        currentLocation = location

        if location.course >= 0 {
            smoothedCourse = courseFilter.update(measurement: location.course)
        }

        previousLocation = location
    }

    #if targetEnvironment(simulator)
    private func restoreLocationAfterTestDrive() {
        if let liveLocation = clManager.location {
            currentLocation = liveLocation
            lastGPSLocation = liveLocation
            previousLocation = liveLocation
            if liveLocation.course >= 0 {
                smoothedCourse = courseFilter.update(measurement: liveLocation.course)
            }
            return
        }

        if let lastGPSLocation {
            currentLocation = lastGPSLocation
            previousLocation = lastGPSLocation
            return
        }

        applySimulatorFallbackLocation(force: true)
    }

    private func applySimulatorFallbackLocationIfNeeded() {
        guard !isTestDriving, currentLocation == nil else { return }
        guard clManager.location == nil, lastGPSLocation == nil else { return }
        applySimulatorFallbackLocation()
    }

    private func applySimulatorFallbackLocation(force: Bool = false) {
        guard force || currentLocation == nil else { return }
        let fallback = CLLocation(
            coordinate: Self.simulatorFallbackCoordinate,
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: -1,
            speed: 0,
            timestamp: Date()
        )
        currentLocation = fallback
        previousLocation = fallback
    }
    #else
    private func restoreLocationAfterTestDrive() {
        currentLocation = nil
        previousLocation = nil
    }
    #endif
}
