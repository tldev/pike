//
//  ExitService.swift
//  Pike
//
//  Orchestrator: wires together BundledPack, GraphStrategy,
//  ExitStabilizer, and CorridorLock to produce
//  exit cards from the SQLite data pack that ships in the app.
//

import Foundation
import CoreLocation
import Sentry

@MainActor
final class ExitService: ObservableObject {

    // MARK: - Published State

    @Published var exitCards: [ExitCard] = []
    @Published var feedVersion: UInt64 = 0
    @Published var isLoading = false
    @Published var error: String?
    @Published private(set) var packVersionLabel: String?

    // MARK: - Configuration

    private let defaultLimit = 10
    private let defaultLookaheadMeters: CLLocationDistance = 50_000
    private let prefetchThresholdFromEnd = 3
    private let minRefreshInterval: TimeInterval = 3.0
    private let minRefreshDistance: CLLocationDistance = 150

    // MARK: - Dependencies

    private let database: (any ExitDatabase)?
    private let databaseError: String?

    // MARK: - State

    private var loadingCount: Int = 0
    private var hasCompletedInitialFetch = false
    private var corridorLock: CorridorLockState? = nil
    private var stabilizer = ExitStabilizer()
    private var headCards: [ExitCard] = []
    private var pagedTailCards: [ExitCard] = []
    private var afterExitIdCursor: String?
    private var afterDistanceCursor: Int?
    private var pagingExhausted = false
    private var pagingInFlight = false
    private var noProgressPageCount = 0
    private var lastUserCourse: CLLocationDirection?
    private var lastRefreshAt: Date?
    private var lastRefreshLocation: CLLocation?

    // MARK: - Public API

    init() {
        do {
            let db = try BundledPack.open()
            database = db
            databaseError = nil
            packVersionLabel = BundledPack.generatedAtLabel(for: db)
        } catch {
            SentrySDK.capture(error: error)
            database = nil
            databaseError = error.localizedDescription
        }
        Task.detached(priority: .utility) { BundledPack.removeLegacyDownload() }
    }

    /// Reset all transient feed state (corridor lock, stabilizer, exit cards).
    /// Called when test drive stops to prevent stale state from interfering with real GPS.
    func resetFeedState() {
        corridorLock = nil
        stabilizer.reset()
        resetPaginationState()
        exitCards = []
        feedVersion &+= 1
        lastRefreshAt = nil
        lastRefreshLocation = nil
        hasCompletedInitialFetch = false
    }

    // MARK: - Feed Refresh

    func loadExitCards(
        userLocation: CLLocation,
        userCourse: CLLocationDirection
    ) async {
        let speedMps = max(0, userLocation.speed)
        error = nil

        guard let db = database else {
            error = databaseError
            return
        }

        // Throttle
        if shouldSkipRefresh(for: userLocation) {
            return
        }
        lastUserCourse = userCourse

        // Only show loading UI before the first completed fetch.
        // If we keep getting empty results, stay on the empty state instead
        // of flashing back to loading on every refresh.
        let isInitialLoad = exitCards.isEmpty && !hasCompletedInitialFetch
        if isInitialLoad {
            beginLoading()
        }
        defer {
            hasCompletedInitialFetch = true
            if isInitialLoad {
                endLoading()
            }
        }

        do {
            // Heavy SQLite work runs on a background thread to avoid blocking
            // the main thread (which would cause drag gesture jank).
            let previousCorridor = corridorLock?.key
            let lock = corridorLock
            let lookahead = defaultLookaheadMeters
            let limit = defaultLimit

            let graphResult = try await Task.detached(priority: .userInitiated) {
                try GraphStrategy.findExits(
                    database: db,
                    userLocation: userLocation,
                    userCourse: userCourse,
                    speedMps: speedMps,
                    corridorLock: lock,
                    lookahead: lookahead,
                    limit: limit
                )
            }.value

            // Back on main actor: update lock state, stabilize
            if let graphResult {
                CorridorLock.update(
                    lock: &corridorLock,
                    signal: graphResult.corridorSignal,
                    userCoord: userLocation.coordinate,
                    now: Date()
                )
            }

            if didCorridorChange(previous: previousCorridor, current: corridorLock?.key) {
                resetPaginationTail()
            }

            let stabilized = stabilizer.stabilize(
                graphResult?.cards ?? [],
                userLocation: userLocation,
                userCourse: userCourse,
                limit: defaultLimit
            )
            headCards = stabilized
            let combined = composeVisibleCards(
                userLocation: userLocation,
                userCourse: userCourse,
                speedMps: speedMps
            )
            applyIfChanged(combined)
            await ensureMinimumBuffer(
                userLocation: userLocation,
                userCourse: userCourse,
                speedMps: speedMps
            )
        } catch {
            SentrySDK.capture(error: error)
            self.error = error.localizedDescription
        }
    }

