import Foundation
import GRDB

/// App session query and insertion methods for StorageManager.
extension StorageManager {

    private static let sessionLogger = DualLogger(category: "Storage+Sessions")

    // MARK: - Insert

    /// Insert a new app session record.
    @discardableResult
    func insertAppSession(_ session: AppSessionRecord) throws -> AppSessionRecord {
        var record = session
        try database.dbPool.write { db in
            try record.insert(db)
        }
        Self.sessionLogger.debug("Inserted app session id=\(record.id ?? -1) app=\(record.appName)")
        return record
    }

    // MARK: - Queries

    /// Fetch app sessions in a time range, with optional app filtering and pagination.
    func appSessions(
        from startDate: Date,
        to endDate: Date,
        appBundleID: String? = nil,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [AppSessionRecord] {
        try database.dbPool.read { db in
            var query = AppSessionRecord
                .filter(AppSessionRecord.Columns.endTimestamp >= startDate.timeIntervalSince1970)
                .filter(AppSessionRecord.Columns.startTimestamp <= endDate.timeIntervalSince1970)
                .order(AppSessionRecord.Columns.startTimestamp.desc)

            if let bundleID = appBundleID, !bundleID.isEmpty {
                query = query.filter(AppSessionRecord.Columns.appBundleID == bundleID)
            }

            if let limit = limit {
                query = query.limit(limit, offset: offset)
            } else if offset > 0 {
                query = query.limit(-1, offset: offset)
            }

            return try query.fetchAll(db)
        }
    }

    /// Fetch captures that belong to a given app session (same app, within time range).
    func capturesForSession(_ session: AppSessionRecord) throws -> [CaptureRecord] {
        try database.dbPool.read { db in
            var query = CaptureRecord
                .filter(CaptureRecord.Columns.timestamp >= session.startTimestamp)
                .filter(CaptureRecord.Columns.timestamp <= session.endTimestamp)
                .order(CaptureRecord.Columns.timestamp.asc)

            if let bundleID = session.appBundleID {
                query = query.filter(CaptureRecord.Columns.appBundleID == bundleID)
            } else {
                query = query.filter(CaptureRecord.Columns.appName == session.appName)
            }

            return try query.fetchAll(db)
        }
    }

    /// Aggregate app usage within a time range: total seconds and session count per app.
    /// Returns results sorted by total seconds descending.
    func appUsageSummary(
        from startDate: Date,
        to endDate: Date
    ) throws -> [(appName: String, totalSeconds: Double, sessionCount: Int)] {
        try database.dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT appName,
                       SUM(endTimestamp - startTimestamp) AS totalSeconds,
                       COUNT(*) AS sessionCount
                FROM app_sessions
                WHERE endTimestamp >= ? AND startTimestamp <= ?
                GROUP BY appName
                ORDER BY totalSeconds DESC
                """, arguments: [
                    startDate.timeIntervalSince1970,
                    endDate.timeIntervalSince1970,
                ])

            return rows.map { row in
                (
                    appName: row["appName"] as String,
                    totalSeconds: row["totalSeconds"] as Double,
                    sessionCount: row["sessionCount"] as Int
                )
            }
        }
    }
}
