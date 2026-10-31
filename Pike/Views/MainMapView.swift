import SwiftUI
import MapKit
import UIKit

struct MainMapView: View {
    @EnvironmentObject var locationManager: LocationManager
    @EnvironmentObject var exitService: ExitService
    @EnvironmentObject var testDrivePlayer: TestDrivePlayer

    @StateObject private var viewModel = MainMapViewModel()
    @Namespace private var mapScope
    @State private var showTestDrivePicker = false
    @State private var testDrivePickerDetent: PresentationDetent = .height(300)

    private let interstatePickerDetent: PresentationDetent = .height(300)
    private let directionPickerDetent: PresentationDetent = .height(190)

    var body: some View {
        mapLayer
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if let error = exitService.error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(8)
                            .frame(maxWidth: .infinity)
                            .background(.red.opacity(0.85))
                    }

                    ExitBrowserView(
                        exitService: exitService,
                        selectedPOI: $viewModel.selectedPOI,
                        focusedExitCard: $viewModel.focusedExitCard,
                        onTakeTestDrive: {
                            testDrivePickerDetent = interstatePickerDetent
                            showTestDrivePicker = true
                        }
                    )
                }
            }
            .sheet(item: $viewModel.selectedPOI) { poi in
                POIDetailView(poi: poi)
                    .environmentObject(locationManager)
            }
            .sheet(isPresented: $viewModel.showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $viewModel.showPOIList) {
                POIListView(
                    exitCards: exitService.exitCards,
                    onPOISelected: { poi in
                        viewModel.selectPOIFromList(poi)
                    },
                    onNearEnd: { index, total in
                        exitService.maybePrefetchFromList(
                            visibleExitIndex: index,
                            totalExits: total
                        )
                    }
                )
            }
            .sheet(isPresented: $viewModel.showOnboarding, onDismiss: {
                viewModel.dismissOnboarding(locationManager: locationManager)
            }) {
                OnboardingView(onDismiss: {
                    viewModel.dismissOnboarding(locationManager: locationManager)
                }, onTestDrive: {
                    viewModel.dismissOnboarding(locationManager: locationManager)
                    testDrivePickerDetent = interstatePickerDetent
                    showTestDrivePicker = true
                })
                .interactiveDismissDisabled()
            }
            .sheet(isPresented: $showTestDrivePicker) {
                TestDriveRoutePickerSheet(
                    selectedDetent: $testDrivePickerDetent,
                    interstateDetent: interstatePickerDetent,
                    directionDetent: directionPickerDetent
                )
                .environmentObject(testDrivePlayer)
                .presentationDetents(
                    [interstatePickerDetent, directionPickerDetent],
                    selection: $testDrivePickerDetent
                )
                .presentationDragIndicator(.visible)
            }
            .overlay {
                if viewModel.showStartupLoading {
                    AppLoadingView()
                        .transition(.opacity)
                        .zIndex(100)
                }
            }
            .onAppear {
                viewModel.handleAppear(locationManager: locationManager)
            }
            .onChange(of: viewModel.focusedExitCard) {
                viewModel.handleFocusedExitChange(
                    locationManager: locationManager,
                    isTestDriveActive: testDrivePlayer.isActive
                )
            }
            .onChange(of: locationManager.currentLocation) {
                Task {
                    await viewModel.handleLocationChange(
                        locationManager: locationManager,
                        exitService: exitService,
                        isTestDriveActive: testDrivePlayer.isActive
                    )
                }
            }
            .onChange(of: testDrivePlayer.isActive) {
                viewModel.handleTestDriveActivityChange(
                    isActive: testDrivePlayer.isActive,
                    exitService: exitService
                )
            }
            .onMapCameraChange(frequency: .onEnd) { _ in
                viewModel.handleMapCameraChange(
                    isTestDriveActive: testDrivePlayer.isActive
                )
            }
    }

    // MARK: - Map Layer

    private var mapLayer: some View {
        Map(position: $viewModel.mapCameraPosition, interactionModes: .all) {
            if viewModel.shouldShowCustomLocationDot(
                isTestDriveActive: testDrivePlayer.isActive
            ), let loc = locationManager.currentLocation {
                Annotation("", coordinate: loc.coordinate) {
                    Circle()
                        .fill(.blue)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(.white, lineWidth: 2.5))
                        .shadow(radius: 3)
                }
            } else {
                UserAnnotation()
            }

            // Show focused exit marker
            if let card = viewModel.focusedExitCard {
                // Exit location marker (green highway sign style)
                Annotation(card.exit.shortTitle, coordinate: card.exit.coordinate) {
                    exitMarker(for: card.exit)
                }

                // POIs at this exit
                ForEach(card.allPOIs) { poi in
                    Annotation(poi.name, coordinate: poi.coordinate) {
                        poiMarker(for: poi)
                    }
                }
            }
        }
        .mapScope(mapScope)
        .mapControls { }
        .overlay(alignment: .topTrailing) {
            mapControlsOverlay
                .padding(.trailing, 10)
                .padding(.top, 6)
        }
        .overlay(alignment: .top) {
            if testDrivePlayer.isActive {
                Button {
                    testDrivePlayer.stop()
                } label: {
                    Label("Test Drive", systemImage: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.blue, in: Capsule())
                        .shadow(radius: 3)
                }
                .padding(.top, 60)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .ignoresSafeArea(edges: .top)
    }

    private func poiMarker(for poi: POI) -> some View {
        Button {
            viewModel.selectPOI(poi)
        } label: {
            Image(systemName: poi.category.systemImage)
                .font(.caption)
                .foregroundStyle(.white)
                .padding(6)
                .background(poi.category.color)
                .clipShape(Circle())
                .shadow(radius: 2)
        }
    }

    private func exitMarker(for exit: Exit) -> some View {
        VStack(spacing: 2) {
            Text(exit.markerLabel)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.green.opacity(0.9))
                .clipShape(RoundedRectangle(cornerRadius: 4))

            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 8))
                .foregroundStyle(.green)
        }
        .shadow(radius: 2)
    }

    private func mapOverlayButton(
        icon: String,
        active: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .foregroundStyle(active ? .blue : .primary)
        }
    }

    // MARK: - Map Controls Overlay

    @ViewBuilder
    private var mapControlsOverlay: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer {
                mapControlsStack { button in
                    button.glassEffect(.clear.interactive(), in: .circle)
                }
            }
        } else {
            mapControlsLegacy
        }
    }

    /// Shared control stack — the `applyStyle` closure decorates each app button.
    private func mapControlsStack<V: View>(
        @ViewBuilder applyStyle: @escaping (AnyView) -> V
    ) -> some View {
        VStack(spacing: 8) {
            MapUserLocationButton(scope: mapScope)
            MapCompass(scope: mapScope)

            applyStyle(AnyView(mapOverlayButton(
                icon: viewModel.isFollowingCourse
                    ? "location.north.fill"
                    : "location.north",
                active: viewModel.isFollowingCourse
            ) {
                viewModel.toggleFollowMode(
                    locationManager: locationManager,
                    isTestDriveActive: testDrivePlayer.isActive
                )
            }))

            applyStyle(AnyView(mapOverlayButton(icon: "list.bullet") {
                viewModel.presentPOIList()
            }))

            applyStyle(AnyView(mapOverlayButton(icon: "gear") {
                viewModel.presentSettings()
            }))
        }
    }

    /// Pre-iOS 26 fallback with ultraThinMaterial grouped style.
    private var mapControlsLegacy: some View {
        VStack(spacing: 8) {
            MapUserLocationButton(scope: mapScope)
            MapCompass(scope: mapScope)

            VStack(spacing: 0) {
                mapOverlayButton(
                    icon: viewModel.isFollowingCourse
                        ? "location.north.fill"
                        : "location.north",
                    active: viewModel.isFollowingCourse
                ) {
                    viewModel.toggleFollowMode(
                        locationManager: locationManager,
                        isTestDriveActive: testDrivePlayer.isActive
                    )
                }

                Divider().frame(width: 36)

                mapOverlayButton(icon: "list.bullet") {
                    viewModel.presentPOIList()
                }

                Divider().frame(width: 36)

                mapOverlayButton(icon: "gear") {
                    viewModel.presentSettings()
                }
            }
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(radius: 2)
        }
    }
}

