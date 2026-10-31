//
//  ExitCardView.swift
//  Pike
//
//  Visual representation of a single exit "logo sign" card
//

import SwiftUI
import UIKit

/// Displays an exit card mimicking interstate logo signs
struct ExitCardView: View, Equatable {
    let card: ExitCard
    let categoryVisibility: ExitCardCategoryVisibility
    let onPOITapped: (POI) -> Void
    let onExitTapped: () -> Void

    private let signBlue = BrandHelpers.signBlue
    private let signGreen = BrandHelpers.signGreen
    private let restAreaGreen = Color(red: 45.0/255, green: 90.0/255, blue: 61.0/255)

    static func == (lhs: ExitCardView, rhs: ExitCardView) -> Bool {
        lhs.card == rhs.card && lhs.categoryVisibility == rhs.categoryVisibility
    }

    private struct ServiceRowModel: Identifiable {
        let category: ExitCardServiceCategory
        let pois: [POI]

        var id: ExitCardServiceCategory { category }
    }

    private var visibleServiceRows: [ServiceRowModel] {
        let enabled = categoryVisibility.enabledCategories
        return ExitCardServiceCategory.displayOrder.compactMap { category in
            // Parks row shows when either .parks or .dogParks is enabled.
            let rowVisible = category == .parks
                ? enabled.contains(.parks) || enabled.contains(.dogParks)
                : enabled.contains(category)
            guard rowVisible else { return nil }
            let pois = card.servicePOIs(for: category, visibleCategories: enabled)
            guard !pois.isEmpty else { return nil }
            return ServiceRowModel(category: category, pois: pois)
        }
    }

    private var visibleServiceRowCategories: Set<ExitCardServiceCategory> {
        Set(visibleServiceRows.map(\.category))
    }

    private var shouldUseRestAreaCard: Bool {
        card.isRestAreaOnly && categoryVisibility.isEnabled(.restAreas)
    }

    var body: some View {
        Group {
            if shouldUseRestAreaCard {
                restAreaCard
            } else {
                standardCard
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(.white, lineWidth: 4)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if shouldUseRestAreaCard, let poi = card.restAreaPOIs.first ?? card.restroomPOIs.first {
                onPOITapped(poi)
            } else {
                onExitTapped()
            }
        }
        .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
    }

    // MARK: - Standard Card

    private var standardCard: some View {
        VStack(spacing: 0) {
            exitHeader
            Color.clear.frame(height: 1)

            serviceRows

            signBlue.frame(height: 3)
        }
    }

    // MARK: - Rest Area Card

    private var restAreaCard: some View {
        ZStack(alignment: .bottom) {
            restAreaGreen.overlay(
                Image("rest_area_scene")
                    .resizable()
                    .scaledToFill()
                    .opacity(0.15)
            )
            .clipped()

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(card.exit.distanceText)
                            .font(.system(size: 28, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                        if let timeText = card.exit.timeText {
                            Text(timeText)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }

                    Spacer()

                    restAreaSignBadge
                }
                .padding(.top, 14)
                .padding(.leading, 16)
                .padding(.trailing, 16)

                Spacer()

                VStack(alignment: .leading, spacing: 0) {
                    if let name = card.restAreaDisplayName {
                        Text(name)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
        }
        .frame(height: ExitCard.restAreaCardHeight)
    }

    /// FHWA rest area highway sign badge.
    private var restAreaSignBadge: some View {
        Image("rest_area_sign")
            .resizable()
            .scaledToFit()
            .frame(height: 80)
    }

    // MARK: - Exit Header

    private var exitHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(card.exit.shortTitle)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                if let name = card.exit.name {
                    Text(name)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(1)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(card.exit.distanceText)
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)

                if let timeText = card.exit.timeText {
                    Text(timeText)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(signGreen)
    }

    // MARK: - Service Rows

    private var serviceRows: some View {
        VStack(spacing: 1) {
            let shownCategories = visibleServiceRowCategories
            ForEach(visibleServiceRows) { row in
                serviceRow(
                    systemIcon: rowSystemIcon(for: row.category),
                    pois: row.pois,
                    maxBadgeRowsPerCategory: ExitCard.maxBadgeRowsPerCategory(
                        for: row.category,
                        shownCategories: shownCategories
                    )
                )
            }
        }
    }

    private func rowSystemIcon(for category: ExitCardServiceCategory) -> String {
        switch category {
        case .restAreas:
            return "parkingsign"
        default:
            return category.systemImage
        }
    }

    private func serviceRow(
        systemIcon: String,
        pois: [POI],
        maxBadgeRowsPerCategory: Int
    ) -> some View {
        let branded = pois.filter { !BrandHelpers.genericPOINames.contains($0.name) }
        let visible = Array(
            branded.prefix(
                ExitCard.maxBrandedBadgesPerCategory(
                    maxBadgeRowsPerCategory: maxBadgeRowsPerCategory
                )
            )
        )
        let firstRow = Array(visible.prefix(ExitCard.serviceBadgeColumns))
        let additionalRows: [[POI]] = stride(
            from: ExitCard.serviceBadgeColumns,
            to: visible.count,
            by: ExitCard.serviceBadgeColumns
        ).map { start in
            let end = min(start + ExitCard.serviceBadgeColumns, visible.count)
            return Array(visible[start..<end])
        }
        let genericCount = pois.count - branded.count
        let showCount = genericCount > 0 && firstRow.count < ExitCard.serviceBadgeColumns

        return VStack(spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: systemIcon)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 30)

                badgeRow(pois: firstRow, genericCount: showCount ? genericCount : 0)
            }

            ForEach(Array(additionalRows.enumerated()), id: \.offset) { _, rowPOIs in
                badgeRow(pois: rowPOIs, genericCount: 0)
                    .padding(.leading, 40) // 30 icon width + 10 spacing
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(signBlue)
    }

    private func badgeRow(pois: [POI], genericCount: Int) -> some View {
        let filledSlots = pois.count + (genericCount > 0 ? 1 : 0)

        return HStack(spacing: 8) {
            ForEach(pois, id: \.id) { poi in
                brandBadge(for: poi)
                    .onTapGesture { onPOITapped(poi) }
            }

            if genericCount > 0 {
                Text("+\(genericCount)")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
            }

            if filledSlots < ExitCard.serviceBadgeColumns {
                ForEach(0..<(ExitCard.serviceBadgeColumns - filledSlots), id: \.self) { _ in
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                }
            }
        }
    }

    private func brandBadge(for poi: POI) -> some View {
        let fallback = BrandHelpers.shortenBrandName(poi.name)
        let assetName = BrandHelpers.assetName(for: poi.name)
        let image = UIImage(named: assetName)

        return Group {
            if let parkIcon = parkIconName(for: poi) {
                Image(systemName: parkIcon)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(poi.category == .dogPark ? .brown : .green)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel(poi.name)
            } else if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel(poi.name)
            } else {
                Text(fallback)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(signBlue)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel(poi.name)
            }
        }
    }

    private func parkIconName(for poi: POI) -> String? {
        switch poi.category {
        case .park: return "tree.fill"
        case .dogPark: return "dog.fill"
        default: return nil
        }
    }
}
