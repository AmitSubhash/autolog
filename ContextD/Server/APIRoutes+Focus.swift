import Foundation
import Hummingbird

extension APIServer {
    func registerFocusRoutes(
        on router: Router<BasicRequestContext>,
        storage: StorageManager,
        log: DualLogger
    ) {
        router.get("v1/focus/current") { _, _ -> Response in
            let snapshot = FocusStateStore.currentSnapshot(storageManager: storage)
            let response = FocusStatusResponse(
                current: snapshot.current.map(Self.mapFocusState),
                drift: snapshot.drift.map(Self.mapFocusDrift)
            )
            return try Self.jsonResponse(response, status: .ok)
        }

        router.get("v1/focus/blocks") { request, _ -> Response in
            let limitParam = request.uri.queryParameters.get("limit", as: Int.self) ?? 20
            let limit = max(1, min(limitParam, 100))
            let blocks = FocusStateStore.loadBlocks(limit: limit, includeOpen: false)
            let response = FocusBlocksResponse(
                blocks: blocks.map(Self.mapFocusBlock),
                total: blocks.count
            )
            return try Self.jsonResponse(response, status: .ok)
        }

        router.get("v1/focus/blocks/:id/report") { _, context -> Response in
            guard let id = context.parameters.get("id"),
                  let block = FocusStateStore.block(withId: id),
                  let start = FocusStateStore.parseDate(block.startedAt) else {
                return try Self.jsonResponse(
                    APIErrorResponse(error: "not_found", detail: "Focus block not found"),
                    status: .notFound
                )
            }

            let end = FocusStateStore.parseDate(block.endedAt) ?? Date()

            do {
                let summaries = try storage.summaries(from: start, to: end)
                    .filter { Self.matches(block: block, start: $0.startDate, end: $0.endDate, directId: $0.focusBlockId) }
                    .sorted { $0.startTimestamp < $1.startTimestamp }
                let sessions = try storage.appSessions(from: start, to: end)
                    .filter { Self.matches(block: block, start: $0.startDate, end: $0.endDate, directId: $0.focusBlockId) }
                    .sorted { $0.startTimestamp < $1.startTimestamp }
                let activities = try storage.activities(from: start, to: end)
                    .filter { Self.matches(block: block, start: $0.startDate, end: $0.endDate, directId: $0.focusBlockId) }
                    .sorted { $0.startTimestamp < $1.startTimestamp }

                let summaryContexts = Self.enrichedSummaryContexts(summaries, block: block)
                let coveredSections = Array(
                    Set(
                        summaryContexts.compactMap(\.studyCoverage).flatMap(\.sections)
                        + activities.compactMap(\.decodedStudyCoverage).flatMap(\.sections)
                    )
                ).sorted()
                let coveredConcepts = Array(
                    Set(
                        summaryContexts.compactMap(\.studyCoverage).flatMap(\.concepts)
                        + activities.compactMap(\.decodedStudyCoverage).flatMap(\.concepts)
                    )
                ).sorted()

                let driftSegments = summaryContexts.compactMap { context -> FocusReportSegmentItem? in
                    guard let alignment = context.focusAlignment,
                          alignment == FocusAlignment.offTask.rawValue
                            || alignment == FocusAlignment.recovered.rawValue else {
                        return nil
                    }
                    return FocusReportSegmentItem(
                        start_timestamp: ISO8601DateFormatter().string(from: context.summary.startDate),
                        end_timestamp: ISO8601DateFormatter().string(from: context.summary.endDate),
                        focus_alignment: alignment,
                        summary: context.summary.summary
                    )
                }

                let appUsage = Self.appUsage(from: sessions)
                let resumeHint = Self.resumeHint(
                    block: block,
                    summaryContexts: summaryContexts,
                    coveredSections: coveredSections
                )

                let response = FocusBlockReportResponse(
                    block: Self.mapFocusBlock(block),
                    activities: Self.mapActivityRecords(activities),
                    app_usage: appUsage,
                    covered_sections: coveredSections,
                    covered_concepts: coveredConcepts,
                    drift_segments: driftSegments,
                    resume_hint: resumeHint,
                    summary_count: summaries.count,
                    session_count: sessions.count
                )
                return try Self.jsonResponse(response, status: .ok)
            } catch {
                log.error("Focus report failed: \(error.localizedDescription)")
                return try Self.jsonResponse(
                    APIErrorResponse(error: "focus_report_error", detail: error.localizedDescription),
                    status: .internalServerError
                )
            }
        }
    }

