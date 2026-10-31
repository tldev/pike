//
//  TestDrivePlayer.swift
//  Pike
//
//  Plays back pack-provided test drive routes to simulate driving, letting
//  users experience the exit carousel without being on a real highway.
//

import Foundation
import CoreLocation

@MainActor
final class TestDrivePlayer: ObservableObject {

    @Published private(set) var isActive = false

    private struct TimedWaypoint {
        let coordinate: CLLocationCoordinate2D
        let timestamp: Date
    }

    private let locationManager: LocationManager
    private var waypoints: [TimedWaypoint] = []
    private var totalDuration: TimeInterval = 0
    private var timeOffset: TimeInterval = 0
    private var timer: Timer?
    private var lastDiscoveryCoordinate: CLLocationCoordinate2D?

    /// Start a bit into the route so the first exits appear quickly.
    private let startOffset: TimeInterval = 480
    /// 20x real-time so exits scroll by at a watchable pace.
    private let playbackSpeed: Double = 20
    /// 10 Hz tick rate for smooth movement.
    private let tickInterval: TimeInterval = 0.1
    /// Keep at least this much wall-clock playback after start (at current playback speed).
    private let minimumVisiblePlaybackSeconds: TimeInterval = 20

    init(locationManager: LocationManager) {
        self.locationManager = locationManager
    }

    func start(routeId: String) -> Bool {
        guard !isActive, let route = loadRoute(routeId) else { return false }
        return startWithRoute(waypoints: buildWaypoints(from: route), startIndex: route.startIndex)
    }

    func routeChoices(limit: Int) -> [TestDriveRouteChoice] {
        (try? BundledPack.open().testDriveRouteChoices(near: discoveryCoordinate(), limit: limit)) ?? []
    }

    private func loadRoute(_ routeId: String) -> TestDriveRouteData? {
        try? BundledPack.open().testDriveRouteById(routeId, near: discoveryCoordinate())
    }

    private func discoveryCoordinate() -> CLLocationCoordinate2D? {
        if let coordinate = locationManager.routeDiscoveryCoordinate {
            lastDiscoveryCoordinate = coordinate
        }
        return lastDiscoveryCoordinate
    }

    private func buildWaypoints(from route: TestDriveRouteData) -> [TimedWaypoint] {
        let baseTime = Date(timeIntervalSince1970: 1_736_198_400) // Jan 6, 2025 UTC
        return route.waypoints.enumerated().map { idx, coord in
            TimedWaypoint(
                coordinate: coord,
                timestamp: baseTime.addingTimeInterval(Double(idx) * route.intervalSeconds)
            )
        }
    }

    private func startWithRoute(
        waypoints parsed: [TimedWaypoint],
        startIndex: Int?
    ) -> Bool {
        guard parsed.count >= 2 else { return false }

        waypoints = parsed
        totalDuration = totalDuration(of: parsed)
        let offsetFromIndex = startIndexOffset(startIndex: startIndex, route: parsed)
        let defaultOffset = min(startOffset, max(0, totalDuration - 1))
        var effectiveOffset = min(max(0, offsetFromIndex ?? defaultOffset), max(0, totalDuration - 1))
        let minimumRemainingRouteSeconds = max(120, playbackSpeed * minimumVisiblePlaybackSeconds)

        if max(0, totalDuration - effectiveOffset) < minimumRemainingRouteSeconds {
            effectiveOffset = min(effectiveOffset, max(0, totalDuration - minimumRemainingRouteSeconds))
        }

        timeOffset = effectiveOffset
        isActive = true

        timer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        return true
    }

    private func startIndexOffset(startIndex: Int?, route: [TimedWaypoint]) -> TimeInterval? {
        guard let startIndex, startIndex >= 0, startIndex < route.count else {
            return nil
        }
        let base = route.first?.timestamp ?? .distantPast
        return route[startIndex].timestamp.timeIntervalSince(base)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        waypoints = []
        timeOffset = 0
        isActive = false
        locationManager.clearTestDriveLocation()
    }

    private func tick() {
        timeOffset += tickInterval * playbackSpeed

        guard timeOffset < totalDuration else {
            stop()
            return
        }

        if let loc = interpolatedLocation(at: timeOffset, in: waypoints) {
            locationManager.applyTestDriveLocation(loc)
        }
    }

    private func totalDuration(of waypoints: [TimedWaypoint]) -> TimeInterval {
        guard let first = waypoints.first, let last = waypoints.last else { return 0 }
        return last.timestamp.timeIntervalSince(first.timestamp)
    }

    private func interpolatedLocation(at timeOffset: TimeInterval, in waypoints: [TimedWaypoint]) -> CLLocation? {
        guard waypoints.count >= 2, let first = waypoints.first else { return nil }

        let targetTime = first.timestamp.addingTimeInterval(timeOffset)
        var lo = 0
        var hi = waypoints.count - 1

        while lo < hi - 1 {
            let mid = (lo + hi) / 2
            if waypoints[mid].timestamp <= targetTime {
                lo = mid
            } else {
                hi = mid
            }
        }

        let start = waypoints[lo]
        let end = waypoints[hi]
        let segmentDuration = end.timestamp.timeIntervalSince(start.timestamp)

        guard segmentDuration > 0 else {
            return CLLocation(latitude: start.coordinate.latitude, longitude: start.coordinate.longitude)
        }

        let fraction = max(0, min(1, targetTime.timeIntervalSince(start.timestamp) / segmentDuration))
        let lat = start.coordinate.latitude + (end.coordinate.latitude - start.coordinate.latitude) * fraction
        let lon = start.coordinate.longitude + (end.coordinate.longitude - start.coordinate.longitude) * fraction
        let course = GeoMath.bearing(from: start.coordinate, to: end.coordinate)
        let distance = GeoMath.haversineDistance(from: start.coordinate, to: end.coordinate)
        let speed = distance / segmentDuration

        return CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: course,
            speed: speed,
            timestamp: targetTime
        )
    }
}
