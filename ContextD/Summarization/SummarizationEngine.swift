import Foundation

/// Controls summarization backend. All modes route through claude -p proxy.
enum SummarizationMode: String, CaseIterable, Sendable {
    /// Standard cloud summarization via claude -p proxy with Haiku.
    case cloud
    /// Reserved for future local-only mode.
    case local
    /// Reserved for future hybrid mode.
    case hybrid

    /// UserDefaults key for persisting the selected mode.
    static let defaultsKey = "summarizationMode"

    /// Read the current mode from UserDefaults, defaulting to `.cloud`.
    static var current: SummarizationMode {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let mode = SummarizationMode(rawValue: raw) else {
            return .cloud
        }
        return mode
    }
}

/// Background engine that progressively summarizes captured screen content.
/// Runs periodically, picks up unsummarized captures, chunks them, and
/// summarizes each chunk using the configured SummarizationMode.
actor SummarizationEngine {
    private let storageManager: StorageManager
    private let llmClient: LLMClient
    private let logger = DualLogger(category: "Summarization")

    /// Active summarization mode. Defaults to .cloud (uses claude -p proxy).
    var mode: SummarizationMode = .cloud

    /// How often to check for unsummarized captures (seconds).
    var pollInterval: TimeInterval = 60

    /// Minimum age of captures before summarizing (seconds).
    /// 5 min balances freshness with having enough context per chunk.
    var minimumAge: TimeInterval = 300 // 5 minutes

    /// Duration of each summarization time window (seconds).
    /// 5 min chunks for faster feedback. Cost ~$0.002/call, ~12 calls/hour.
    var chunkDuration: TimeInterval = 300 // 5 minutes

    /// Minimum sub-chunk duration when splitting at app boundaries (seconds).
    /// 60s prevents micro-summaries from rapid app switching.
    var minimumChunkDuration: TimeInterval = 60

    /// The model to use for summarization (cheap/fast).
    var model: String = "anthropic/claude-haiku-4-5"

    /// Maximum OCR text samples to include per chunk (to stay within token limits).
    var maxSamplesPerChunk: Int = 10

    /// Max response tokens for summarization LLM calls.
    var maxTokens: Int = 1024

    /// Max deltas per keyframe in formatted output.
    var maxDeltasPerKeyframe: Int = 3

    /// Max keyframe text length in formatted output.
    var maxKeyframeTextLength: Int = 2000

    /// Max delta text length in formatted output.
    /// Increased from 300 to 500 (avg delta is ~519 chars, was truncating most deltas).
    var maxDeltaTextLength: Int = 500

    /// Maximum total characters of formatted OCR text to send per chunk.
    /// At ~4 chars per token this is roughly 1000 input tokens of OCR content.
    /// Increased from 2000 to 4000 to reduce information loss during summarization.
    var maxInputCharsPerChunk: Int = 4000

    /// Maximum chunks per poll cycle. With ~70s per claude -p call and 60s poll interval,
    /// only 1 chunk can realistically complete per cycle.
    var maxChunksPerCycle: Int = 3

    private var isRunning = false
    private var task: Task<Void, Never>?

    /// Counter for poll cycles, used to throttle periodic maintenance tasks
    /// like pruning processed captures (runs every 10 cycles, ~10 minutes).
    private var pollCycleCount: Int = 0

    init(storageManager: StorageManager, llmClient: LLMClient) {
        self.storageManager = storageManager
        self.llmClient = llmClient
        self.mode = SummarizationMode.current
    }

    // MARK: - Settings Setters (for applying UserDefaults from outside the actor)

    func setMaxTokens(_ value: Int) { maxTokens = value }
    func setMaxSamplesPerChunk(_ value: Int) { maxSamplesPerChunk = value }
    func setMaxDeltasPerKeyframe(_ value: Int) { maxDeltasPerKeyframe = value }
    func setMaxKeyframeTextLength(_ value: Int) { maxKeyframeTextLength = value }
    func setMaxDeltaTextLength(_ value: Int) { maxDeltaTextLength = value }
    func setMode(_ value: SummarizationMode) { mode = value }

    /// Start the background summarization loop.
    func start() {
        guard !isRunning else {
            logger.info("Summarization engine already running, ignoring start()")
            return
        }
        isRunning = true
        logger.info("Summarization engine started (mode: \(self.mode.rawValue), poll: \(self.pollInterval)s, chunk: \(self.chunkDuration)s)")

        task = Task { [weak self] in
            guard let self = self else {
                DualLogger(category: "Summarization").error("SummarizationEngine deallocated before background task started (weak self was nil)")
                return
            }
            while !Task.isCancelled {
                await self.processPendingChunks()
                try? await Task.sleep(nanoseconds: UInt64(await self.pollInterval * 1_000_000_000))
            }
        }
    }

    /// Stop the background summarization loop.
    func stop() {
        isRunning = false
        task?.cancel()
        task = nil
        logger.info("Summarization engine stopped")
    }

    /// Process all pending (unsummarized) captures.
    private func processPendingChunks() async {
        // Prune processed captures every 10 cycles (~10 minutes)
        pollCycleCount += 1
        if pollCycleCount % 10 == 0 {
            do {
                let pruned = try storageManager.pruneProcessedCaptures(olderThan: 24)
                if pruned > 0 {
                    logger.info("Pruned \(pruned) processed captures older than 24h")
                }
            } catch {
                logger.error("Failed to prune processed captures: \(error.localizedDescription)")
            }
        }

        do {
            logger.debug("Polling for unsummarized captures (minimumAge: \(self.minimumAge)s)")

            let captures = try storageManager.unsummarizedCaptures(
                olderThan: minimumAge,
                limit: 500
            )

            guard !captures.isEmpty else {
                logger.debug("No unsummarized captures found (older than \(self.minimumAge)s)")
                return
            }

            logger.info("Found \(captures.count) unsummarized captures")

            var chunks = Chunker.chunkHybrid(
                captures: captures,
                windowDuration: chunkDuration,
                minimumChunkDuration: minimumChunkDuration
            )

            // Limit chunks per cycle to prevent unbounded bursts
            if chunks.count > maxChunksPerCycle {
                logger.warning(
                    "Capping chunk count from \(chunks.count) to \(self.maxChunksPerCycle) this cycle"
                )
                chunks = Array(chunks.prefix(maxChunksPerCycle))
            }

            for chunk in chunks {
                do {
                    // All modes route through cloud (claude -p proxy)
                    try await summarizeChunkCloud(chunk)
                } catch {
                    logger.error("Failed to summarize chunk: \(error.localizedDescription)")
                    // Continue with next chunk instead of stopping entirely
                }
            }
        } catch {
            logger.error("Failed to fetch unsummarized captures: \(error.localizedDescription)")
        }
    }

    // MARK: - Cloud Summarization (via claude -p proxy)

    /// Summarize a chunk using the LLM (claude -p proxy with Haiku).
    private func summarizeChunkCloud(_ chunk: Chunker.Chunk) async throws {
        var ocrSamples = CaptureFormatter.formatHierarchical(
            captures: chunk.captures,
            maxKeyframes: maxSamplesPerChunk,
            maxDeltasPerKeyframe: maxDeltasPerKeyframe,
            maxKeyframeTextLength: maxKeyframeTextLength,
            maxDeltaTextLength: maxDeltaTextLength
        )

        if ocrSamples.count > maxInputCharsPerChunk {
            ocrSamples = String(ocrSamples.prefix(maxInputCharsPerChunk)) + "\n[...truncated]"
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss"

        let duration = chunk.endTime.timeIntervalSince(chunk.startTime)
        let durationStr = duration < 60
            ? "\(Int(duration))s"
            : "\(Int(duration / 60))m \(Int(duration.truncatingRemainder(dividingBy: 60)))s"

        // Extract unique document paths, URLs, and visible windows from captures
        let docPaths = Set(chunk.captures.compactMap(\.documentPath)).sorted()
        let urls = Set(chunk.captures.compactMap(\.browserURL)).sorted()

        // Collect all unique visible windows across captures in this chunk
        let allVisibleWindows = chunk.captures
            .flatMap(\.decodedVisibleWindows)
            .reduce(into: [String: String]()) { dict, w in
                // Dedupe by app name, keep the most recent window title
                if let title = w.windowTitle, !title.isEmpty {
                    dict[w.appName] = title
                } else if dict[w.appName] == nil {
                    dict[w.appName] = "(no title)"
                }
            }
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }

        let userPrompt = PromptTemplates.render(
            PromptTemplates.template(for: .summarizationUser),
            values: [
                "start_time": dateFormatter.string(from: chunk.startTime),
                "end_time": dateFormatter.string(from: chunk.endTime),
                "duration": durationStr,
                "app_name": chunk.primaryApp,
                "window_title": chunk.primaryWindowTitle ?? "Unknown",
                "visible_windows": allVisibleWindows.isEmpty ? "None" : allVisibleWindows.joined(separator: "\n"),
                "document_paths": docPaths.isEmpty ? "None" : docPaths.joined(separator: ", "),
                "browser_urls": urls.isEmpty ? "None" : urls.joined(separator: ", "),
                "ocr_samples": ocrSamples,
            ]
        )

        let systemPrompt = PromptTemplates.template(for: .summarizationSystem)

        let llmResponse = try await llmClient.completeWithUsage(
            messages: [LLMMessage(role: "user", content: userPrompt)],
            model: model,
            maxTokens: maxTokens,
            systemPrompt: systemPrompt,
            temperature: 0.0
        )

        // Record token usage
        if let usage = llmResponse.usage {
            let usageRecord = TokenUsageRecord(
                id: nil,
                timestamp: Date().timeIntervalSince1970,
                caller: "summarizer",
                model: model,
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens
            )
            _ = try? storageManager.insertTokenUsage(usageRecord)
            let cost = PromptTemplates.estimateCost(
                model: model, inputTokens: usage.inputTokens, outputTokens: usage.outputTokens
            )
            logger.debug("Summarizer \(cost)")
        }

        let parsed = parseSummarizationResponse(llmResponse.text)

        // Merge LLM-extracted files/URLs with metadata from captures (belt and suspenders)
        let captureDocPaths = Set(chunk.captures.compactMap(\.documentPath))
        let captureURLs = Set(chunk.captures.compactMap(\.browserURL))
        let allDocPaths = Array(captureDocPaths.union(parsed.filesMentioned))
        let allURLs = Array(captureURLs.union(parsed.urlsVisited))

        let record = try buildSummaryRecord(
            chunk: chunk, summary: parsed.summary, keyTopics: parsed.keyTopics,
            documentPaths: allDocPaths, browserURLs: allURLs, activityType: parsed.activityType
        )
        let inserted = try storageManager.insertSummary(record)
        try storageManager.markCapturesAsSummarized(ids: chunk.captureIds)

        // TF-IDF embeddings are computed lazily on first semantic search query
        logger.info("Summarized chunk: \(chunk.startTime.shortTimestamp)-\(chunk.endTime.shortTimestamp) (\(chunk.captures.count) captures)")
    }

    // MARK: - Shared Helpers

    /// Build a SummaryRecord from a chunk and parsed LLM output.
    private func buildSummaryRecord(
        chunk: Chunker.Chunk,
        summary: String,
        keyTopics: [String],
        documentPaths: [String],
        browserURLs: [String],
        activityType: String?
    ) throws -> SummaryRecord {
        let encoder = JSONEncoder()
        let appNamesJSON = try String(data: encoder.encode(chunk.appNames), encoding: .utf8) ?? "[]"
        let captureIdsJSON = try String(data: encoder.encode(chunk.captureIds), encoding: .utf8) ?? "[]"
        let keyTopicsJSON = try String(data: encoder.encode(keyTopics), encoding: .utf8) ?? "[]"
        let docPathsJSON = documentPaths.isEmpty ? nil :
            try String(data: encoder.encode(documentPaths), encoding: .utf8)
        let urlsJSON = browserURLs.isEmpty ? nil :
            try String(data: encoder.encode(browserURLs), encoding: .utf8)

        return SummaryRecord(
            id: nil,
            startTimestamp: chunk.startTime.timeIntervalSince1970,
            endTimestamp: chunk.endTime.timeIntervalSince1970,
            appNames: appNamesJSON,
            summary: summary,
            keyTopics: keyTopicsJSON,
            captureIds: captureIdsJSON,
            documentPaths: docPathsJSON,
            browserURLs: urlsJSON,
            activityType: activityType
        )
    }

    /// Parsed fields from the LLM summarization response.
    struct ParsedSummary {
        let summary: String
        let keyTopics: [String]
        let filesMentioned: [String]
        let urlsVisited: [String]
        let activityType: String?
    }

    /// Parse the LLM's JSON response into structured summary fields.
    private func parseSummarizationResponse(_ response: String) -> ParsedSummary {
        let cleaned = stripCodeFences(response)

        if let data = cleaned.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return ParsedSummary(
                summary: json["summary"] as? String ?? response,
                keyTopics: json["key_topics"] as? [String] ?? [],
                filesMentioned: json["files_mentioned"] as? [String] ?? [],
                urlsVisited: json["urls_visited"] as? [String] ?? [],
                activityType: json["activity_type"] as? String
            )
        }

        logger.warning("Failed to parse summarization response as JSON. Raw response:\n\(response)")
        // Truncate raw response to avoid storing garbage as summary text
        let truncated = String(response.prefix(200))
        return ParsedSummary(summary: truncated, keyTopics: [], filesMentioned: [], urlsVisited: [], activityType: nil)
    }

    /// Strip markdown code fences (```json ... ``` or ``` ... ```) from LLM output.
    private func stripCodeFences(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let endOfFirstLine = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: endOfFirstLine)...])
            }
        }
        if s.hasSuffix("```") {
            s = String(s.dropLast(3))
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

}
