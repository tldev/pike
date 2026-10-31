import Foundation

enum AppConfig {
    private static let sentryDSNInfoPlistKey = "SentryDSN"
    private static let sentryDSNEnvKey = "SENTRY_DSN"

    static var sentryDSN: String? {
        if let raw = ProcessInfo.processInfo.environment[sentryDSNEnvKey], !raw.isEmpty {
            return raw
        }
        if let raw = Bundle.main.object(forInfoDictionaryKey: sentryDSNInfoPlistKey) as? String, !raw.isEmpty {
            return raw
        }
        return nil
    }
}
