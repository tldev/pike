//
//  POIFilterBar.swift
//  Pike
//
//  Category toggle pills for filtering POIs
//

import SwiftUI

struct POIFilterBar: View {
    @Binding var filter: POIListFilter

    /// Display categories — merge restStop + restroom into one "Rest Areas" toggle.
    private struct FilterCategory: Identifiable {
        let id: String
        let label: String
        let icon: String
        let color: Color
        /// The POICategory values this toggle controls.
        let categories: Set<POICategory>
    }

    private let filterCategories: [FilterCategory] = [
        FilterCategory(id: "gas", label: "Gas", icon: "fuelpump.fill", color: .orange, categories: [.gas]),
        FilterCategory(id: "food", label: "Food", icon: "fork.knife", color: .red, categories: [.food]),
        FilterCategory(id: "lodging", label: "Lodging", icon: "bed.double.fill", color: .purple, categories: [.lodging]),
        FilterCategory(id: "ev", label: "EV", icon: "bolt.car.fill", color: .teal, categories: [.evCharging]),
        FilterCategory(id: "rest", label: "Rest Areas", icon: "parkingsign.circle.fill", color: .green, categories: [.restStop, .restroom]),
        FilterCategory(id: "parks", label: "Parks", icon: "tree.fill", color: .green, categories: [.park]),
        FilterCategory(id: "dogParks", label: "Dog Parks", icon: "dog.fill", color: .brown, categories: [.dogPark]),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(filterCategories) { cat in
                    let isActive = cat.categories.isSubset(of: filter.enabledCategories)
                    Button {
                        toggleCategory(cat)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: cat.icon)
                                .font(.system(size: 12, weight: .semibold))
                            Text(cat.label)
                                .font(.system(size: 13, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(isActive ? cat.color.opacity(0.15) : Color(.systemGray6))
                        .foregroundColor(isActive ? cat.color : .secondary)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .stroke(isActive ? cat.color.opacity(0.4) : Color(.systemGray4), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func toggleCategory(_ cat: FilterCategory) {
        let isActive = cat.categories.isSubset(of: filter.enabledCategories)
        if isActive {
            // Don't allow disabling the last active category
            let remaining = filter.enabledCategories.subtracting(cat.categories)
            if !remaining.isEmpty {
                filter.enabledCategories = remaining
            }
        } else {
            filter.enabledCategories.formUnion(cat.categories)
        }
    }
}
