//
//  Exit.swift
//  Pike
//
//  Highway exit model representing a discrete off-ramp decision point
//

import Foundation
import CoreLocation

/// Classification of noref (unnumbered) highway exits.
enum ExitKind {
    case numbered       // Normal exit with a ref number
    case restArea       // Rest area / service plaza ramp
    case welcomeCenter  // Welcome center / visitor info ramp
    case unnumbered     // Real exit with POIs, just no number
}

/// Represents a highway exit/junction
struct Exit: Identifiable, Equatable {
    let id: String
    let exitNumber: String          // "142", "142A", "142B"
    var name: String?               // "Main Street" / "Downtown"
    let coordinate: CLLocationCoordinate2D

    // Computed at search time
    var distanceFromUser: CLLocationDistance = 0
    var estimatedTimeToExit: TimeInterval = 0  // seconds at current speed
    var kind: ExitKind = .numbered

    // MARK: - Display Helpers

    var shortTitle: String {
        switch kind {
        case .numbered:     return "Exit \(exitNumber)"
        case .restArea:     return name ?? "Rest Area"
        case .welcomeCenter: return name ?? "Welcome Center"
        case .unnumbered:   return "Exit"
        }
    }

    /// Short label for the small map badge marker.
    var markerLabel: String {
        switch kind {
        case .numbered:     return exitNumber
        case .restArea:     return "Rest"
        case .welcomeCenter: return "Info"
        case .unnumbered:   return "Exit"
        }
    }

    /// MUTCD-style distance: ¼-mile fractions for miles, feet below ¼ mi.
    var distanceText: String {
        let feet = distanceFromUser * 3.28084
        let quarterMileFeet: Double = 1320

        if feet < 160 {
            return "Now"
        }

        if feet >= quarterMileFeet {
            let miles = distanceFromUser / 1609.34

            if miles >= 2 {
                // Round to whole miles above 2 mi
                return "\(Int(miles.rounded())) mi"
            }

            // MUTCD: fractions, not decimals, rounded to nearest ¼ mile
            let quarters = (miles * 4).rounded() / 4
            let whole = Int(quarters)
            let frac = quarters - Double(whole)

            switch frac {
            case 0:    return "\(whole) mi"
            case 0.25: return whole > 0 ? "\(whole)¼ mi" : "¼ mi"
            case 0.5:  return whole > 0 ? "\(whole)½ mi" : "½ mi"
            default:   return whole > 0 ? "\(whole)¾ mi" : "¾ mi"
            }
        }

        // Under ¼ mile: show in feet
        if feet >= 500 {
            let rounded = Int((feet / 50).rounded()) * 50
            return "\(rounded) ft"
        } else {
            let rounded = Int((feet / 5).rounded()) * 5
            return "\(rounded) ft"
        }
    }

    var timeText: String? {
        guard estimatedTimeToExit > 0 else { return nil }
        let minutes = Int(estimatedTimeToExit / 60)
        if minutes < 1 {
            return "< 1 min"
        }
        return "\(minutes) min"
    }

    // MARK: - Equatable

    static func == (lhs: Exit, rhs: Exit) -> Bool {
        lhs.id == rhs.id
    }
}

