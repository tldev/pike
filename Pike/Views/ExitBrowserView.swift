//
//  ExitBrowserView.swift
//  Pike
//
//  Swipeable exit card browser - the main "logo sign" browsing experience
//

import SwiftUI

enum ExitBrowserLogic {
    static func visibleCardIndices(
        total: Int,
        currentIndex: Int,
        visibleWindow: Int
    ) -> [Int] {
        guard total > 0 else { return [] }
        let clampedIndex = clampedCurrentIndex(currentIndex: currentIndex, total: total)
        let window = max(0, visibleWindow)
        let lower = max(0, clampedIndex - window)
        let upper = min(total - 1, clampedIndex + window)
        guard lower <= upper else { return [] }
        return Array(lower...upper)
    }

    static func boundedDragOffset(
        translation: CGFloat,
        currentIndex: Int,
        totalCards: Int
    ) -> CGFloat {
        let atFirst = currentIndex == 0 && translation > 0
        let atLast = currentIndex == totalCards - 1 && translation < 0
        return (atFirst || atLast) ? translation * 0.32 : translation
    }

    static func clampedCurrentIndex(currentIndex: Int, total: Int) -> Int {
        guard total > 0 else { return 0 }
        return min(max(0, currentIndex), total - 1)
    }

    static func indicatorPageIndices(total: Int, currentIndex: Int) -> [Int] {
        guard total > 0 else { return [] }
        if total <= 3 {
            return Array(0..<total)
        }

        if currentIndex == 0 {
            return [0, 1, 2]
        }
        if currentIndex == total - 1 {
            return [total - 3, total - 2, total - 1]
        }

        return [currentIndex - 1, currentIndex, currentIndex + 1]
    }
}

/// Main view for browsing exits via swipeable cards
struct ExitBrowserView: View {
    @ObservedObject var exitService: ExitService
    @EnvironmentObject var testDrivePlayer: TestDrivePlayer
    @Binding var selectedPOI: POI?
    @Binding var focusedExitCard: ExitCard?
    let onTakeTestDrive: () -> Void
    @AppStorage(ExitCardCategoryVisibility.storageKey)
    private var categoryVisibilityMask: Int = ExitCardCategoryVisibility.defaultMask

    @State private var currentIndex: Int = 0
    @State private var dragOffset: CGFloat = 0
    @State private var detailCard: ExitCard?
    /// When nil, we auto-follow the leftmost (closest) card.
    /// When set, we pin to this exit ID until it leaves the list.
    @State private var pinnedExitId: String?
    @State private var cachedMaxCardHeight: CGFloat = ExitCard.emptyCarouselHeight

    private let cardSpacing: CGFloat = 16
    private let visibleCardWindow = 1

    private var categoryVisibility: ExitCardCategoryVisibility {
        ExitCardCategoryVisibility(mask: categoryVisibilityMask)
    }

    private var visibleServiceCategories: Set<ExitCardServiceCategory> {
        categoryVisibility.enabledCategories
    }

    private var visibleCards: [ExitCard] {
        exitService.exitCards.filter { card in
            !card.displayedServiceCategories(visibleCategories: visibleServiceCategories).isEmpty
        }
    }

    private var isFilteringOutAllCards: Bool {
        !exitService.exitCards.isEmpty && visibleCards.isEmpty
    }

    var body: some View {
        VStack(spacing: 10) {
            // Exit cards carousel
            if visibleCards.isEmpty {
                if exitService.isLoading {
                    loadingView
                } else {
                    emptyStateView
                }
            } else {
                exitCardsCarousel
            }

            // Navigation dots
            if !visibleCards.isEmpty {
                HStack(spacing: 10) {
                    ZStack {
                        if shouldShowJumpToFirstButton {
                            jumpToFirstButton
                                .transition(.opacity)
                        }
                    }
                    .frame(width: 30, height: 30)

                    pageIndicator

                    ZStack {
                        if exitService.isLoading {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(0.8)
                        }
                    }
                    .frame(width: 30, height: 30)
                }
                .frame(maxWidth: .infinity)
                .animation(.easeInOut(duration: 0.18), value: shouldShowJumpToFirstButton)
            }
        }
        .onChange(of: exitService.feedVersion) {
            reconcileVisibleCards(disableAnimations: true, followLeftmostWhenUnpinned: true)
        }
        .onAppear {
            reconcileVisibleCards(disableAnimations: true, followLeftmostWhenUnpinned: true)
        }
        .onChange(of: categoryVisibilityMask) {
            reconcileVisibleCards(disableAnimations: true, followLeftmostWhenUnpinned: false)
        }
    }

