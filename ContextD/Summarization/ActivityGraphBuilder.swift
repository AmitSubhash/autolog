import Foundation

/// Helper utilities for entity extraction, link discovery, and prompt
/// formatting used by ActivityInferenceEngine. Split out to keep the
/// engine file under 300 lines.
enum ActivityGraphBuilder {

    // MARK: - Noise Entity Filtering

    /// Terminal tab names, usernames, and directory names that should not
    /// be stored as entities. Checked case-insensitively.
    private static let noiseEntities: Set<String> = [
        "amit", "atsubhas", "stanford_hardi", "stanford hardi",
        "about:blank", "unknown", "untitled", "loginwindow",
        "securityagent",
    ]

    /// Returns true if a value is noise (terminal tab name, username, etc.)
    /// that should be filtered out before inserting into the entity graph.
    static func isNoiseEntity(_ value: String) -> Bool {
        let lower = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.isEmpty || lower.count < 2 { return true }
        if noiseEntities.contains(lower) { return true }
        // Filter UUID-like strings
        let uuidPattern = #"^[0-9a-f]{8}-[0-9a-f]{4}-"#
        if lower.range(of: uuidPattern, options: .regularExpression) != nil { return true }
        return false
    }

    // MARK: - Entity Extraction (deterministic, no LLM)

    /// Extract entities from an activity's sessions and insert them into the database.
    /// Filters out noise entities (terminal tab names, usernames) before insertion.
    static func extractEntities(
        for activityId: Int64,
        group: RawActivityGroup,
        docPaths: [String],
        urls: [String],
        storageManager: StorageManager
    ) throws {
        for path in docPaths {
            let filename = (path as NSString).lastPathComponent
            guard !isNoiseEntity(filename) else { continue }
            try storageManager.insertActivityEntity(
                ActivityEntityRecord(
                    id: nil, activityId: activityId,
                    entityType: "file", entityValue: path
                )
            )
        }
        for url in urls {
            guard !isNoiseEntity(url) else { continue }
            try storageManager.insertActivityEntity(
                ActivityEntityRecord(
                    id: nil, activityId: activityId,
                    entityType: "url", entityValue: url
                )
            )
        }
        for topic in group.keyTopics {
            guard !isNoiseEntity(topic) else { continue }
            try storageManager.insertActivityEntity(
                ActivityEntityRecord(
                    id: nil, activityId: activityId,
                    entityType: "topic", entityValue: topic
                )
            )
        }
    }

    // MARK: - Link Discovery (deterministic)

    /// Find shared entities between the given activity and all other activities,
    /// then insert link records (INSERT OR IGNORE for idempotency).
    static func discoverLinks(
        for activityId: Int64,
        storageManager: StorageManager
    ) throws {
        let entities = try storageManager.entitiesForActivity(activityId)
        let now = Date().timeIntervalSince1970

        for entity in entities {
            let relatedActivities = try storageManager.activitiesForEntity(
                type: entity.entityType, value: entity.entityValue
            )
            for related in relatedActivities {
                guard let relatedId = related.id, relatedId != activityId else { continue }
                let linkType = "shared_\(entity.entityType)"
                try storageManager.insertActivityLink(ActivityLinkRecord(
                    id: nil, sourceActivityId: activityId, targetActivityId: relatedId,
                    linkType: linkType, weight: 1.0,
                    sharedEntity: entity.entityValue, createdAt: now
                ))
            }
        }
    }

    // MARK: - Response Parsing

    /// Parse the LLM JSON response into raw activity groups.
    static func parseInferenceResponse(
        _ response: String,
        logger: DualLogger
    ) -> [RawActivityGroup] {
        let cleaned = RetrievalPipeline.stripCodeFences(response)
        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let activities = json["activities"] as? [[String: Any]] else {
            logger.warning("Failed to parse activity inference response as JSON")
            return []
        }

        return activities.compactMap { dict in
            guard let name = dict["name"] as? String,
                  let sessionIds = dict["session_ids"] as? [Int] else { return nil }
            return RawActivityGroup(
                name: name,
                description: dict["description"] as? String,
                sessionIds: sessionIds.map { Int64($0) },
                keyTopics: dict["key_topics"] as? [String] ?? [],
                confidence: dict["confidence"] as? Double ?? 0.8
            )
        }
    }

    // MARK: - Prompt Formatting

    /// Format sessions into a text block suitable for the LLM prompt.
    static func formatSessionsForPrompt(
        _ sessions: [AppSessionRecord],
        storageManager: StorageManager
    ) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm"

        return sessions.compactMap { session -> String? in
            guard let id = session.id else { return nil }
            let startStr = dateFormatter.string(from: session.startDate)
            let endStr = dateFormatter.string(from: session.endDate)

            var parts = [
                "Session \(id): \(session.appName) [\(startStr)-\(endStr)]",
            ]

            let titles = session.decodedWindowTitles
            if !titles.isEmpty {
                parts.append("  Windows: \(titles.prefix(3).joined(separator: ", "))")
            }
            let docs = session.decodedDocumentPaths
            if !docs.isEmpty {
                parts.append("  Files: \(docs.prefix(3).joined(separator: ", "))")
            }
            let urls = session.decodedBrowserURLs
            if !urls.isEmpty {
                parts.append("  URLs: \(urls.prefix(3).joined(separator: ", "))")
            }

            if let summaryText = overlappingSummaryText(for: session, storageManager: storageManager) {
                parts.append("  Summary: \(summaryText)")
            }

            return parts.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// Get summary text overlapping with a session's time range (public accessor).
    static func overlappingSummaryTextPublic(
        for session: AppSessionRecord,
        storageManager: StorageManager
    ) -> String? {
        return overlappingSummaryText(for: session, storageManager: storageManager)
    }

    /// Get summary text overlapping with a session's time range.
    private static func overlappingSummaryText(
        for session: AppSessionRecord,
        storageManager: StorageManager
    ) -> String? {
        let summaries = try? storageManager.summaries(
            from: session.startDate, to: session.endDate, limit: 3
        )
        guard let summaries = summaries, !summaries.isEmpty else { return nil }
        let text = summaries.map(\.summary).joined(separator: " ")
        return text.count > 500 ? String(text.prefix(500)) + "..." : text
    }
}