private struct TestDriveRoutePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var testDrivePlayer: TestDrivePlayer

    @Binding var selectedDetent: PresentationDetent
    let interstateDetent: PresentationDetent
    let directionDetent: PresentationDetent

    @State private var choices: [TestDriveRouteChoice] = []
    @State private var selectedChoice: TestDriveRouteChoice?
    @State private var isLoading = true
    @State private var startError: String?
    @State private var stage: PickerStage = .interstates

    private enum PickerStage {
        case interstates
        case directions
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading Routes…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if choices.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 8) {
                        if stage == .directions, let choice = selectedChoice {
                            directionButtons(for: choice)
                        } else {
                            interstateButtons
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .navigationTitle(titleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if stage == .directions {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Back") {
                            withAnimation(.easeInOut(duration: 0.22)) {
                                stage = .interstates
                                selectedDetent = interstateDetent
                            }
                        }
                    }
                }
            }
        }
        .task {
            choices = testDrivePlayer.routeChoices(limit: 6)
            isLoading = false
        }
    }

    private var titleText: String {
        switch stage {
        case .interstates:
            return "Choose Interstate"
        case .directions:
            return ""
        }
    }

    private var interstateButtons: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ],
                spacing: 8
            ) {
                ForEach(choices, id: \.highway) { choice in
                    Button {
                        startError = nil
                        withAnimation(.easeInOut(duration: 0.22)) {
                            selectedChoice = choice
                            stage = .directions
                            selectedDetent = directionDetent
                        }
                    } label: {
                        InterstateShieldBadge(highway: choice.highway, width: 72, height: 82)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(choice.highway)
                }
            }
            .padding(.bottom, 2)
        }
    }

    private func directionButtons(for choice: TestDriveRouteChoice) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                ForEach(Array(choice.directions.prefix(2)), id: \.routeId) { direction in
                    Button {
                        if testDrivePlayer.start(routeId: direction.routeId) {
                            dismiss()
                        } else {
                            startError = "Could not start that route."
                        }
                    } label: {
                        Text(direction.directionLabel)
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, minHeight: 64)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            if choice.directions.count < 2 {
                Text("Direction unavailable for this route.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let startError {
                Text(startError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "road.lanes")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("Could not load nearby routes.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

}

private struct InterstateShieldBadge: View {
    let highway: String
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        if let imageName = resolvedImageName {
            Image(imageName)
                .resizable()
                .scaledToFit()
                .frame(width: width, height: height)
                .accessibilityHidden(true)
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.blue)
                .overlay(
                    Text(shieldLabel)
                        .font(.system(size: 16, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                )
                .frame(width: width, height: height)
                .accessibilityHidden(true)
        }
    }

    private var resolvedImageName: String? {
        let candidate = "interstate_\(normalizedKey)"
        return UIImage(named: candidate) == nil ? nil : candidate
    }

    private var normalizedKey: String {
        highway.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private var shieldLabel: String {
        let upper = highway.uppercased()
        return upper.hasPrefix("I-") ? String(upper.dropFirst(2)) : upper
    }
}
