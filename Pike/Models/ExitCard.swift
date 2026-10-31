//
//  ExitCard.swift
//  Pike
//
//  UI model representing an exit "logo sign" card with grouped POIs
//

import Foundation
import CoreGraphics

/// Represents a single exit card (mimics interstate logo signs)
/// Groups all POIs accessible from a specific exit
struct ExitCard: Identifiable, Equatable {
    let id: String
    var exit: Exit

    // POIs grouped by category (like logo sign rows)
    var gasPOIs: [POI] = []
    var foodPOIs: [POI] = []
    var lodgingPOIs: [POI] = []
    var evChargingPOIs: [POI] = []
    var restAreaPOIs: [POI] = []      // Rest stops at this exit
    var restroomPOIs: [POI] = []
    var parkPOIs: [POI] = []
    var dogParkPOIs: [POI] = []

    // MARK: - Initialization

    init(exit: Exit) {
        self.id = exit.id
        self.exit = exit
    }

    // MARK: - Computed Properties

    /// All POIs at this exit, flattened
    var allPOIs: [POI] {
        gasPOIs + foodPOIs + lodgingPOIs + evChargingPOIs + restAreaPOIs + restroomPOIs + parkPOIs + dogParkPOIs
    }

    /// Whether this exit has any services
    var hasServices: Bool {
        !allPOIs.isEmpty
    }

    /// True when this exit has only rest area / restroom POIs (no gas, food, lodging, or EV).
    var isRestAreaOnly: Bool {
        gasPOIs.isEmpty && foodPOIs.isEmpty && lodgingPOIs.isEmpty && evChargingPOIs.isEmpty
            && parkPOIs.isEmpty && dogParkPOIs.isEmpty
            && (!restAreaPOIs.isEmpty || !restroomPOIs.isEmpty)
    }

