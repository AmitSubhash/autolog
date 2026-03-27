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
}
