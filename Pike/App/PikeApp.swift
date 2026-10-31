import SwiftUI
import Sentry

@main
struct PikeApp: App {
    @StateObject private var exitService: ExitService
    @StateObject private var testDrivePlayer: TestDrivePlayer

    init() {
        #if !targetEnvironment(simulator)
        if let dsn = AppConfig.sentryDSN {
            SentrySDK.start { options in
                options.dsn = dsn
                options.enableCaptureFailedRequests = true
                options.enableAutoSessionTracking = true
            }
        }
        #endif

        _exitService = StateObject(wrappedValue: ExitService())
        _testDrivePlayer = StateObject(
            wrappedValue: TestDrivePlayer(locationManager: LocationManager.shared)
        )
    }

    var body: some Scene {
        WindowGroup {
            MainMapView()
                .environmentObject(LocationManager.shared)
                .environmentObject(exitService)
                .environmentObject(testDrivePlayer)
        }
    }
}
