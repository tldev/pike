import Foundation

enum ExitCardServiceCategory: Int, CaseIterable, Identifiable {
    case gas
    case food
    case lodging
    case evCharging
    case restAreas
    case parks
    case dogParks

    var id: Int { rawValue }

    /// Row order on exit cards. Dog parks fold into the parks row (not a separate row).
    static let displayOrder: [ExitCardServiceCategory] = [
        .food,
        .gas,
        .restAreas,
        .parks,
        .lodging,
        .evCharging
    ]

    /// Toggle order in Settings — parks and dog parks get separate toggles.
    static let settingsOrder: [ExitCardServiceCategory] = [
        .food,
        .gas,
        .restAreas,
        .parks,
        .dogParks,
        .lodging,
        .evCharging
    ]

    var displayName: String {
        switch self {
        case .gas: return "Gas"
        case .food: return "Food"
        case .lodging: return "Lodging"
        case .evCharging: return "EV Charging"
        case .restAreas: return "Rest Areas"
        case .parks: return "Parks"
        case .dogParks: return "Dog Parks"
        }
    }

    var systemImage: String {
        switch self {
        case .gas: return "fuelpump.fill"
        case .food: return "fork.knife"
        case .lodging: return "bed.double.fill"
        case .evCharging: return "bolt.car.fill"
        case .restAreas: return "parkingsign.circle.fill"
        case .parks: return "tree.fill"
        case .dogParks: return "dog.fill"
        }
    }
}

struct ExitCardCategoryVisibility: Equatable {
    static let storageKey = "exitCardCategoryVisibilityMask"

    /// Categories disabled by default (user must opt in via Settings).
    private static let defaultDisabledCategories: Set<ExitCardServiceCategory> = [.parks, .dogParks]

    /// Bitmask with every known category enabled.
    static let fullMask: Int = ExitCardServiceCategory.allCases.reduce(0) { partial, category in
        partial | bit(for: category)
    }

    /// Bitmask for new installs — all categories except `defaultDisabledCategories`.
    static let defaultMask: Int = ExitCardServiceCategory.allCases.reduce(0) { partial, category in
        defaultDisabledCategories.contains(category) ? partial : partial | bit(for: category)
    }

    private(set) var mask: Int

    init(mask: Int = defaultMask) {
        let normalized = mask & Self.fullMask
        self.mask = normalized == 0 ? Self.defaultMask : normalized
    }

    var enabledCategories: Set<ExitCardServiceCategory> {
        Set(ExitCardServiceCategory.allCases.filter { isEnabled($0) })
    }

    var isAllEnabled: Bool {
        mask == Self.fullMask
    }

    func isEnabled(_ category: ExitCardServiceCategory) -> Bool {
        mask & Self.bit(for: category) != 0
    }

    mutating func set(_ category: ExitCardServiceCategory, enabled: Bool) {
        if enabled {
            mask |= Self.bit(for: category)
            return
        }

        let proposedMask = mask & ~Self.bit(for: category)
        if proposedMask != 0 {
            mask = proposedMask
        }
    }

    mutating func enableAll() {
        mask = Self.fullMask
    }

    private static func bit(for category: ExitCardServiceCategory) -> Int {
        1 << category.rawValue
    }
}
