//
//  BoundingBox.swift
//  Pike
//
//  Axis-aligned bounding box for spatial queries.
//

import Foundation

struct BoundingBox {
    let minLat: Double
    let maxLat: Double
    let minLon: Double
    let maxLon: Double

    static func around(lat: Double, lon: Double, radiusMeters: Double) -> BoundingBox {
        let latDelta = radiusMeters / 111_000
        let lonDelta = radiusMeters / (111_000 * cos(lat.degreesToRadians))
        return BoundingBox(
            minLat: lat - latDelta,
            maxLat: lat + latDelta,
            minLon: lon - lonDelta,
            maxLon: lon + lonDelta
        )
    }
}