    private static func mapFocusState(_ state: AutoLogFocusState) -> FocusStateItem {
        FocusStateItem(
            id: state.id,
            task: state.task,
            task_slug: state.taskSlug,
            started_at: state.startedAt,
            done_when: state.doneWhen,
            artifact_goal: state.artifactGoal,
            artifact: state.artifact,
            drift_budget_minutes: state.driftBudgetMinutes,
            source: state.source,
            status: state.status
        )
    }

    private static func mapFocusBlock(_ block: AutoLogFocusBlock) -> FocusBlockItem {
        FocusBlockItem(
            id: block.id,
            task: block.task,
            task_slug: block.taskSlug,
            started_at: block.startedAt,
            ended_at: block.endedAt,
            done_when: block.doneWhen,
            artifact_goal: block.artifactGoal,
            artifact: block.artifact,
            drift_budget_minutes: block.driftBudgetMinutes,
            score: block.score,
            notes: block.notes,
            next_step: block.nextStep,
            source: block.source,
            status: block.status
        )
    }

    private static func mapFocusDrift(_ drift: FocusDriftMetrics) -> FocusDriftItem {
        FocusDriftItem(
            level: drift.level,
            fragmentation_score: drift.fragmentationScore,
            session_count: drift.sessionCount,
            app_count: drift.appCount,
            browser_ratio: drift.browserRatio,
            elapsed_minutes: drift.elapsedMinutes,
            reasons: drift.reasons
        )
    }

    private static func matches(
        block: AutoLogFocusBlock,
        start: Date,
        end: Date,
        directId: String?
    ) -> Bool {
        if let directId {
            return directId == block.id
        }
        guard let blockStart = FocusStateStore.parseDate(block.startedAt) else { return false }
        let blockEnd = FocusStateStore.parseDate(block.endedAt) ?? Date()
        return start <= blockEnd && end >= blockStart
    }

    private static func appUsage(from sessions: [AppSessionRecord]) -> [AppUsageItem] {
        let usage = sessions.reduce(into: [String: (seconds: Double, count: Int)]()) { partial, session in
            partial[session.appName, default: (0, 0)].seconds += session.duration
            partial[session.appName, default: (0, 0)].count += 1
        }

        return usage.map { appName, stats in
            AppUsageItem(
                app_name: appName,
                total_seconds: stats.seconds,
                session_count: stats.count
            )
        }
        .sorted { lhs, rhs in
            if lhs.total_seconds != rhs.total_seconds { return lhs.total_seconds > rhs.total_seconds }
            return lhs.app_name < rhs.app_name
        }
    }

    private static func resumeHint(
        block: AutoLogFocusBlock,
        summaryContexts: [EnrichedSummaryContext],
        coveredSections: [String]
    ) -> String? {
        if let nextStep = block.nextStep?.trimmingCharacters(in: .whitespacesAndNewlines),
           !nextStep.isEmpty {
            return nextStep
        }

        if let lastCoverage = summaryContexts.compactMap(\.studyCoverage).last,
           let lastSection = lastCoverage.sections.last {
            if let resource = lastCoverage.resource {
                return "Resume \(resource) after \(lastSection)."
            }
            return "Resume after \(lastSection)."
        }

        if let lastSection = coveredSections.last {
            return "Resume after \(lastSection)."
        }

        return nil
    }

    private struct EnrichedSummaryContext {
        let summary: SummaryRecord
        let focusAlignment: String?
        let studyCoverage: StudyCoverage?
    }

    private static func enrichedSummaryContexts(
        _ summaries: [SummaryRecord],
        block: AutoLogFocusBlock
    ) -> [EnrichedSummaryContext] {
        var previousAlignment: String?
        return summaries.map { summary in
            let fallback = FocusContextAnalyzer.analyze(
                focusBlock: block,
                appNames: summary.decodedAppNames,
                windowTitles: [],
                urls: summary.decodedBrowserURLs,
                text: summary.summary,
                previousAlignment: previousAlignment
            )
            let alignment = summary.focusAlignment ?? fallback.focusAlignment
            let coverage = summary.decodedStudyCoverage
                ?? FocusContextAnalyzer.decodeStudyCoverage(fallback.studyCoverageJSON)
            previousAlignment = alignment
            return EnrichedSummaryContext(
                summary: summary,
                focusAlignment: alignment,
                studyCoverage: coverage
            )
        }
    }
}
