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

    static func isLikelyURL(_ value: String) -> Bool {
        let lower = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.hasPrefix("http://")
            || lower.hasPrefix("https://")
            || lower.hasPrefix("chrome://")
            || lower.hasPrefix("file://")
            || lower.hasPrefix("about:")
            || lower.hasPrefix("www.")
    }

    static func normalizeEntities(
        documentPaths: [String],
        browserURLs: [String],
        topics: [String]
    ) -> (files: [String], urls: [String], topics: [String]) {
        var files = Set<String>()
        var urls = Set<String>()
        var cleanTopics = Set<String>()

        for value in documentPaths.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            guard !value.isEmpty, !isNoiseEntity(value) else { continue }
            if isLikelyURL(value) {
                urls.insert(value)
            } else {
                files.insert(value)
            }
        }

        for value in browserURLs.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            guard !value.isEmpty, !isNoiseEntity(value) else { continue }
            if isLikelyURL(value) {
                urls.insert(value)
            } else {
                files.insert(value)
            }
        }

        for topic in topics.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            guard !topic.isEmpty, !isNoiseEntity(topic) else { continue }
            cleanTopics.insert(topic)
        }

        return (Array(files).sorted(), Array(urls).sorted(), Array(cleanTopics).sorted())
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
        let normalized = normalizeEntities(
            documentPaths: docPaths,
            browserURLs: urls,
            topics: group.keyTopics
        )

        for path in normalized.files {
            let filename = (path as NSString).lastPathComponent
            guard !isNoiseEntity(filename) else { continue }
            try storageManager.insertActivityEntity(
                ActivityEntityRecord(
                    id: nil, activityId: activityId,
                    entityType: "file", entityValue: path
                )
            )
        }
        for url in normalized.urls {
            try storageManager.insertActivityEntity(
                ActivityEntityRecord(
                    id: nil, activityId: activityId,
                    entityType: "url", entityValue: url
                )
            )
        }
        for topic in normalized.topics {
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

    static func backfillGraph(
        storageManager: StorageManager,
        logger: DualLogger,
        limit: Int = 5000
    ) throws -> (activities: Int, entities: Int, links: Int) {
        let activities = try storageManager.allActivities(limit: limit)
        var entityCount = 0
        var linkCount = 0

        for activity in activities {
            guard let activityId = activity.id else { continue }

            let normalized = normalizeEntities(
                documentPaths: activity.decodedDocumentPaths,
                browserURLs: activity.decodedBrowserURLs,
                topics: activity.decodedKeyTopics
            )

            let beforeEntities = try storageManager.entityCount(for: activityId)
            let beforeLinks = try storageManager.linkCount(for: activityId)

            for path in normalized.files {
                try storageManager.insertActivityEntity(
                    ActivityEntityRecord(
                        id: nil,
                        activityId: activityId,
                        entityType: "file",
                        entityValue: path
                    )
                )
            }

            for url in normalized.urls {
                try storageManager.insertActivityEntity(
                    ActivityEntityRecord(
                        id: nil,
                        activityId: activityId,
                        entityType: "url",
                        entityValue: url
                    )
                )
            }

            for topic in normalized.topics {
                try storageManager.insertActivityEntity(
                    ActivityEntityRecord(
                        id: nil,
                        activityId: activityId,
                        entityType: "topic",
                        entityValue: topic
                    )
                )
            }

            try discoverLinks(for: activityId, storageManager: storageManager)

            let afterEntities = try storageManager.entityCount(for: activityId)
            let afterLinks = try storageManager.linkCount(for: activityId)
            entityCount += max(0, afterEntities - beforeEntities)
            linkCount += max(0, afterLinks - beforeLinks)
        }

        logger.info(
            "Graph backfill complete: activities=\(activities.count), entities_added=\(entityCount), links_added=\(linkCount)"
        )
        return (activities.count, entityCount, linkCount)
    }

    // MARK: - Response Parsing

    /// Parse the LLM JSON response into raw activity groups.
    static func parseInferenceResponse(
        _ response: String,
        logger: DualLogger
    ) -> [RawActivityGroup] {
        let cleaned = RetrievalPipeline.stripCodeFences(response)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let activities = extractActivitiesPayload(from: cleaned) else {
            let firstChar = cleaned.first.map(String.init) ?? "none"
            logger.warning(
                "Failed to parse activity inference response as JSON "
                    + "(chars=\(cleaned.count), first_char=\(firstChar), "
                    + "has_activities_key=\(cleaned.contains("\"activities\"")))"
            )
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

    private static func extractActivitiesPayload(from text: String) -> [[String: Any]]? {
        if let root = parseJSONObject(text),
           let activities = root["activities"] as? [[String: Any]] {
            return activities
        }

        if let array = parseJSONArray(text) {
            return array
        }

        for candidate in extractJSONObjectCandidates(from: text) {
            if let root = parseJSONObject(candidate),
               let activities = root["activities"] as? [[String: Any]] {
                return activities
            }
        }

        return nil
    }

    private static func parseJSONObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private static func parseJSONArray(_ text: String) -> [[String: Any]]? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        return json
    }

    private static func extractJSONObjectCandidates(from text: String) -> [String] {
        var candidates: [String] = []
        var depth = 0
        var startIndex: String.Index?
        var inString = false
        var escape = false

        for index in text.indices {
            let char = text[index]

            if inString {
                if escape {
                    escape = false
                    continue
                }
                if char == "\\" {
                    escape = true
                    continue
                }
                if char == "\"" {
                    inString = false
                }
                continue
            }

            if char == "\"" {
                inString = true
                continue
            }

            if char == "{" {
                if depth == 0 {
                    startIndex = index
                }
                depth += 1
                continue
            }

            if char == "}" {
                guard depth > 0 else { continue }
                depth -= 1
                if depth == 0, let candidateStart = startIndex {
                    candidates.append(String(text[candidateStart...index]))
                    startIndex = nil
                }
            }
        }

        return candidates
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
