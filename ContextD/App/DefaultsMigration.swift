import Foundation

enum DefaultsMigration {
    private static let logger = DualLogger(category: "DefaultsMigration")
    private static let legacyDomain = "com.contextd.app"
    private static let migrationMarker = "didMigrateLegacyContextDDefaults"

    static func migrateLegacyContextDDefaults() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationMarker) else { return }

        guard let legacyValues = defaults.persistentDomain(forName: legacyDomain),
              !legacyValues.isEmpty else {
            defaults.set(true, forKey: migrationMarker)
            return
        }

        var migratedCount = 0
        for (key, value) in legacyValues where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            migratedCount += 1
        }

        defaults.set(true, forKey: migrationMarker)

        if migratedCount > 0 {
            logger.info("Migrated \(migratedCount) defaults from \(legacyDomain)")
        } else {
            logger.info("Legacy defaults present but no migration was needed")
        }
    }
}
