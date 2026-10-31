import SwiftUI
import MapKit

/// Detail view for a selected POI with map preview, detour cost, and action buttons.
struct POIDetailView: View {
    let poi: POI
    @EnvironmentObject var locationManager: LocationManager
    @Environment(\.dismiss) var dismiss

    @State private var isResolvingApple = false
    @State private var showMap = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Grabber
                Capsule()
                    .fill(Color(.systemFill))
                    .frame(width: 36, height: 5)
                    .padding(.top, 6)

                // Title row: name + dismiss button
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(poi.name)
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                }

                // Map preview — deferred to avoid MapKit init competing with sheet animation
                mapPreview

                // POI info
                infoSection

                // Detour cost
                if let estimate = resolvedDriveEstimate {
                    estimateSection(estimate)
                }

                // Action buttons
                actionButtons
            }
            .padding()
        }
        .task(id: poi.id) {
            // Delay MapKit initialization until the sheet transition settles.
            showMap = false
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            showMap = true
        }
    }

    // MARK: - Map Preview

    private var mapPreview: some View {
        Group {
            if showMap {
                Map {
                    Marker(poi.name, coordinate: poi.coordinate)
                        .tint(poi.category.color)

                    if let location = locationManager.currentLocation {
                        Annotation("You", coordinate: location.coordinate) {
                            Circle()
                                .fill(.blue)
                                .frame(width: 12, height: 12)
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                        }
                    }
                }
            } else {
                MapPlaceholder()
            }
        }
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Info Section

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: poi.category.systemImage)
                    .foregroundStyle(poi.category.color)
                Text(poi.category.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let distance = poi.estimatedDriveDistanceFromExit ?? poi.distanceFromExit {
                Label(formatExitDistance(distance), systemImage: "arrowshape.turn.up.right")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Estimate Section

    private struct DriveEstimate {
        let distanceMeters: CLLocationDistance
        let timeSeconds: TimeInterval
        let isReachability: Bool
    }

    private func estimateSection(_ estimate: DriveEstimate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Estimated Drive from Exit")
                .font(.headline)

            HStack(spacing: 16) {
                VStack {
                    Text(formatDriveTime(estimate.timeSeconds))
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Drive time")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()
                    .frame(height: 40)

                VStack {
                    Text(formatDriveDistance(estimate.distanceMeters))
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("From exit")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
                Text("Estimate")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.systemGray5))
                    .clipShape(Capsule())
            }

            if !estimate.isReachability {
                Text("Fallback estimate based on local-road speed.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Actions

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button {
                poi.openInMaps()
            } label: {
                Label("Get Directions", systemImage: "arrow.triangle.turn.up.right.diamond")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(poi.category.color)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .fontWeight(.semibold)
            }

            HStack(spacing: 10) {
                Button {
                    isResolvingApple = true
                    Task {
                        await poi.resolveAndOpenInAppleMaps()
                        isResolvingApple = false
                    }
                } label: {
                    Label {
                        if isResolvingApple {
                            Text("Opening…")
                        } else {
                            Text("Apple Maps")
                        }
                    } icon: {
                        if isResolvingApple {
                            ProgressView()
                        } else {
                            Image(systemName: "map.fill")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(.systemGray5))
                    .foregroundStyle(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(isResolvingApple)

                Button {
                    openInGoogleMaps()
                } label: {
                    Label("Google Maps", systemImage: "globe")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(.systemGray5))
                        .foregroundStyle(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private func openInGoogleMaps() {
        let encodedName = poi.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? poi.name
        let lat = poi.coordinate.latitude
        let lon = poi.coordinate.longitude
        if let url = URL(string: "https://www.google.com/maps/search/\(encodedName)/@\(lat),\(lon),17z") {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Helpers

    private func formatExitDistance(_ meters: CLLocationDistance) -> String {
        if meters < 1609 {
            let feet = Int(meters * 3.28084)
            return "\(feet) ft from exit"
        }
        let miles = meters / 1609.34
        return String(format: "%.1f mi from exit", miles)
    }

    private func formatDriveDistance(_ meters: CLLocationDistance) -> String {
        let miles = meters / 1609.34
        if miles < 10 {
            return String(format: "%.1f mi", miles)
        }
        return String(format: "%.0f mi", miles)
    }

    private func formatDriveTime(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 1 { return "<1 min" }
        return "\(minutes) min"
    }

    private var resolvedDriveEstimate: DriveEstimate? {
        if let driveDistance = poi.estimatedDriveDistanceFromExit,
           let driveTime = poi.estimatedDriveTimeFromExit {
            return DriveEstimate(
                distanceMeters: driveDistance,
                timeSeconds: driveTime,
                isReachability: true
            )
        }

        guard let distance = poi.distanceFromExit else { return nil }
        // Local-road fallback when reachability estimates are unavailable.
        let fallbackSeconds = distance / 13.4
        return DriveEstimate(
            distanceMeters: distance,
            timeSeconds: fallbackSeconds,
            isReachability: false
        )
    }
}
