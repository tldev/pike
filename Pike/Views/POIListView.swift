//
//  POIListView.swift
//  Pike
//
//  Full-screen sheet showing all POIs across upcoming exits with filtering
//

import SwiftUI
import UIKit

struct POIListView: View {
    let exitCards: [ExitCard]
    let onPOISelected: (POI) -> Void
    let onNearEnd: (Int, Int) -> Void
    private let filterStore = POIListFilterStore()

    @Environment(\.dismiss) private var dismiss

    @State private var filter: POIListFilter
    @State private var listTableView: UITableView?

    init(
        exitCards: [ExitCard],
        onPOISelected: @escaping (POI) -> Void,
        onNearEnd: @escaping (Int, Int) -> Void
    ) {
        self.exitCards = exitCards
        self.onPOISelected = onPOISelected
        self.onNearEnd = onNearEnd
        _filter = State(initialValue: filterStore.load())
    }

    /// Exit cards that have at least one POI matching the current filter.
    private var filteredCards: [(card: ExitCard, pois: [POI])] {
        exitCards.compactMap { card in
            let matching = card.allPOIs.filter { filter.matches($0) }
            guard !matching.isEmpty else { return nil }
            return (card, POISorter.byEstimatedDriveTime(matching))
        }
    }

    private var filteredCardIds: [String] {
        filteredCards.map(\.card.id)
    }

    var body: some View {
        NavigationStack {
            Group {
                if filteredCards.isEmpty {
                    emptyState
                } else {
                    poiList
                }
            }
            .safeAreaInset(edge: .top) {
                POIFilterBar(filter: $filter)
            }
            .navigationTitle("Points of Interest")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: filter) {
                filterStore.save(filter)
            }
            .transaction { $0.disablesAnimations = true }
        }
    }

    // MARK: - POI List

    private var poiList: some View {
        List {
            ForEach(Array(filteredCards.enumerated()), id: \.element.card.id) { index, item in
                Section {
                    ForEach(item.pois) { poi in
                        Button {
                            onPOISelected(poi)
                        } label: {
                            POIRowView(poi: poi)
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets())
                    }
                } header: {
                    exitSectionHeader(card: item.card)
                        .onAppear {
                            onNearEnd(index, filteredCards.count)
                        }
                }
            }

            // Keep pagination progressing even when newly fetched exits do not
            // match the current POI filter (for example, dog parks only).
            Color.clear
                .frame(height: 1)
                .listRowSeparator(.hidden)
                .onAppear {
                    guard !filteredCards.isEmpty else { return }
                    onNearEnd(max(filteredCards.count - 1, 0), filteredCards.count)
                }
                .onChange(of: exitCards.count) {
                    // Re-trigger pagination when new exits were fetched but none matched
                    // the filter. The sentinel is already visible so onAppear won't re-fire.
                    guard !filteredCards.isEmpty else { return }
                    onNearEnd(max(filteredCards.count - 1, 0), filteredCards.count)
                }
                .id("poi-list-end-\(filteredCards.count)")
        }
        .listStyle(.insetGrouped)
        .background(
            TableViewResolver { tableView in
                listTableView = tableView
            }
        )
        .onChange(of: filteredCardIds) { oldIds, newIds in
            preserveScrollDepthIfNeeded(oldIds: oldIds, newIds: newIds)
        }
    }

    private func preserveScrollDepthIfNeeded(oldIds: [String], newIds: [String]) {
        guard oldIds != newIds,
              !oldIds.isEmpty,
              !newIds.isEmpty,
              let tableView = listTableView,
              tableView.window != nil else {
            return
        }

        let topLimit = -tableView.adjustedContentInset.top + 20
        guard tableView.contentOffset.y > topLimit else { return }

        guard let anchorId = oldIds.first(where: { newIds.contains($0) }),
              let oldAnchorIndex = oldIds.firstIndex(of: anchorId),
              let newAnchorIndex = newIds.firstIndex(of: anchorId) else {
            return
        }

        let removedHeightAboveAnchor = sumSectionHeights(
            sectionRange: 0..<oldAnchorIndex,
            tableView: tableView
        )

        DispatchQueue.main.async {
            guard tableView.window != nil else { return }

            tableView.layoutIfNeeded()
            let insertedHeightAboveAnchor = sumSectionHeights(
                sectionRange: 0..<newAnchorIndex,
                tableView: tableView
            )

            let deltaY = insertedHeightAboveAnchor - removedHeightAboveAnchor
            guard abs(deltaY) > 0.5 else { return }

            let minOffsetY = -tableView.adjustedContentInset.top
            let maxOffsetY = max(
                minOffsetY,
                tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom
            )
            let targetY = min(max(tableView.contentOffset.y + deltaY, minOffsetY), maxOffsetY)
            tableView.setContentOffset(
                CGPoint(x: tableView.contentOffset.x, y: targetY),
                animated: false
            )
        }
    }

    private func sumSectionHeights(
        sectionRange: Range<Int>,
        tableView: UITableView
    ) -> CGFloat {
        guard !sectionRange.isEmpty else { return 0 }
        let upper = min(sectionRange.upperBound, tableView.numberOfSections)
        guard sectionRange.lowerBound < upper else { return 0 }
        return (sectionRange.lowerBound..<upper).reduce(CGFloat.zero) { partial, index in
            partial + tableView.rect(forSection: index).height
        }
    }

    // MARK: - Exit Section Header

    private func exitSectionHeader(card: ExitCard) -> some View {
        HStack(spacing: 6) {
            Text(card.exit.shortTitle)
                .font(.system(size: 14, weight: .bold))

            if let name = card.exit.name {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(card.exit.distanceText)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))

            if let timeText = card.exit.timeText {
                Text("·")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(timeText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No matching POIs")
                .font(.headline)
            Text("Try adjusting your filters")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TableViewResolver: UIViewRepresentable {
    let onResolve: (UITableView) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            guard let tableView = uiView.closestAncestor(of: UITableView.self) else { return }
            onResolve(tableView)
        }
    }
}

private extension UIView {
    func closestAncestor<T: UIView>(of type: T.Type) -> T? {
        var current: UIView? = self
        while let view = current {
            if let typed = view as? T {
                return typed
            }
            current = view.superview
        }
        return nil
    }
}
