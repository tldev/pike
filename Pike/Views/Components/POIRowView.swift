//
//  POIRowView.swift
//  Pike
//
//  Shared POI row component used by ExitDetailView and POIListView
//

import SwiftUI
import CoreLocation
import UIKit

/// A single POI row with brand badge, name, and distance.
struct POIRowView: View {
    let poi: POI

    private let signBlue = BrandHelpers.signBlue

    var body: some View {
        HStack(spacing: 12) {
            brandBadge

            VStack(alignment: .leading, spacing: 2) {
                Text(poi.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let distance = poi.estimatedDriveDistanceFromExit ?? poi.distanceFromExit {
                    Text(Self.formatDistance(distance))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    // MARK: - Brand Badge

    private var brandBadge: some View {
        let isGeneric = BrandHelpers.genericPOINames.contains(poi.name)
        let assetName = isGeneric ? nil : BrandHelpers.assetName(for: poi.name)
        let image = assetName.flatMap { UIImage(named: $0) }

        return Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 48, height: 34)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel(poi.name)
            } else {
                Image(systemName: poi.category.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(signBlue)
                    .frame(width: 48, height: 34)
                    .accessibilityLabel(poi.name)
            }
        }
    }

    // MARK: - Helpers

    static func formatDistance(_ meters: CLLocationDistance) -> String {
        let feet = meters * 3.28084
        let quarterMileFeet: Double = 1320

        if feet < 160 {
            return "Nearby"
        }

        if feet >= quarterMileFeet {
            let miles = meters / 1609.34
            let quarters = (miles * 4).rounded() / 4
            let whole = Int(quarters)
            let frac = quarters - Double(whole)

            let dist: String
            switch frac {
            case 0:    dist = "\(whole) mi"
            case 0.25: dist = whole > 0 ? "\(whole)¼ mi" : "¼ mi"
            case 0.5:  dist = whole > 0 ? "\(whole)½ mi" : "½ mi"
            default:   dist = whole > 0 ? "\(whole)¾ mi" : "¾ mi"
            }
            return "\(dist) from exit"
        }

        if feet >= 500 {
            let rounded = Int((feet / 50).rounded()) * 50
            return "\(rounded) ft from exit"
        } else {
            let rounded = Int((feet / 5).rounded()) * 5
            return "\(rounded) ft from exit"
        }
    }
}
