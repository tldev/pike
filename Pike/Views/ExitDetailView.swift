//
//  ExitDetailView.swift
//  Pike
//
//  Full detail sheet for an exit — shows all POIs grouped by category
//

import SwiftUI

/// Sheet showing every POI at an exit, grouped by category.
struct ExitDetailView: View {
    let card: ExitCard
    let onPOISelected: (POI) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    header
                        .padding(.bottom, 16)

                    categorySections
                }
                .padding()
            }
            .navigationTitle(card.exit.shortTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let name = card.exit.name {
                Text(name)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text(card.exit.distanceText)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))

                if let timeText = card.exit.timeText {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(timeText)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Category Sections

    private var categorySections: some View {
        VStack(spacing: 20) {
            ForEach(ExitCardServiceCategory.displayOrder) { category in
                categorySection(
                    systemIcon: detailSystemIcon(for: category),
                    label: category.displayName,
                    pois: card.servicePOIs(for: category)
                )
            }
        }
    }

    private func detailSystemIcon(for category: ExitCardServiceCategory) -> String {
        switch category {
        case .restAreas:
            return "parkingsign"
        default:
            return category.systemImage
        }
    }

    @ViewBuilder
    private func categorySection(
        systemIcon: String,
        label: String,
        pois: [POI]
    ) -> some View {
        if !pois.isEmpty {
            let sortedPOIs = POISorter.byEstimatedDriveTime(pois)
            VStack(alignment: .leading, spacing: 8) {
                // Section header
                HStack(spacing: 8) {
                    Image(systemName: systemIcon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(BrandHelpers.signBlue)
                        .frame(width: 24)

                    Text(label)
                        .font(.system(size: 15, weight: .semibold))

                    Spacer()

                    Text("\(sortedPOIs.count)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                // POI rows
                VStack(spacing: 0) {
                    ForEach(Array(sortedPOIs.enumerated()), id: \.element.id) { index, poi in
                        Button {
                            onPOISelected(poi)
                        } label: {
                            POIRowView(poi: poi)
                        }
                        .buttonStyle(.plain)

                        if index < sortedPOIs.count - 1 {
                            Divider()
                                .padding(.leading, 60)
                        }
                    }
                }
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}
