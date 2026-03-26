import Foundation

/// Single-pass enrichment strategy that eliminates the LLM relevance-filtering step.
///
/// Instead of two sequential LLM calls (Haiku for filtering, Sonnet for synthesis),
/// this strategy fetches summaries and captures from the database directly and sends
/// them to a single LLM call that performs both relevance filtering and context synthesis.
/// This halves the number of subprocess spawns, saving 5-10s per enrichment request.
final class SinglePassStrategy: EnrichmentStrategy, @unchecked Sendable {
    let name = "Single-Pass LLM"
    let strategyDescription = "DB retrieval + single LLM call for filtering and synthesis"

    private let logger = DualLogger(category: "SinglePass")

    /// Model for the single merged call.
    var model: String = "anthropic/claude-sonnet-4-6"

    /// Maximum summaries to include in the prompt.
    var maxSummaries: Int = 20

    /// Maximum unsummarized captures to include.
    var maxCaptures: Int = 30

    /// Max response tokens.
    var maxTokens: Int = 2048

    /// Capture formatting limits (reduced from two-pass defaults to keep prompt compact).
    var maxKeyframes: Int = 8
    var maxDeltasPerKeyframe: Int = 3
    var maxKeyframeTextLength: Int = 2000
    var maxDeltaTextLength: Int = 300

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func enrich(
        query: String,
        timeRange: TimeRange,
        storageManager: StorageManager,
        llmClient: LLMClient
    ) async throws -> EnrichedResult {
        let startTime = Date()

        // Step 1: Fetch summaries (FTS + recency) -- no LLM filtering
        let summaries = try fetchSummaries(
            query: query, timeRange: timeRange, storageManager: storageManager
        )

        // Step 2: Fetch unsummarized captures (FTS + recency)
        let captures = try fetchCaptures(
            query: query, timeRange: timeRange, storageManager: storageManager
        )

        guard !summaries.isEmpty || !captures.isEmpty else {
            logger.info("No summaries or captures found")
            return EnrichedResult(
                originalPrompt: query,
                enrichedPrompt: query + "\n\n_(No relevant context found from recent activity.)_",
                references: [],
                metadata: EnrichmentMetadata(
                    strategy: name, timeRange: timeRange,
                    summariesSearched: 0, capturesExamined: 0,
                    processingTime: Date().timeIntervalSince(startTime),
                    pass1Model: model, pass2Model: nil
                )
            )
        }

        // Step 3: Format both for the prompt
        let summariesText = formatSummaries(summaries)
        let capturesText = CaptureFormatter.formatHierarchical(
            captures: captures,
            maxKeyframes: maxKeyframes,
            maxDeltasPerKeyframe: maxDeltasPerKeyframe,
            maxKeyframeTextLength: maxKeyframeTextLength,
            maxDeltaTextLength: maxDeltaTextLength
        )

        // Step 4: Single LLM call
        let userPrompt = PromptTemplates.render(
            PromptTemplates.template(for: .enrichmentSinglePassUser),
            values: [
                "query": query,
                "summaries": summariesText.isEmpty ? "_(none)_" : summariesText,
                "captures": capturesText.isEmpty ? "_(none)_" : capturesText,
            ]
        )

        let systemPrompt = PromptTemplates.template(for: .enrichmentSinglePassSystem)

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
                id: nil,
                timestamp: Date().timeIntervalSince1970,
                caller: "enrichment_single_pass",
                model: model,
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens
            )
            _ = try? storageManager.insertTokenUsage(usageRecord)
            let cost = PromptTemplates.estimateCost(
                model: model, inputTokens: usage.inputTokens, outputTokens: usage.outputTokens
            )
            logger.debug("Single-pass \(cost)")
        }

        // Step 5: Build result
        let footnotes = response.text
        let enrichedPrompt: String
        if footnotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || footnotes.contains("No relevant context found") {
            enrichedPrompt = query + "\n\n_(No relevant context found from recent activity.)_"
        } else {
            enrichedPrompt = query + "\n\n---\n" + footnotes
        }

        let metadata = EnrichmentMetadata(
            strategy: name,
            timeRange: timeRange,
            summariesSearched: summaries.count,
            capturesExamined: captures.count,
            processingTime: Date().timeIntervalSince(startTime),
            pass1Model: model,
            pass2Model: nil
        )

        logger.info(
            "Single-pass complete: \(summaries.count) summaries, "
            + "\(captures.count) captures, "
            + "\(String(format: "%.1f", metadata.processingTime))s"
        )

        return EnrichedResult(
            originalPrompt: query,
            enrichedPrompt: enrichedPrompt,
            references: [],
            metadata: metadata
        )
    }

    // MARK: - DB Retrieval

    /// Fetch summaries via FTS + recency, deduplicated.
    private func fetchSummaries(
        query: String,
        timeRange: TimeRange,
        storageManager: StorageManager
    ) throws -> [SummaryRecord] {
        let halfLimit = maxSummaries / 2

        let ftsResults = try storageManager.searchSummaries(query: query, limit: halfLimit)
        let recentResults = try storageManager.summaries(
            from: timeRange.start, to: timeRange.end, limit: halfLimit
        )

        var seen = Set<Int64>()
        return (ftsResults + recentResults).filter { summary in
            guard let id = summary.id, !seen.contains(id) else { return false }
            seen.insert(id)
            return true
        }
    }

    /// Fetch unsummarized captures via FTS + recency, deduplicated.
    private func fetchCaptures(
        query: String,
        timeRange: TimeRange,
        storageManager: StorageManager
    ) throws -> [CaptureRecord] {
        let halfLimit = maxCaptures / 2

        let ftsResults = try storageManager.searchCaptures(query: query, limit: halfLimit)
            .filter { !$0.isSummarized }
        let recentResults = try storageManager.unsummarizedCaptures(
            from: timeRange.start, to: timeRange.end, limit: halfLimit
        )

        var seen = Set<Int64>()
        return (ftsResults + recentResults).filter { capture in
            guard let id = capture.id, !seen.contains(id) else { return false }
            seen.insert(id)
            return true
        }
    }

    // MARK: - Formatting

    /// Format summaries as numbered text blocks for the LLM prompt.
    private func formatSummaries(_ summaries: [SummaryRecord]) -> String {
        guard !summaries.isEmpty else { return "" }

        return summaries.enumerated().map { index, summary -> String in
            let apps = summary.decodedAppNames.joined(separator: ", ")
            let topics = summary.decodedKeyTopics.joined(separator: ", ")
            let id = summary.id ?? Int64(index)
            let start = dateFormatter.string(from: summary.startDate)
            let end = dateFormatter.string(from: summary.endDate)
            return "[\(id)]: \(start) - \(end)\n"
                + "Apps: \(apps)\n"
                + "Topics: \(topics)\n"
                + "Summary: \(summary.summary)"
        }.joined(separator: "\n\n")
    }
}