    // MARK: - Pagination

    func maybePrefetchFromCarousel(currentIndex: Int) {
        let total = exitCards.count
        guard shouldPrefetch(at: currentIndex, total: total),
              let location = lastRefreshLocation,
              let userCourse = lastUserCourse
        else {
            return
        }
        Task {
            _ = await fetchNextPageIfNeeded(
                userLocation: location,
                userCourse: userCourse,
                speedMps: max(0, location.speed)
            )
        }
    }

    func maybePrefetchFromList(visibleExitIndex: Int, totalExits: Int) {
        guard shouldPrefetch(at: visibleExitIndex, total: totalExits),
              let location = lastRefreshLocation,
              let userCourse = lastUserCourse
        else {
            return
        }
        Task {
            _ = await fetchNextPageIfNeeded(
                userLocation: location,
                userCourse: userCourse,
                speedMps: max(0, location.speed)
            )
        }
    }

    private func shouldPrefetch(at index: Int, total: Int) -> Bool {
        guard total > 0 else { return false }
        return index >= max(0, total - prefetchThresholdFromEnd)
    }

    private func ensureMinimumBuffer(
        userLocation: CLLocation,
        userCourse: CLLocationDirection,
        speedMps: CLLocationSpeed
    ) async {
        while exitCards.count < defaultLimit && !pagingExhausted {
            let progressed = await fetchNextPageIfNeeded(
                userLocation: userLocation,
                userCourse: userCourse,
                speedMps: speedMps
            )
            if !progressed {
                break
            }
        }
    }

    private func fetchNextPageIfNeeded(
        userLocation: CLLocation,
        userCourse: CLLocationDirection,
        speedMps: CLLocationSpeed
    ) async -> Bool {
        if pagingInFlight || pagingExhausted {
            return false
        }
        guard let db = database,
              let afterExitId = afterExitIdCursor,
              let afterDistanceM = afterDistanceCursor
        else {
            return false
        }

        pagingInFlight = true
        defer { pagingInFlight = false }

        do {
            var pageCards: [ExitCard] = []
            let previousCorridor = corridorLock?.key

            let lock = corridorLock
            let lookahead = defaultLookaheadMeters
            let pageLimit = defaultLimit
            let graphResult = try await Task.detached(priority: .userInitiated) {
                try GraphStrategy.findExits(
                    database: db,
                    userLocation: userLocation,
                    userCourse: userCourse,
                    speedMps: speedMps,
                    corridorLock: lock,
                    lookahead: lookahead,
                    limit: pageLimit,
                    afterExitId: afterExitId,
                    afterDistanceM: afterDistanceM
                )
            }.value

            if let graphResult {
                CorridorLock.update(
                    lock: &corridorLock,
                    signal: graphResult.corridorSignal,
                    userCoord: userLocation.coordinate,
                    now: Date()
                )
                pageCards = graphResult.cards
            }

            if didCorridorChange(previous: previousCorridor, current: corridorLock?.key) {
                resetPaginationTail()
                let combined = composeVisibleCards(
                    userLocation: userLocation,
                    userCourse: userCourse,
                    speedMps: speedMps
                )
                applyIfChanged(combined)
                return false
            }

            if pageCards.isEmpty {
                let next = Self.nextNoProgressState(
                    noProgressPageCount: noProgressPageCount,
                    pagingExhausted: pagingExhausted
                )
                noProgressPageCount = next.noProgressPageCount
                pagingExhausted = next.pagingExhausted
                return false
            }

            var existingIds = Set(headCards.map(\.id))
            existingIds.formUnion(pagedTailCards.map(\.id))
            let unique = pageCards.filter { existingIds.insert($0.id).inserted }

            if unique.isEmpty {
                let next = Self.nextNoProgressState(
                    noProgressPageCount: noProgressPageCount,
                    pagingExhausted: pagingExhausted
                )
                noProgressPageCount = next.noProgressPageCount
                pagingExhausted = next.pagingExhausted
                return false
            }

            noProgressPageCount = 0
            pagedTailCards.append(contentsOf: unique)

            let combined = composeVisibleCards(
                userLocation: userLocation,
                userCourse: userCourse,
                speedMps: speedMps
            )
            applyIfChanged(combined)
            return true
        } catch {
            SentrySDK.capture(error: error)
            self.error = error.localizedDescription
            return false
        }
    }

    nonisolated static func nextNoProgressState(
        noProgressPageCount: Int,
        pagingExhausted: Bool
    ) -> (noProgressPageCount: Int, pagingExhausted: Bool) {
        let nextCount = noProgressPageCount + 1
        let exhausted = pagingExhausted || nextCount >= 2
        return (nextCount, exhausted)
    }

