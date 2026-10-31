import Foundation
import SwiftUI

/// Shared brand name and theme helpers used by exit sign views.
enum BrandHelpers {

    // MARK: - Sign Colors

    /// Interstate logo sign blue (FHWA Pantone 294 — #003F87).
    static let signBlue = Color(red: 0.0, green: 63.0 / 255.0, blue: 135.0 / 255.0)

    /// Highway sign green.
    static let signGreen = Color(red: 0.0, green: 0.45, blue: 0.25)

    /// Generic/unknown POI names that shouldn't get brand badges.
    static let genericPOINames: Set<String> = [
        "Unknown", "Gas Station", "Restaurant", "Hotel", "Restroom",
        "Rest Area", "EV Charger"
    ]

    /// Normalize a POI name into an asset catalog key.
    /// Convention: `brand_<normalized_key>` (lowercase, no accents, spaces to underscores, strip apostrophes).
    static func assetName(for poiName: String) -> String {
        "brand_\(brandKey(from: poiName))"
    }

    /// Shorten a brand name for display in the exit card badge.
    static func shortenBrandName(_ name: String) -> String {
        let shortened: [String: String] = [
            "McDonald's": "McD's",
            "Burger King": "BK",
            "Wendy's": "Wendy's",
            "Taco Bell": "Taco Bell",
            "Chick-fil-A": "CFA",
            "Starbucks": "Starbux",
            "QuikTrip": "QT",
            "Pilot Travel Center": "Pilot",
            "Love's Travel Stop": "Love's",
            "Flying J": "Flying J"
        ]

        for (brand, short) in shortened {
            if name.localizedCaseInsensitiveContains(brand) {
                return short
            }
        }

        if name.count > 10 {
            return String(name.prefix(8)) + "…"
        }
        return name
    }

    /// Brand aliases: map variant keys to a canonical asset key.
    /// Avoids needing duplicate imagesets for "loves_travel_stop", "loves_gas_trucks", etc.
    private static let brandAliases: [String: String] = [
        "loves_travel_stop": "loves",
        "loves_gas_trucks": "loves",
    ]

    /// Normalize a raw POI name to a brand key suitable for asset lookup.
    static func brandKey(from raw: String) -> String {
        let lower = raw.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US")).lowercased()
        let replaced = lower
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " "))
        let cleaned = String(replaced.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " })

        let parts = cleaned
            .split(separator: " ")
            .map { String($0) }
            .filter { !$0.isEmpty }

        let normalized = parts.joined(separator: "_")
        let key = normalized.isEmpty ? "unknown" : normalized
        return brandAliases[key] ?? key
    }
}
