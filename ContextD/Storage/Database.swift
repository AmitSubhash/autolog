import Foundation
import GRDB

/// Manages the SQLite database using GRDB with WAL mode and FTS5.
/// Handles schema creation, migrations, and provides the shared DatabasePool.
final class AppDatabase: Sendable {
    /// The GRDB database pool (WAL mode: concurrent reads, serial writes).
    let dbPool: DatabasePool

    private static let logger = DualLogger(category: "Database")

    /// Initialize the database at the default application support location.
    init() throws {
        let dbPath = try AppDatabase.databasePath()
        dbPool = try DatabasePool(path: dbPath, configuration: AppDatabase.makeConfiguration())
        try Self.buildMigrator().migrate(dbPool)
        AppDatabase.logger.info("Database initialized at \(dbPath)")
    }

    /// Initialize with a custom path (for testing).
    init(path: String) throws {
        dbPool = try DatabasePool(path: path, configuration: AppDatabase.makeConfiguration())
        try Self.buildMigrator().migrate(dbPool)
    }

    // MARK: - Configuration

    private static func makeConfiguration() -> Configuration {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_size_limit = 33554432")  // 32MB WAL limit
            try db.execute(sql: "PRAGMA synchronous = NORMAL")           // safe with WAL
            try db.execute(sql: "PRAGMA busy_timeout = 5000")            // 5s retry on contention
            try db.execute(sql: "PRAGMA mmap_size = 268435456")          // 256MB mmap
            // Note: auto_vacuum must be set before first table creation.
            // For existing databases, use incremental_vacuum in maintenance.
        }
        return config
    }

    // MARK: - Database Path

    private static func databasePath() throws -> String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("ContextD", isDirectory: true)

        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

        return appSupport.appendingPathComponent("contextd.sqlite").path
    }

    // MARK: - Migrations

    private static func buildMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // Only erase in unit tests, never in app builds.
        // DEBUG builds used by users should preserve data.
        #if TESTING
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1_createCaptures") { db in
            try db.create(table: "captures") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .double).notNull()
                t.column("appName", .text).notNull()
                t.column("appBundleID", .text)
                t.column("windowTitle", .text)
                t.column("ocrText", .text).notNull()
                t.column("fullOcrText", .text).notNull().defaults(to: "")
                t.column("visibleWindows", .text)
                t.column("textHash", .text).notNull()
                t.column("isSummarized", .boolean).notNull().defaults(to: false)
                t.column("frameType", .text).notNull().defaults(to: "keyframe")
                t.column("keyframeId", .integer)
                t.column("changePercentage", .double).notNull().defaults(to: 1.0)
            }

            try db.create(index: "idx_captures_timestamp", on: "captures", columns: ["timestamp"])
            try db.create(index: "idx_captures_app", on: "captures", columns: ["appName"])
            try db.create(index: "idx_captures_hash", on: "captures", columns: ["textHash"])
            try db.create(index: "idx_captures_keyframe", on: "captures", columns: ["keyframeId"])
            try db.create(index: "idx_captures_frametype", on: "captures", columns: ["frameType"])
        }

        migrator.registerMigration("v1_createCapturesFTS") { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE captures_fts USING fts5(
                    ocrText,
                    windowTitle,
                    appName,
                    content=captures,
                    content_rowid=id,
                    tokenize='porter unicode61'
                )
                """)

            // Triggers to keep FTS in sync with the content table.
            // The FTS column name stays 'ocrText' for backward compat, but the VALUE
            // comes from fullOcrText (always has complete text for all frame types).
            try db.execute(sql: """
                CREATE TRIGGER captures_ai AFTER INSERT ON captures BEGIN
                    INSERT INTO captures_fts(rowid, ocrText, windowTitle, appName)
                    VALUES (new.id, new.fullOcrText, new.windowTitle, new.appName);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER captures_ad AFTER DELETE ON captures BEGIN
                    INSERT INTO captures_fts(captures_fts, rowid, ocrText, windowTitle, appName)
                    VALUES ('delete', old.id, old.fullOcrText, old.windowTitle, old.appName);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER captures_au AFTER UPDATE ON captures BEGIN
                    INSERT INTO captures_fts(captures_fts, rowid, ocrText, windowTitle, appName)
                    VALUES ('delete', old.id, old.fullOcrText, old.windowTitle, old.appName);
                    INSERT INTO captures_fts(rowid, ocrText, windowTitle, appName)
                    VALUES (new.id, new.fullOcrText, new.windowTitle, new.appName);
                END
                """)
        }

        migrator.registerMigration("v1_createSummaries") { db in
            try db.create(table: "summaries") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("startTimestamp", .double).notNull()
                t.column("endTimestamp", .double).notNull()
                t.column("appNames", .text)
                t.column("summary", .text).notNull()
                t.column("keyTopics", .text)
                t.column("captureIds", .text).notNull()
            }

            try db.create(index: "idx_summaries_time", on: "summaries",
                          columns: ["startTimestamp", "endTimestamp"])
        }

        migrator.registerMigration("v1_createSummariesFTS") { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE summaries_fts USING fts5(
                    summary,
                    keyTopics,
                    appNames,
                    content=summaries,
                    content_rowid=id,
                    tokenize='porter unicode61'
                )
                """)

            try db.execute(sql: """
                CREATE TRIGGER summaries_ai AFTER INSERT ON summaries BEGIN
                    INSERT INTO summaries_fts(rowid, summary, keyTopics, appNames)
                    VALUES (new.id, new.summary, new.keyTopics, new.appNames);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER summaries_ad AFTER DELETE ON summaries BEGIN
                    INSERT INTO summaries_fts(summaries_fts, rowid, summary, keyTopics, appNames)
                    VALUES ('delete', old.id, old.summary, old.keyTopics, old.appNames);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER summaries_au AFTER UPDATE ON summaries BEGIN
                    INSERT INTO summaries_fts(summaries_fts, rowid, summary, keyTopics, appNames)
                    VALUES ('delete', old.id, old.summary, old.keyTopics, old.appNames);
                    INSERT INTO summaries_fts(rowid, summary, keyTopics, appNames)
                    VALUES (new.id, new.summary, new.keyTopics, new.appNames);
                END
                """)
        }

        migrator.registerMigration("v2_createTokenUsage") { db in
            try db.create(table: "token_usage") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .double).notNull()
                t.column("caller", .text).notNull()
                t.column("model", .text).notNull()
                t.column("inputTokens", .integer).notNull()
                t.column("outputTokens", .integer).notNull()
            }

            try db.create(index: "idx_token_usage_timestamp", on: "token_usage",
                          columns: ["timestamp"])
            try db.create(index: "idx_token_usage_caller", on: "token_usage",
                          columns: ["caller"])
        }

        migrator.registerMigration("v3_addCompositeIndexes") { db in
            // Composite index for the common unsummarized-captures query
            // (isSummarized filter + timestamp sort).
            try db.create(index: "idx_captures_unsummarized", on: "captures",
                          columns: ["isSummarized", "timestamp"], ifNotExists: true)

            // Index on summaries.endTimestamp for prune queries.
            try db.create(index: "idx_summaries_end", on: "summaries",
                          columns: ["endTimestamp"], ifNotExists: true)

            // Design note: captures.keyframeId intentionally has no FOREIGN KEY
            // constraint. Adding one retroactively could break existing data where
            // keyframes have been pruned but their deltas remain (deltas carry
            // fullOcrText so they are self-contained). Pruning code handles
            // orphaned deltas gracefully.
        }

        migrator.registerMigration("v4_addEmbeddingColumn") { db in
            // Nullable embedding column for TF-IDF vectors for semantic search.
            // Stored as raw Float bytes in a BLOB. Nullable for gradual backfill
            // of existing summaries.
            try db.alter(table: "summaries") { t in
                t.add(column: "embedding", .blob)
            }
        }

        migrator.registerMigration("v5_addEnhancedMetadata") { db in
            try db.alter(table: "captures") { t in
                t.add(column: "documentPath", .text)
                t.add(column: "browserURL", .text)
                t.add(column: "focusedElementRole", .text)
            }
            // Partial indexes: only index non-null values (most captures will be null)
            try db.execute(sql: """
                CREATE INDEX idx_captures_document ON captures(documentPath)
                WHERE documentPath IS NOT NULL
                """)
            try db.execute(sql: """
                CREATE INDEX idx_captures_url ON captures(browserURL)
                WHERE browserURL IS NOT NULL
                """)
        }

        migrator.registerMigration("v6_createAppSessions") { db in
            try db.create(table: "app_sessions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("appName", .text).notNull()
                t.column("appBundleID", .text)
                t.column("startTimestamp", .double).notNull()
                t.column("endTimestamp", .double).notNull()
                t.column("captureCount", .integer).notNull().defaults(to: 0)
                t.column("windowTitles", .text)      // JSON array
                t.column("documentPaths", .text)     // JSON array
                t.column("browserURLs", .text)       // JSON array
                t.column("activityId", .integer)     // FK to activities (Phase 3)
                t.column("activityInferred", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "idx_app_sessions_time",
                          on: "app_sessions", columns: ["startTimestamp", "endTimestamp"])
            try db.create(index: "idx_app_sessions_app",
                          on: "app_sessions", columns: ["appBundleID"])
        }

        migrator.registerMigration("v7_createActivities") { db in
            try db.create(table: "activities") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("description", .text)
                t.column("startTimestamp", .double).notNull()
                t.column("endTimestamp", .double).notNull()
                t.column("keyTopics", .text)         // JSON array
                t.column("documentPaths", .text)     // JSON array
                t.column("browserURLs", .text)       // JSON array
                t.column("confidence", .double).notNull().defaults(to: 0.8)
                t.column("isActive", .boolean).notNull().defaults(to: true)
                t.column("parentActivityId", .integer)
                    .references("activities", onDelete: .setNull)
            }
            try db.create(index: "idx_activities_time",
                          on: "activities", columns: ["startTimestamp", "endTimestamp"])
            try db.create(index: "idx_activities_active",
                          on: "activities", columns: ["isActive"])

            try db.create(table: "activity_sessions") { t in
                t.column("activityId", .integer).notNull()
                    .references("activities", onDelete: .cascade)
                t.column("sessionId", .integer).notNull()
                    .references("app_sessions", onDelete: .cascade)
                t.primaryKey(["activityId", "sessionId"])
            }
        }

        migrator.registerMigration("v8_createActivityGraph") { db in
            try db.create(table: "activity_entities") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("activityId", .integer).notNull()
                    .references("activities", onDelete: .cascade)
                t.column("entityType", .text).notNull()  // file, url, topic, project
                t.column("entityValue", .text).notNull()
            }
            try db.create(index: "idx_activity_entities_value",
                          on: "activity_entities", columns: ["entityType", "entityValue"])
            try db.create(index: "idx_activity_entities_activity",
                          on: "activity_entities", columns: ["activityId"])

            try db.create(table: "activity_links") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("sourceActivityId", .integer).notNull()
                    .references("activities", onDelete: .cascade)
                t.column("targetActivityId", .integer).notNull()
                    .references("activities", onDelete: .cascade)
                t.column("linkType", .text).notNull()  // shared_file, shared_url, shared_topic, llm_inferred
                t.column("weight", .double).notNull().defaults(to: 1.0)
                t.column("sharedEntity", .text)
                t.column("createdAt", .double).notNull()
            }
            try db.create(index: "idx_activity_links_source",
                          on: "activity_links", columns: ["sourceActivityId"])
            try db.create(index: "idx_activity_links_target",
                          on: "activity_links", columns: ["targetActivityId"])
        }

        migrator.registerMigration("v9_createActivitiesFTS") { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE activities_fts USING fts5(
                    name,
                    description,
                    keyTopics,
                    content=activities,
                    content_rowid=id,
                    tokenize='porter unicode61'
                )
                """)

            try db.execute(sql: """
                CREATE TRIGGER activities_ai AFTER INSERT ON activities BEGIN
                    INSERT INTO activities_fts(rowid, name, description, keyTopics)
                    VALUES (new.id, new.name, new.description, new.keyTopics);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER activities_ad AFTER DELETE ON activities BEGIN
                    INSERT INTO activities_fts(activities_fts, rowid, name, description, keyTopics)
                    VALUES ('delete', old.id, old.name, old.description, old.keyTopics);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER activities_au AFTER UPDATE ON activities BEGIN
                    INSERT INTO activities_fts(activities_fts, rowid, name, description, keyTopics)
                    VALUES ('delete', old.id, old.name, old.description, old.keyTopics);
                    INSERT INTO activities_fts(rowid, name, description, keyTopics)
                    VALUES (new.id, new.name, new.description, new.keyTopics);
                END
                """)
        }

        migrator.registerMigration("v10_enrichSummaries") { db in
            // Store structured metadata extracted by the LLM alongside summaries.
            // Survives capture pruning so historical queries retain file/URL context.
            try db.alter(table: "summaries") { t in
                t.add(column: "documentPaths", .text)   // JSON array of file paths
                t.add(column: "browserURLs", .text)     // JSON array of URLs visited
                t.add(column: "activityType", .text)    // coding, research, communication, etc.
            }
        }

        return migrator
    }
}
