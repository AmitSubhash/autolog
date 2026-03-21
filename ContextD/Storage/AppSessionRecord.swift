import Foundation
import GRDB

/// Database record for an app session -- a contiguous stretch where the same
/// app is frontmost. Brief interruptions (< gap tolerance) do not break a session.
struct AppSessionRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// Auto-incremented primary key
    var id: Int64?

    /// Name of the frontmost application during this session
    var appName: String

    /// Bundle identifier of the frontmost application
    var appBundleID: String?

    /// Unix timestamp when the session started
    var startTimestamp: Double

    /// Unix timestamp when the session ended
    var endTimestamp: Double

    /// Number of captures recorded during this session
    var captureCount: Int

    /// JSON array of unique window titles seen during the session
    var windowTitles: String?

    /// JSON array of unique document paths seen during the session
    var documentPaths: String?

    /// JSON array of unique browser URLs seen during the session
    var browserURLs: String?

    /// Foreign key to activities table (Phase 3)
    var activityId: Int64?

    /// Whether the activity was inferred by the LLM
    var activityInferred: Bool

    // MARK: - Table mapping

    static let databaseTableName = "app_sessions"

    enum Columns: String, ColumnExpression {
        case id, appName, appBundleID
        case startTimestamp, endTimestamp, captureCount
        case windowTitles, documentPaths, browserURLs
        case activityId, activityInferred
    }

    // MARK: - Record lifecycle

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Convenience accessors

extension AppSessionRecord {
    /// Decode the window titles JSON to an array of strings.
    var decodedWindowTitles: [String] {
        guard let json = windowTitles,
              let data = json.data(using: .utf8),
              let titles = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return titles
    }

    /// Decode the document paths JSON to an array of strings.
    var decodedDocumentPaths: [String] {
        guard let json = documentPaths,
              let data = json.data(using: .utf8),
              let paths = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return paths
    }

    /// Decode the browser URLs JSON to an array of strings.
    var decodedBrowserURLs: [String] {
        guard let json = browserURLs,
              let data = json.data(using: .utf8),
              let urls = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return urls
    }

    /// Start date
    var startDate: Date {
        Date(timeIntervalSince1970: startTimestamp)
    }

    /// End date
    var endDate: Date {
        Date(timeIntervalSince1970: endTimestamp)
    }

    /// Duration of this session in seconds.
    var duration: TimeInterval {
        endTimestamp - startTimestamp
    }
}
