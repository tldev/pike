import Foundation
import CoreLocation

/// Core geographic math utilities for bearing, distance, and point projection.
enum GeoMath {

    static let earthRadiusMeters: Double = 6_371_000

    // MARK: - Bearing

    /// Calculate the initial bearing from point A to point B in degrees (0-360).
    static func bearing(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> CLLocationDirection {
        let lat1 = from.latitude.degreesToRadians
        let lat2 = to.latitude.degreesToRadians
        let dLon = (to.longitude - from.longitude).degreesToRadians

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let bearing = atan2(y, x).radiansToDegrees

        return (bearing + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Angle difference between two bearings, normalized to -180...180.
    static func angleDifference(_ a: CLLocationDirection, _ b: CLLocationDirection) -> Double {
        var diff = a - b
        while diff > 180 { diff -= 360 }
        while diff < -180 { diff += 360 }
        return diff
    }

    /// Absolute angular difference between two bearings (0-180).
    static func absoluteAngleDifference(_ a: CLLocationDirection, _ b: CLLocationDirection) -> Double {
        abs(angleDifference(a, b))
    }

    // MARK: - Distance

    /// Haversine distance between two coordinates in meters.
    static func haversineDistance(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> CLLocationDistance {
        let lat1 = from.latitude.degreesToRadians
        let lat2 = to.latitude.degreesToRadians
        let dLat = (to.latitude - from.latitude).degreesToRadians
        let dLon = (to.longitude - from.longitude).degreesToRadians

        let a = sin(dLat / 2) * sin(dLat / 2) +
                cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))

        return earthRadiusMeters * c
    }

    // MARK: - Point Projection

    /// Project a coordinate forward along a bearing by a given distance.
    static func project(
        from: CLLocationCoordinate2D,
        bearing: CLLocationDirection,
        distanceMeters: CLLocationDistance
    ) -> CLLocationCoordinate2D {
        let lat1 = from.latitude.degreesToRadians
        let lon1 = from.longitude.degreesToRadians
        let brng = bearing.degreesToRadians
        let d = distanceMeters / earthRadiusMeters

        let lat2 = asin(sin(lat1) * cos(d) + cos(lat1) * sin(d) * cos(brng))
        let lon2 = lon1 + atan2(sin(brng) * sin(d) * cos(lat1), cos(d) - sin(lat1) * sin(lat2))

        return CLLocationCoordinate2D(
            latitude: lat2.radiansToDegrees,
            longitude: lon2.radiansToDegrees
        )
    }
}

struct CourseCameraPlan {
    let centerCoordinate: CLLocationCoordinate2D
    let distanceMeters: CLLocationDistance
    let heading: CLLocationDirection
    let pitch: Double
}

enum CourseCameraPlanner {
    static func plan(
        userCoordinate: CLLocationCoordinate2D,
        userCourse: CLLocationDirection,
        focusedExitDistance: CLLocationDistance?
    ) -> CourseCameraPlan {
        let lookAhead: CLLocationDistance
        if let focusedExitDistance, focusedExitDistance > 0 {
            lookAhead = min(focusedExitDistance * 1.3, 80_000)
        } else {
            lookAhead = 16_000
        }

        let centerOffset = lookAhead * 0.4
        let center = GeoMath.project(
            from: userCoordinate,
            bearing: userCourse,
            distanceMeters: centerOffset
        )

        return CourseCameraPlan(
            centerCoordinate: center,
            distanceMeters: lookAhead * 2.0,
            heading: userCourse,
            pitch: 50
        )
    }
}

// MARK: - Numeric Extensions

extension Double {
    var degreesToRadians: Double { self * .pi / 180 }
    var radiansToDegrees: Double { self * 180 / .pi }
}
