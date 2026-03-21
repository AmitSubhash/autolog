import Foundation

/// Raw grouping result from LLM inference, before validation.
struct RawActivityGroup: Sendable {
    let name: String
    let description: String?
    let sessionIds: [Int64]
    let keyTopics: [String]
    let confidence: Double
}

/// Background engine that infers logical activities from app sessions.
/// Groups sessions into tasks (e.g., "Debugging contextd sleep-wake handling")
/// using LLM inference, then extracts entities and discovers cross-activity links.
actor ActivityInferenceEngine {
    private let storageManager: StorageManager
    private let llmClient: LLMClient
    private let logger = DualLogger(category: "ActivityInference")

    /// How often to check for uninferred sessions (seconds).
    var pollInterval: TimeInterval = 300  // 5 minutes

    /// Maximum time gap between sessions in the same batch (seconds).
    var batchWindowSize: TimeInterval = 7200  // 2 hours

    /// Min sessions per LLM batch.
    var minBatchSize: Int = 2

    /// Max sessions per LLM batch.
    var maxBatchSize: Int = 15

    /// Model for activity inference (cheap/fast).
    var model: String = "anthropic/claude-haiku-4-5"

    /// Max response tokens for inference calls.
    var maxTokens: Int = 2048

    private var isRunning = false
    private var task: Task<Void, Never>?

    init(storageManager: StorageManager, llmClient: LLMClient) {
        self.storageManager = storageManager
        self.llmClient = llmClient
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else {
            logger.info("Activity inference engine already running")
            return
        }
        isRunning = true
        logger.info("Activity inference engine started (poll: \(self.pollInterval)s)")

        task = Task {
            while !Task.isCancelled {
                await self.processUninferredSessions()
                try? await Task.sleep(nanoseconds: UInt64(self.pollInterval * 1_000_000_000))
            }
        }
    }

    func stop() {
        isRunning = false
        task?.cancel()
        task = nil
        logger.info("Activity inference engine stopped")
    }

    // MARK: - Processing

    private func processUninferredSessions() async {
        do {
            let sessions = try storageManager.uninferredSessions(limit: 100)
            guard !sessions.isEmpty else {
                logger.debug("No uninferred sessions found")
                return
            }

            logger.info("Found \(sessions.count) uninferred sessions")
            let batches = batchSessionsByTimeProximity(sessions)

            for batch in batches {
                guard batch.count >= minBatchSize else {
                    await createIndividualActivities(for: batch)
                    continue
                }
                do {
                    try await inferActivitiesForBatch(batch)
                } catch {
                    logger.error("Failed to infer batch: \(error.localizedDescription)")
                }
            }
        } catch {
            logger.error("Failed to fetch uninferred sessions: \(error.localizedDescription)")
        }
    }

    /// Split sessions into batches based on time proximity.
    private func batchSessionsByTimeProximity(
        _ sessions: [AppSessionRecord]
    ) -> [[AppSessionRecord]] {
        guard !sessions.isEmpty else { return [] }

        var batches: [[AppSessionRecord]] = []
        var current: [AppSessionRecord] = [sessions[0]]

        for i in 1..<sessions.count {
            let gap = sessions[i].startTimestamp - (current.last?.endTimestamp ?? 0)
            if gap <= batchWindowSize && current.count < maxBatchSize {
                current.append(sessions[i])
            } else {
                batches.append(current)
                current = [sessions[i]]
            }
        }
        if !current.isEmpty {
            batches.append(current)
        }
        return batches
    }

    // MARK: - LLM Inference

    private func inferActivitiesForBatch(_ sessions: [AppSessionRecord]) async throws {
        let validIds = Set(sessions.compactMap(\.id))
        let sessionText = ActivityGraphBuilder.formatSessionsForPrompt(
            sessions, storageManager: storageManager
        )

        let systemPrompt = PromptTemplates.template(for: .activityInferenceSystem)
        let userPrompt = PromptTemplates.render(
            PromptTemplates.template(for: .activityInferenceUser),
            values: ["sessions": sessionText]
        )

        let response = try await llmClient.completeWithUsage(
            messages: [LLMMessage(role: "user", content: userPrompt)],
            model: model,
            maxTokens: maxTokens,
            systemPrompt: systemPrompt,
            temperature: 0.0
        )

        // Record token usage
        if let usage = response.usage {
            let usageRecord = TokenUsageRecord(
                id: nil, timestamp: Date().timeIntervalSince1970,
                caller: "activity_inference", model: model,
                inputTokens: usage.inputTokens, outputTokens: usage.outputTokens
            )
            _ = try? storageManager.insertTokenUsage(usageRecord)
            let cost = PromptTemplates.estimateCost(
                model: model, inputTokens: usage.inputTokens, outputTokens: usage.outputTokens
            )
            logger.debug("Activity inference \(cost)")
        }

        let parsed = ActivityGraphBuilder.parseInferenceResponse(response.text, logger: logger)
        let validated = validateInferenceResponse(parsed: parsed, validSessionIds: validIds)

        let sessionMap = Dictionary(uniqueKeysWithValues: sessions.compactMap { s in
            s.id.map { ($0, s) }
        })

        // Create activities FIRST, then mark sessions as inferred.
        // If creation fails mid-loop, unmarked sessions will be retried next cycle.
        // Duplicate activities are prevented by the validation layer (first-claim-wins).
        for group in validated {
            try createActivityFromGroup(group, sessionMap: sessionMap)
        }

        try storageManager.markSessionsAsInferred(ids: Array(validIds))
        logger.info("Inferred \(validated.count) activities from \(sessions.count) sessions")
    }

    /// Create individual activities for sessions that don't need LLM grouping.
    private func createIndividualActivities(for sessions: [AppSessionRecord]) async {
        for session in sessions {
            guard let sessionId = session.id else { continue }
            let group = RawActivityGroup(
                name: "Session: \(session.appName)",
                description: nil,
                sessionIds: [sessionId],
                keyTopics: [],
                confidence: 0.5
            )
            do {
                try createActivityFromGroup(group, sessionMap: [sessionId: session])
                try storageManager.markSessionsAsInferred(ids: [sessionId])
            } catch {
                logger.error("Failed to create individual activity: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Activity Creation

    private func createActivityFromGroup(
        _ group: RawActivityGroup,
        sessionMap: [Int64: AppSessionRecord]
    ) throws {
        let groupSessions = group.sessionIds.compactMap { sessionMap[$0] }
        guard !groupSessions.isEmpty else { return }

        let startTs = groupSessions.map(\.startTimestamp).min() ?? 0
        let endTs = groupSessions.map(\.endTimestamp).max() ?? 0

        let allDocPaths = Array(Set(groupSessions.flatMap(\.decodedDocumentPaths)))
        let allURLs = Array(Set(groupSessions.flatMap(\.decodedBrowserURLs)))

        let topicsJSON = try String(
            data: JSONEncoder().encode(group.keyTopics), encoding: .utf8
        ) ?? "[]"
        let docsJSON = try String(
            data: JSONEncoder().encode(allDocPaths), encoding: .utf8
        ) ?? "[]"
        let urlsJSON = try String(
            data: JSONEncoder().encode(allURLs), encoding: .utf8
        ) ?? "[]"

        var activity = ActivityRecord(
            id: nil, name: group.name, description: group.description,
            startTimestamp: startTs, endTimestamp: endTs,
            keyTopics: topicsJSON, documentPaths: docsJSON, browserURLs: urlsJSON,
            confidence: group.confidence, isActive: true, parentActivityId: nil
        )
        activity = try storageManager.insertActivity(activity)

        guard let activityId = activity.id else { return }

        for sessionId in group.sessionIds {
            try storageManager.insertActivitySession(
                ActivitySessionRecord(activityId: activityId, sessionId: sessionId)
            )
        }

        try ActivityGraphBuilder.extractEntities(
            for: activityId, group: group,
            docPaths: allDocPaths, urls: allURLs,
            storageManager: storageManager
        )
        try ActivityGraphBuilder.discoverLinks(
            for: activityId, storageManager: storageManager
        )
    }

    // MARK: - Validation

    func validateInferenceResponse(
        parsed: [RawActivityGroup],
        validSessionIds: Set<Int64>
    ) -> [RawActivityGroup] {
        var claimed = Set<Int64>()
        var validated: [RawActivityGroup] = []

        for group in parsed {
            let clean = group.sessionIds.filter { validSessionIds.contains($0) }
            let unique = clean.filter { !claimed.contains($0) }
            guard !unique.isEmpty else { continue }
            claimed.formUnion(unique)
            validated.append(RawActivityGroup(
                name: group.name, description: group.description,
                sessionIds: unique, keyTopics: group.keyTopics,
                confidence: group.confidence
            ))
        }

        // Orphan rescue: unclaimed sessions become individual activities
        let orphans = validSessionIds.subtracting(claimed)
        for orphanId in orphans {
            validated.append(RawActivityGroup(
                name: "Untitled session",
                description: nil,
                sessionIds: [orphanId],
                keyTopics: [],
                confidence: 0.3
            ))
        }
        return validated
    }
}
