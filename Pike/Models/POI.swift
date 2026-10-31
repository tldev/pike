import Foundation
import CoreLocation
import MapKit

/// A point of interest found along the user's route.
struct POI: Identifiable, Equatable {
    let id: String
    let name: String
    let coordinate: CLLocationCoordinate2D
    let category: POICategory

    /// Distance from the exit ramp to this POI in meters (as reported by the exit feed/database).
    var distanceFromExit: CLLocationDistance?

    /// Reachability-based one-way drive distance from exit to POI in meters.
    var estimatedDriveDistanceFromExit: CLLocationDistance?

    /// Reachability-based one-way drive time from exit to POI in seconds.
    var estimatedDriveTimeFromExit: TimeInterval?

    static func == (lhs: POI, rhs: POI) -> Bool {
        lhs.id == rhs.id
    }

    /// Open directions to this POI in Apple Maps.
    func openInMaps() {
        let destination = Self.mapItem(at: coordinate)
        destination.name = name
        destination.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
        ])
    }

    // MARK: - Apple Maps Place Resolution

    private static var appleMapItemCache: [String: MKMapItem] = [:]

    /// Resolve and open the actual Apple Maps business listing via MKLocalSearch.
    /// Falls back to a coordinate pin if no match is found.
    func resolveAndOpenInAppleMaps() async {
        // Check cache
        if let cached = Self.appleMapItemCache[id] {
            cached.openInMaps(launchOptions: nil)
            return
        }

        // Search for the business near the POI coordinate
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = name
        request.region = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: 400,
            longitudinalMeters: 400
        )

        do {
            let search = MKLocalSearch(request: request)
            let response = try await search.start()

            // Find the closest match within 200m
            let poiLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

            func distance(to item: MKMapItem) -> CLLocationDistance {
                let coord = Self.coordinate(of: item)
                return CLLocation(latitude: coord.latitude, longitude: coord.longitude)
                    .distance(from: poiLocation)
            }

            let best = response.mapItems
                .filter { distance(to: $0) <= 200 }
                .min(by: { distance(to: $0) < distance(to: $1) })

            if let resolved = best {
                Self.appleMapItemCache[id] = resolved
                resolved.openInMaps(launchOptions: nil)
                return
            }
        } catch {
            // Fall through to coordinate pin
        }

        // Fallback: bare coordinate pin (no directions mode — shows the pin on the map)
        let fallback = Self.mapItem(at: coordinate)
        fallback.name = name
        fallback.openInMaps(launchOptions: nil)
    }

    // MARK: - MKPlacemark Compatibility

    private static func mapItem(at coordinate: CLLocationCoordinate2D) -> MKMapItem {
        if #available(iOS 26, *) {
            MKMapItem(location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude), address: nil)
        } else {
            MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        }
    }

    private static func coordinate(of item: MKMapItem) -> CLLocationCoordinate2D {
        if #available(iOS 26, *) {
            item.location.coordinate
        } else {
            item.placemark.coordinate
        }
    }
}

enum POISorter {
    /// Stable sort by estimated drive time (when available), then by original order.
    static func byEstimatedDriveTime(_ pois: [POI]) -> [POI] {
        pois.enumerated().sorted { lhs, rhs in
            let lhsTime = lhs.element.estimatedDriveTimeFromExit
            let rhsTime = rhs.element.estimatedDriveTimeFromExit

            switch (lhsTime, rhsTime) {
            case let (l?, r?) where l != r:
                return l < r
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }
}
