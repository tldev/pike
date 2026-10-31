//
//  BundledPack.swift
//  Pike
//
//  Opens the SQLite data pack that ships inside the app bundle.
//

import Foundation

enum BundledPack {

    /// Must match the schema of the pack pinned in build.sh.
    static let supportedSchema = 5

    enum PackError: LocalizedError {
        case missing
        case unsupportedSchema(Int?)

        var errorDescription: String? {
            switch self {
            case .missing: return "Exit data is missing from this build of Pike"
            case .unsupportedSchema: return "Exit data doesn't match this build of Pike"
            }
        }
    }

    static func open(bundle: Bundle = .main) throws -> SQLiteExitDatabase {
        guard let url = bundle.url(forResource: "pike", withExtension: "sqlite") else {
            throw PackError.missing
        }
        let db = try SQLiteExitDatabase.open(at: url)
        let version = try db.schemaVersionChecked()
        guard isSupported(schemaVersion: version) else {
            throw PackError.unsupportedSchema(version)
        }
        return db
    }

    static func isSupported(schemaVersion: Int?) -> Bool {
        schemaVersion == supportedSchema
    }

    /// Short label for when the bundled data was generated, e.g. "Jul 15, 2026".
    static func generatedAtLabel(for db: SQLiteExitDatabase) -> String? {
        guard let raw = db.metaValue(forKey: "generated_at"),
              let date = ISO8601DateFormatter().date(from: raw) else {
            return nil
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// Delete state left by versions that downloaded the pack at runtime.
    static func removeLegacyDownload() {
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let url = appSupport
                .appendingPathComponent("Pike", isDirectory: true)
                .appendingPathComponent("pike.sqlite", isDirectory: false)
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        for key in ["pike.pack.sha256", "pike.pack.sizeBytes", "pike.pack.versionLabel", "premium.offlinePreference"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
