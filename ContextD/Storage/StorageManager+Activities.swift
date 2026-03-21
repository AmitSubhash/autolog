import Foundation
import GRDB

/// Activity query and insertion methods for StorageManager.
extension StorageManager {

    private static let activityLogger = DualLogger(category: "Storage+Activities")

    // MARK: - Insert

    /// Insert a new activity record.
    @discardableResult
    func insertActivity(_ activity: ActivityRecord) throws -> ActivityRecord {
        var record = activity
        try database.dbPool.write { db in
            try record.insert(db)
        }
        Self.activityLogger.debug(
            "Inserted activity id=\(record.id ?? -1) name=\(record.name)"
        )
        return record
    }

    /// Insert an activity-session join record, ignoring duplicates.
    func insertActivitySession(_ record: ActivitySessionRecord) throws {
        var rec = record
        try database.dbPool.write { db in
            try rec.insert(db, onConflict: .ignore)
        }
    }

    /// Insert an activity entity record.
    func insertActivityEntity(_ entity: ActivityEntityRecord) throws {
        var record = entity
        try database.dbPool.write { db in
            try record.insert(db)
        }
    }

    /// Insert an activity link, ignoring duplicates (INSERT OR IGNORE semantics).
    func insertActivityLink(_ link: ActivityLinkRecord) throws {
        try database.dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO activity_links
                    (sourceActivityId, targetActivityId, linkType, weight, sharedEntity, createdAt)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    link.sourceActivityId, link.targetActivityId,
                    link.linkType, link.weight,
                    link.sharedEntity, link.createdAt,
                ]
            )
        }
    }

    /// Mark sessions as having been processed for activity inference.
    func markSessionsAsInferred(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try database.dbPool.write { db in
            try AppSessionRecord
                .filter(ids.contains(AppSessionRecord.Columns.id))
                .updateAll(db, AppSessionRecord.Columns.activityInferred.set(to: true))
        }
    }


    /// Fetch sessions that have not yet been processed for activity inference.
    func uninferredSessions(limit: Int = 100) throws -> [AppSessionRecord] {
        try database.dbPool.read { db in
            try AppSessionRecord
                .filter(AppSessionRecord.Columns.activityInferred == false)
                .order(AppSessionRecord.Columns.startTimestamp.asc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    // MARK: - Activity Queries

    /// Fetch activities in a time range with optional pagination.
    func activities(
        from startDate: Date,
        to endDate: Date,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [ActivityRecord] {
        try database.dbPool.read { db in
            var query = ActivityRecord
                .filter(ActivityRecord.Columns.endTimestamp >= startDate.timeIntervalSince1970)
                .filter(ActivityRecord.Columns.startTimestamp <= endDate.timeIntervalSince1970)
                .order(ActivityRecord.Columns.startTimestamp.desc)

            if let limit = limit {
                query = query.limit(limit, offset: offset)
            } else if offset > 0 {
                query = query.limit(-1, offset: offset)
            }

            return try query.fetchAll(db)
        }
    }

    /// Fetch currently active activities (isActive = true).
    func activeActivities() throws -> [ActivityRecord] {
        try database.dbPool.read { db in
            try ActivityRecord
                .filter(ActivityRecord.Columns.isActive == true)
                .order(ActivityRecord.Columns.startTimestamp.desc)
                .fetchAll(db)
        }
    }

    /// Fetch app sessions that belong to a given activity.
    func sessionsForActivity(_ activityId: Int64) throws -> [AppSessionRecord] {
        try database.dbPool.read { db in
            try AppSessionRecord.fetchAll(db, sql: """
                SELECT s.* FROM app_sessions s
                JOIN activity_sessions a ON a.sessionId = s.id
                WHERE a.activityId = ?
                ORDER BY s.startTimestamp ASC
                """, arguments: [activityId])
        }
    }

    /// Fetch entities for a given activity.
    func entitiesForActivity(_ activityId: Int64) throws -> [ActivityEntityRecord] {
        try database.dbPool.read { db in
            try ActivityEntityRecord
                .filter(ActivityEntityRecord.Columns.activityId == activityId)
                .fetchAll(db)
        }
    }

    /// Fetch links originating from or targeting a given activity.
    func linksForActivity(_ activityId: Int64) throws -> [ActivityLinkRecord] {
        try database.dbPool.read { db in
            try ActivityLinkRecord.fetchAll(db, sql: """
                SELECT * FROM activity_links
                WHERE sourceActivityId = ? OR targetActivityId = ?
                ORDER BY createdAt DESC
                """, arguments: [activityId, activityId])
        }
    }

    /// Fetch related activities by following links from a given activity.
    func relatedActivities(_ activityId: Int64, limit: Int = 10) throws -> [ActivityRecord] {
        try database.dbPool.read { db in
            try ActivityRecord.fetchAll(db, sql: """
                SELECT a.*, MAX(l.weight) AS max_weight FROM activities a
                JOIN activity_links l ON (
                    (l.sourceActivityId = ? AND l.targetActivityId = a.id)
                    OR (l.targetActivityId = ? AND l.sourceActivityId = a.id)
                )
                WHERE a.id != ?
                GROUP BY a.id
                ORDER BY max_weight DESC
                LIMIT ?
                """, arguments: [activityId, activityId, activityId, limit])
        }
    }

    /// Fetch activities involving a specific entity (type + value).
    func activitiesForEntity(type: String, value: String) throws -> [ActivityRecord] {
        try database.dbPool.read { db in
            try ActivityRecord.fetchAll(db, sql: """
                SELECT DISTINCT a.* FROM activities a
                JOIN activity_entities e ON e.activityId = a.id
                WHERE e.entityType = ? AND e.entityValue = ?
                ORDER BY a.startTimestamp DESC
                """, arguments: [type, value])
        }
    }

    /// Search activities via FTS5 full-text search.
    func searchActivities(query: String, limit: Int = 20) throws -> [ActivityRecord] {
        let ftsQuery = sanitizeFTSQuery(query)
        guard !ftsQuery.isEmpty else { return [] }

        return try database.dbPool.read { db in
            let sql = """
                SELECT activities.*
                FROM activities
                JOIN activities_fts ON activities.id = activities_fts.rowid
                WHERE activities_fts MATCH ?
                ORDER BY rank
                LIMIT ?
                """
            return try ActivityRecord.fetchAll(db, sql: sql, arguments: [ftsQuery, limit])
        }
    }

    /// Fetch the full activity graph (activities + links) for a time range.
    func activityGraph(
        from startDate: Date,
        to endDate: Date
    ) throws -> (activities: [ActivityRecord], links: [ActivityLinkRecord]) {
        try database.dbPool.read { db in
            let acts = try ActivityRecord
                .filter(ActivityRecord.Columns.endTimestamp >= startDate.timeIntervalSince1970)
                .filter(ActivityRecord.Columns.startTimestamp <= endDate.timeIntervalSince1970)
                .order(ActivityRecord.Columns.startTimestamp.desc)
                .fetchAll(db)

            let actIds = acts.compactMap(\.id)
            guard !actIds.isEmpty else { return (acts, []) }

            // Use parameterized placeholders to prevent SQL injection
            let placeholders = actIds.map { _ in "?" }.joined(separator: ",")
            let args = actIds.flatMap { [$0 as DatabaseValueConvertible, $0 as DatabaseValueConvertible] }
            let links = try ActivityLinkRecord.fetchAll(db, sql: """
                SELECT * FROM activity_links
                WHERE sourceActivityId IN (\(placeholders))
                   OR targetActivityId IN (\(placeholders))
                ORDER BY createdAt DESC
                """, arguments: StatementArguments(args))

            return (acts, links)
        }
    }
}