    /// Best non-generic display name from the rest area POIs, or the exit name itself.
    /// Strips directional suffixes like "Westbound" / "Eastbound".
    var restAreaDisplayName: String? {
        var raw: String?
        // Prefer the exit's own name (e.g. "Alachua County Rest Area")
        if let name = exit.name, !name.isEmpty {
            raw = name
        } else {
            // Fall back to a non-generic rest area POI name
            raw = restAreaPOIs.first(where: { !BrandHelpers.genericPOINames.contains($0.name) })?.name
        }
        guard var result = raw else { return nil }
        // Strip directional suffixes in various formats:
        // "... Westbound", "... (I-75 southbound)", "... - I90 EB", "... North", "... South"
        // Remove parenthesized directional info like "(I-75 northbound)" or "(Northbound)"
        result = result.replacingOccurrences(
            of: #"\s*\(.*?\b(?:north|south|east|west)bound\)"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        // Remove trailing " - I90 EB" / ", I-90 Westbound" style suffixes
        result = result.replacingOccurrences(
            of: #"\s*[,\-–]\s*I-?\d+\s*(?:EB|WB|NB|SB|Eastbound|Westbound|Northbound|Southbound)$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        // Remove trailing bare directional words
        result = result.replacingOccurrences(
            of: #"\s+(?:Westbound|Eastbound|Northbound|Southbound|West\s*Bound|East\s*Bound|North|South|NB|SB|EB|WB)$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        result = result.trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? nil : result
    }
}

// MARK: - Layout Metrics

extension ExitCard {
    static let restAreaCardHeight: CGFloat = 220
    static let emptyCarouselHeight: CGFloat = 220
    static let serviceBadgeColumns = 3
    static let defaultMaxBadgeRowsPerCategory = 2
    static let restAreasMaxBadgeRows = 1

    private static let headerHeightWithName: CGFloat = 92
    private static let headerHeightWithoutName: CGFloat = 85
    private static let serviceRowVerticalPadding: CGFloat = 6
    private static let serviceBadgeRowHeight: CGFloat = 52
    private static let serviceRowContentSpacing: CGFloat = 6
    private static let headerToBodyDividerHeight: CGFloat = 1
    private static let serviceRowSeparatorHeight: CGFloat = 1
    private static let bottomBalancePadding: CGFloat = 6

    private static let allServiceCategories = Set(ExitCardServiceCategory.allCases)

    func servicePOIs(for category: ExitCardServiceCategory) -> [POI] {
        servicePOIs(for: category, visibleCategories: Self.allServiceCategories)
    }

    /// Returns POIs for a category, respecting visibility.
    /// The `.parks` row on the exit card combines parks + dog parks; which sub-categories
    /// appear depends on whether `.parks` and/or `.dogParks` are individually enabled.
    func servicePOIs(
        for category: ExitCardServiceCategory,
        visibleCategories: Set<ExitCardServiceCategory>
    ) -> [POI] {
        switch category {
        case .gas:
            return gasPOIs
        case .food:
            return foodPOIs
        case .lodging:
            return lodgingPOIs
        case .evCharging:
            return evChargingPOIs
        case .restAreas:
            return restAreaPOIs + restroomPOIs
        case .parks:
            var result: [POI] = []
            if visibleCategories.contains(.parks) { result += parkPOIs }
            if visibleCategories.contains(.dogParks) { result += dogParkPOIs }
            return result
        case .dogParks:
            return dogParkPOIs
        }
    }

    /// Categories displayed as rows in `ExitCardView`, in render order.
    func displayedServiceCategories(
        visibleCategories: Set<ExitCardServiceCategory>
    ) -> [[POI]] {
        ExitCardServiceCategory.displayOrder.compactMap { category in
            // Parks row shows when either .parks or .dogParks is enabled.
            let rowVisible = category == .parks
                ? visibleCategories.contains(.parks) || visibleCategories.contains(.dogParks)
                : visibleCategories.contains(category)
            guard rowVisible else { return nil }
            let pois = servicePOIs(for: category, visibleCategories: visibleCategories)
            return pois.isEmpty ? nil : pois
        }
    }

    /// Height estimate used by carousel layout so all cards share a stable max height.
    func estimatedCardHeight(
        visibleCategories: Set<ExitCardServiceCategory>
    ) -> CGFloat {
        if isRestAreaOnly && visibleCategories.contains(.restAreas) {
            return Self.restAreaCardHeight
        }

        let headerHeight = exit.name != nil ? Self.headerHeightWithName : Self.headerHeightWithoutName
        let shownCategories = shownServiceCategories(visibleCategories: visibleCategories)

        let rowsHeight = ExitCardServiceCategory.displayOrder.reduce(CGFloat.zero) { partial, category in
            guard shownCategories.contains(category) else { return partial }
            let pois = servicePOIs(for: category, visibleCategories: visibleCategories)

            let rowCap = Self.maxBadgeRowsPerCategory(
                for: category,
                shownCategories: shownCategories
            )

            return partial + Self.heightForServiceRow(
                pois: pois,
                maxBadgeRowsPerCategory: rowCap
            )
        }
        let separatorsHeight = CGFloat(max(0, shownCategories.count - 1)) * Self.serviceRowSeparatorHeight

        return headerHeight + Self.headerToBodyDividerHeight + rowsHeight + separatorsHeight + Self.bottomBalancePadding
    }

    private func shownServiceCategories(
        visibleCategories: Set<ExitCardServiceCategory>
    ) -> Set<ExitCardServiceCategory> {
        Set(
            ExitCardServiceCategory.displayOrder.filter { category in
                let rowVisible = category == .parks
                    ? visibleCategories.contains(.parks) || visibleCategories.contains(.dogParks)
                    : visibleCategories.contains(category)
                return rowVisible && !servicePOIs(for: category, visibleCategories: visibleCategories).isEmpty
            }
        )
    }

    static func maxBadgeRowsPerNonRestCategory(
        forEnabledNonRestCategoryCount count: Int
    ) -> Int {
        switch count {
        case 1:
            return 6
        case 2:
            return 3
        default:
            return defaultMaxBadgeRowsPerCategory
        }
    }

    static func maxBadgeRowsPerCategory(
        for category: ExitCardServiceCategory,
        shownCategories: Set<ExitCardServiceCategory>
    ) -> Int {
        if category == .restAreas {
            return restAreasMaxBadgeRows
        }

        let shownNonRestCount = shownCategories.subtracting([.restAreas]).count
        return maxBadgeRowsPerNonRestCategory(
            forEnabledNonRestCategoryCount: shownNonRestCount
        )
    }

    static func maxBrandedBadgesPerCategory(maxBadgeRowsPerCategory: Int) -> Int {
        serviceBadgeColumns * max(1, maxBadgeRowsPerCategory)
    }

    static func visibleBrandedPOIs(
        from pois: [POI],
        maxBadgeRowsPerCategory: Int = defaultMaxBadgeRowsPerCategory
    ) -> [POI] {
        Array(
            pois
                .filter { !BrandHelpers.genericPOINames.contains($0.name) }
                .prefix(maxBrandedBadgesPerCategory(maxBadgeRowsPerCategory: maxBadgeRowsPerCategory))
        )
    }

    private static func heightForServiceRow(
        pois: [POI],
        maxBadgeRowsPerCategory: Int
    ) -> CGFloat {
        let brandedCount = visibleBrandedPOIs(
            from: pois,
            maxBadgeRowsPerCategory: maxBadgeRowsPerCategory
        ).count
        let requiredRows = Int(ceil(Double(brandedCount) / Double(serviceBadgeColumns)))
        let displayedRows = max(1, requiredRows)

        let contentHeight = CGFloat(displayedRows) * serviceBadgeRowHeight
        let contentSpacing = CGFloat(max(0, displayedRows - 1)) * serviceRowContentSpacing
        return (serviceRowVerticalPadding * 2) + contentHeight + contentSpacing
    }
}
