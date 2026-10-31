import Foundation
import SwiftUI

/// Categories of points of interest.
enum POICategory: String, CaseIterable, Identifiable, Codable {
    case gas
    case food
    case lodging
    case evCharging
    case restStop
    case restroom
    case park
    case dogPark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gas: return "Gas"
        case .food: return "Food"
        case .lodging: return "Lodging"
        case .evCharging: return "EV Charging"
        case .restStop: return "Rest Stop"
        case .restroom: return "Restroom"
        case .park: return "Park"
        case .dogPark: return "Dog Park"
        }
    }

    var systemImage: String {
        switch self {
        case .gas: return "fuelpump.fill"
        case .food: return "fork.knife"
        case .lodging: return "bed.double.fill"
        case .evCharging: return "bolt.car.fill"
        case .restStop: return "parkingsign.circle.fill"
        case .restroom: return "figure.dress.line.vertical.figure"
        case .park: return "tree.fill"
        case .dogPark: return "dog.fill"
        }
    }

    var color: Color {
        switch self {
        case .gas: return .orange
        case .food: return .red
        case .lodging: return .purple
        case .evCharging: return .teal
        case .restStop: return .green
        case .restroom: return .blue
        case .park: return .green
        case .dogPark: return .brown
        }
    }

    /// Initialize from the category string stored in the SQLite data pack.
    /// Returns nil for unrecognized strings.
    init?(dbString: String) {
        switch dbString {
        case "gas": self = .gas
        case "food": self = .food
        case "lodging": self = .lodging
        case "restArea": self = .restStop
        case "restroom": self = .restroom
        case "evCharging": self = .evCharging
        case "park": self = .park
        case "dogPark": self = .dogPark
        default: return nil
        }
    }
}
