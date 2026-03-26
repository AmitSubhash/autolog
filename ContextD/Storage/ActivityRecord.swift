import Foundation
import GRDB

/// Database record for an inferred activity -- a logical task spanning one or more app sessions.
struct ActivityRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// Auto-incremented primary key
    var id: Int64?

    /// Human-readable name for this activity (e.g., "Debugging autolog sleep-wake handling")
    var name: String

    /// Optional longer description of the activity
    var description: String?

    /// Unix timestamp when the activity started
    var startTimestamp: Double

    /// Unix timestamp when the activity ended
    var endTimestamp: Double

    /// JSON array of key topics extracted from the activity
    var keyTopics: String?

    /// JSON array of document paths involved in the activity
    var documentPaths: String?

    /// JSON array of browser URLs involved in the activity
    var browserURLs: String?

    /// Confidence score from the LLM inference (0.0-1.0)
    var confidence: Double

    /// Whether the activity is still ongoing
    var isActive: Bool

    /// Optional parent activity for hierarchical grouping
    var parentActivityId: Int64?

    // MARK: - Table mapping

    static let databaseTableName = "activities"

    enum Columns: String, ColumnExpression {
        case id, name, description
        case startTimestamp, endTimestamp
        case keyTopics, documentPaths, browserURLs
        case confidence, isActive, parentActivityId
    }

    // MARK: - Record lifecycle

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Convenience accessors

extension ActivityRecord {
    var decodedKeyTopics: [String] {
        guard let json = keyTopics,
              let data = json.data(using: .utf8),
              let topics = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return topics
    }

    var decodedDocumentPaths: [String] {
        guard let json = documentPaths,
              let data = json.data(using: .utf8),
              let paths = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return paths
    }

    var decodedBrowserURLs: [String] {
        guard let json = browserURLs,
              let data = json.data(using: .utf8),
              let urls = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return urls
    }

    var startDate: Date {
        Date(timeIntervalSince1970: startTimestamp)
    }

    var endDate: Date {
        Date(timeIntervalSince1970: endTimestamp)
    }

    var duration: TimeInterval {
        endTimestamp - startTimestamp
    }
}

// MARK: - Activity Session Join Record

/// Join table linking activities to app sessions.
struct ActivitySessionRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    var activityId: Int64
    var sessionId: Int64

    static let databaseTableName = "activity_sessions"

    enum Columns: String, ColumnExpression {
        case activityId, sessionId
    }
}

// MARK: - Activity Entity Record

/// An entity (file, URL, topic, project) associated with an activity.
struct ActivityEntityRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    var id: Int64?
    var activityId: Int64
    var entityType: String   // file, url, topic, project
    var entityValue: String

    static let databaseTableName = "activity_entities"

    enum Columns: String, ColumnExpression {
        case id, activityId, entityType, entityValue
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Activity Link Record

/// A link between two activities based on shared entities or LLM inference.
struct ActivityLinkRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    var id: Int64?
    var sourceActivityId: Int64
    var targetActivityId: Int64
    var linkType: String     // shared_file, shared_url, shared_topic, llm_inferred
    var weight: Double
    var sharedEntity: String?
    var createdAt: Double

    static let databaseTableName = "activity_links"

    enum Columns: String, ColumnExpression {
        case id, sourceActivityId, targetActivityId
        case linkType, weight, sharedEntity, createdAt
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