    // MARK: - Cards Carousel

    private var exitCardsCarousel: some View {
        GeometryReader { geometry in
            let cardWidth = geometry.size.width - 48
            let cards = visibleCards

            ZStack(alignment: .bottomLeading) {
                ForEach(
                    ExitBrowserLogic.visibleCardIndices(
                        total: cards.count,
                        currentIndex: currentIndex,
                        visibleWindow: visibleCardWindow
                    ),
                    id: \.self
                ) { index in
                    let card = cards[index]
                    ExitCardView(card: card, categoryVisibility: categoryVisibility, onPOITapped: { poi in
                        selectedPOI = poi
                    }, onExitTapped: {
                        detailCard = card
                    })
                    .equatable()
                    .frame(width: cardWidth)
                    .scaleEffect(scaleForCard(at: index))
                    .opacity(opacityForCard(at: index))
                    .offset(x: xOffsetForCard(at: index, cardWidth: cardWidth))
                }
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .simultaneousGesture(dragGesture(cardWidth: cardWidth))
            .animation(.interactiveSpring(response: 0.24, dampingFraction: 0.82), value: currentIndex)
        }
        .frame(height: cachedMaxCardHeight)
        .sheet(item: $detailCard) { card in
            ExitDetailView(card: card) { poi in
                detailCard = nil
                selectedPOI = poi
            }
        }
    }

    private func recalculateMaxCardHeight(_ cards: [ExitCard]) {
        guard !cards.isEmpty else {
            cachedMaxCardHeight = ExitCard.emptyCarouselHeight
            return
        }
        cachedMaxCardHeight = cards.map {
            $0.estimatedCardHeight(visibleCategories: visibleServiceCategories)
        }.max() ?? ExitCard.emptyCarouselHeight
    }

    private func reconcileVisibleCards(
        disableAnimations: Bool,
        followLeftmostWhenUnpinned: Bool
    ) {
        let cards = visibleCards

        guard !cards.isEmpty else {
            focusedExitCard = nil
            currentIndex = 0
            dragOffset = 0
            pinnedExitId = nil
            cachedMaxCardHeight = ExitCard.emptyCarouselHeight
            return
        }

        dragOffset = 0
        recalculateMaxCardHeight(cards)

        var transaction = Transaction()
        transaction.disablesAnimations = disableAnimations

        if let pinId = pinnedExitId {
            if let idx = cards.firstIndex(where: { $0.id == pinId }) {
                withTransaction(transaction) { currentIndex = idx }
                focusedExitCard = cards[idx]
                prefetchForVisibleIndex(idx, cards: cards)
                return
            }
            pinnedExitId = nil
        }

        let targetIndex = followLeftmostWhenUnpinned
            ? 0
            : ExitBrowserLogic.clampedCurrentIndex(currentIndex: currentIndex, total: cards.count)

        withTransaction(transaction) { currentIndex = targetIndex }
        focusedExitCard = cards[targetIndex]
        prefetchForVisibleIndex(targetIndex, cards: cards)
    }

    private func prefetchForVisibleIndex(_ visibleIndex: Int, cards: [ExitCard]) {
        guard visibleIndex >= 0, visibleIndex < cards.count else { return }
        let visibleCardId = cards[visibleIndex].id
        let rawIndex = exitService.exitCards.firstIndex(where: { $0.id == visibleCardId }) ?? visibleIndex
        exitService.maybePrefetchFromCarousel(currentIndex: rawIndex)
    }

    private func dragGesture(cardWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let cards = visibleCards
                guard !cards.isEmpty else {
                    dragOffset = 0
                    return
                }
                dragOffset = ExitBrowserLogic.boundedDragOffset(
                    translation: value.translation.width,
                    currentIndex: currentIndex,
                    totalCards: cards.count
                )
            }
            .onEnded { value in
                let threshold: CGFloat = cardWidth / 4
                let cards = visibleCards
                let swipeWidth = value.predictedEndTranslation.width

                // Let taps flow to card/badge tap gestures without extra settle work.
                if abs(value.translation.width) < 1, abs(value.translation.height) < 1 {
                    dragOffset = 0
                    return
                }

                var nextIndex = currentIndex
                if swipeWidth < -threshold && currentIndex < cards.count - 1 {
                    nextIndex += 1
                } else if swipeWidth > threshold && currentIndex > 0 {
                    nextIndex -= 1
                }

                if nextIndex != currentIndex {
                    withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.82)) {
                        currentIndex = nextIndex
                        dragOffset = 0
                    }
                } else {
                    withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.82)) {
                        dragOffset = 0
                    }
                }

                // Update focused card and pin state after swipe
                if currentIndex < cards.count {
                    focusedExitCard = cards[currentIndex]
                    // Pin to this exit if user swiped past the leftmost card;
                    // clear pin if they swiped back to leftmost
                    pinnedExitId = currentIndex > 0 ? cards[currentIndex].id : nil
                    prefetchForVisibleIndex(currentIndex, cards: cards)
                }
            }
    }

    private func xOffsetForCard(at index: Int, cardWidth: CGFloat) -> CGFloat {
        CGFloat(index - currentIndex) * (cardWidth + cardSpacing) + dragOffset
    }

    private func scaleForCard(at index: Int) -> CGFloat {
        let distance = abs(CGFloat(index - currentIndex))
        return max(0.9, 1.0 - distance * 0.05)
    }

    private func opacityForCard(at index: Int) -> Double {
        let distance = abs(index - currentIndex)
        return max(0.6, 1.0 - Double(distance) * 0.2)
    }

    // MARK: - Page Indicator

    private var shouldShowJumpToFirstButton: Bool {
        clampedCurrentIndex > 0
    }

    private var jumpToFirstButton: some View {
        Button {
            jumpToFirstCard()
        } label: {
            Image(systemName: "backward.end.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.black.opacity(0.3), in: Circle())
        }
        .accessibilityLabel("Go to first exit card")
    }

    private var pageIndicator: some View {
        let visiblePages = indicatorPageIndices
        return HStack(spacing: 6) {
            ForEach(visiblePages, id: \.self) { index in
                Circle()
                    .fill(index == clampedCurrentIndex ? Color.white : Color.white.opacity(0.35))
                    .frame(
                        width: index == clampedCurrentIndex ? 9 : 7,
                        height: index == clampedCurrentIndex ? 9 : 7
                    )
                    .animation(.easeInOut(duration: 0.18), value: clampedCurrentIndex)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.black.opacity(0.3))
        .clipShape(Capsule())
    }

    private var clampedCurrentIndex: Int {
        ExitBrowserLogic.clampedCurrentIndex(
            currentIndex: currentIndex,
            total: visibleCards.count
        )
    }

    private var indicatorPageIndices: [Int] {
        ExitBrowserLogic.indicatorPageIndices(
            total: visibleCards.count,
            currentIndex: clampedCurrentIndex
        )
    }

    private func jumpToFirstCard() {
        let cards = visibleCards
        guard !cards.isEmpty else { return }
        guard currentIndex != 0 || pinnedExitId != nil else { return }

        withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.82)) {
            currentIndex = 0
            dragOffset = 0
        }
        pinnedExitId = nil
        focusedExitCard = cards[0]
        prefetchForVisibleIndex(currentIndex, cards: cards)
    }

    // MARK: - Loading / Empty States

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.2)

            Text("Finding exits ahead…")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        }
        .frame(height: ExitCard.emptyCarouselHeight)
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "road.lanes")
                .font(.system(size: 36))
                .foregroundColor(.secondary.opacity(0.5))

            Text(isFilteringOutAllCards ? "No matching exits" : "Waiting for exits")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.secondary)

            Text(
                isFilteringOutAllCards
                ? "Enable more categories in Settings to show additional exit cards."
                : "Start driving and Pike will show the next exits ahead."
            )
                .font(.system(size: 13))
                .foregroundColor(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)

            if !testDrivePlayer.isActive && !isFilteringOutAllCards {
                Button {
                    onTakeTestDrive()
                } label: {
                    Label("Take a Test Drive", systemImage: "car.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(.blue, in: Capsule())
                }
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 32)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 24)
    }
}
