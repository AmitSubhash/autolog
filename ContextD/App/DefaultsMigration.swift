import Foundation

enum DefaultsMigration {
    private static let logger = DualLogger(category: "DefaultsMigration")
    private static let legacyDomain = "com.contextd.app"
    private static let migrationMarker = "didMigrateLegacyContextDDefaults"
    private static let performanceMarker = "didApplyAutologPerformanceDefaultsV2"

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

    static func applyPerformanceDefaults() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: performanceMarker) else { return }
        let minimumCaptureInterval = 8.0

        var applied: [String] = []

        let interval = defaults.object(forKey: "captureInterval") as? Double
        if interval == nil || (interval ?? 0) < minimumCaptureInterval {
            defaults.set(15.0, forKey: "captureInterval")
            applied.append("captureInterval=15")
        }

        let keyframeInterval = defaults.object(forKey: "maxKeyframeInterval") as? Double
        if keyframeInterval == nil || (keyframeInterval ?? 0) < 90.0 {
            defaults.set(90.0, forKey: "maxKeyframeInterval")
            applied.append("maxKeyframeInterval=90")
        }

        if defaults.string(forKey: "captureSpeed") == nil {
            defaults.set("medium", forKey: "captureSpeed")
            applied.append("captureSpeed=medium")
        }

        defaults.set(true, forKey: performanceMarker)

        if !applied.isEmpty {
            logger.info("Applied performance defaults: \(applied.joined(separator: ", "))")
        }
    }
}