    private func didCorridorChange(previous: CorridorKey?, current: CorridorKey?) -> Bool {
        guard current != nil else { return false }
        guard let previous else { return false }
        return previous != current
    }

    private func composeVisibleCards(
        userLocation: CLLocation,
        userCourse: CLLocationDirection,
        speedMps: CLLocationSpeed
    ) -> [ExitCard] {
        let headIds = Set(headCards.map(\.id))
        pagedTailCards = pagedTailCards.filter { card in
            !headIds.contains(card.id)
                && isCardStillAhead(card, userLocation: userLocation, userCourse: userCourse)
        }

        var combined = headCards
        combined.append(contentsOf: pagedTailCards)
        combined = refreshDistanceAndEta(for: combined, userLocation: userLocation, speedMps: speedMps)
        updatePaginationCursor(from: combined)
        return combined
    }

    private func isCardStillAhead(
        _ card: ExitCard,
        userLocation: CLLocation,
        userCourse: CLLocationDirection
    ) -> Bool {
        let coord = card.exit.coordinate
        let dist = userLocation.distance(from: CLLocation(latitude: coord.latitude, longitude: coord.longitude))
        // Keep far tail cards even when geometric bearing diverges on curvy corridors.
        // Only prune as "behind" when an exit is close and strongly behind heading.
        if dist < 160 { return false }
        let bearing = GeoMath.bearing(from: userLocation.coordinate, to: coord)
        let angle = GeoMath.absoluteAngleDifference(bearing, userCourse)
        if dist < 3_000 && angle > 130 { return false }
        return true
    }

    private func refreshDistanceAndEta(
        for cards: [ExitCard],
        userLocation: CLLocation,
        speedMps: CLLocationSpeed
    ) -> [ExitCard] {
        cards.map { card in
            var updated = card
            let coord = updated.exit.coordinate
            let distance = userLocation.distance(from: CLLocation(latitude: coord.latitude, longitude: coord.longitude))
            updated.exit.distanceFromUser = distance
            updated.exit.estimatedTimeToExit = speedMps > 1 ? distance / speedMps : 0
            return updated
        }
    }

    private func updatePaginationCursor(from cards: [ExitCard]) {
        guard let last = cards.last else {
            afterExitIdCursor = nil
            afterDistanceCursor = nil
            return
        }
        let newId = rawExitId(fromCardId: last.id)
        let newDistance = Int(last.exit.distanceFromUser.rounded())
        if afterExitIdCursor != newId || afterDistanceCursor != newDistance {
            noProgressPageCount = 0
            pagingExhausted = false
        }
        afterExitIdCursor = newId
        afterDistanceCursor = newDistance
    }

    private func rawExitId(fromCardId cardId: String) -> String {
        String(cardId.dropFirst("exit-".count))
    }

    private func resetPaginationTail() {
        pagedTailCards = []
        pagingExhausted = false
        pagingInFlight = false
        noProgressPageCount = 0
        updatePaginationCursor(from: headCards)
    }

    private func resetPaginationState() {
        headCards = []
        pagedTailCards = []
        afterExitIdCursor = nil
        afterDistanceCursor = nil
        pagingExhausted = false
        pagingInFlight = false
        noProgressPageCount = 0
        lastUserCourse = nil
    }

    // MARK: - Throttle

    private func shouldSkipRefresh(for location: CLLocation) -> Bool {
        if let lastAt = lastRefreshAt {
            let elapsed = Date().timeIntervalSince(lastAt)
            // Hard floor: never refresh faster than this, regardless of distance
            if elapsed < minRefreshInterval { return true }
            // Soft throttle: within 2x the interval, also require meaningful movement
            if elapsed < minRefreshInterval * 2,
               let lastLoc = lastRefreshLocation,
               location.distance(from: lastLoc) < minRefreshDistance {
                return true
            }
        }
        lastRefreshAt = Date()
        lastRefreshLocation = location
        return false
    }

    // MARK: - Diffing

    private func applyIfChanged(_ newCards: [ExitCard]) {
        // Skip the @Published update if the card IDs and distances haven't changed,
        // avoiding unnecessary SwiftUI redraws.
        guard newCards.count != exitCards.count ||
              !zip(newCards, exitCards).allSatisfy({ $0.id == $1.id && $0.exit.distanceFromUser == $1.exit.distanceFromUser })
        else { return }
        exitCards = newCards
        feedVersion &+= 1
    }

    // MARK: - Loading

    private func beginLoading() {
        loadingCount += 1
        isLoading = loadingCount > 0
    }

    private func endLoading() {
        loadingCount = max(0, loadingCount - 1)
        isLoading = loadingCount > 0
    }
}
