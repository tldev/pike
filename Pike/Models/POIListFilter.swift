//
//  POIListFilter.swift
//  Pike
//
//  Filter state for the POI list view
//

import Foundation

struct POIListFilter: Codable, Equatable {
    /// Parks and dog parks disabled by default — matches ExitCardCategoryVisibility defaults.
    static let defaultDisabledCategories: Set<POICategory> = [.park, .dogPark]
    static let defaultEnabledCategories: Set<POICategory> = Set(POICategory.allCases)
        .subtracting(defaultDisabledCategories)

    var enabledCategories: Set<POICategory> = defaultEnabledCategories

    /// Whether a POI passes the current filters.
    func matches(_ poi: POI) -> Bool {
        // Treat restStop and restroom as a merged "Rest Areas" toggle
        switch poi.category {
        case .restStop, .restroom:
            return enabledCategories.contains(.restStop) || enabledCategories.contains(.restroom)
        default:
            return enabledCategories.contains(poi.category)
        }
    }
}

/// Persistence wrapper for `POIListFilter`.
struct POIListFilterStore {
    let defaults: UserDefaults
    let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "poiListFilter"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    func load() -> POIListFilter {
        guard
            let data = defaults.data(forKey: storageKey),
            let saved = try? JSONDecoder().decode(POIListFilter.self, from: data)
        else {
            return POIListFilter()
        }
        return saved
    }

    func save(_ filter: POIListFilter) {
        guard let data = try? JSONEncoder().encode(filter) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
