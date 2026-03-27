import Foundation

struct AutoLogFocusState: Codable, Sendable {
    let id: String
    let task: String
    let taskSlug: String?
    let startedAt: String
    let doneWhen: String?
    let artifactGoal: String?
    let artifact: String?
    let driftBudgetMinutes: Int?
    let source: String?
    let scorecardPath: String?
    let status: String?

    enum CodingKeys: String, CodingKey {
        case id, task, artifact, source, status
        case taskSlug = "task_slug"
        case startedAt = "started_at"
        case doneWhen = "done_when"
        case artifactGoal = "artifact_goal"
        case driftBudgetMinutes = "drift_budget_minutes"
        case scorecardPath = "scorecard_path"
    }
}

struct AutoLogFocusBlock: Codable, Sendable {
    let id: String
    let task: String
    let taskSlug: String?
    let startedAt: String
    let endedAt: String?
    let doneWhen: String?
    let artifactGoal: String?
    let artifact: String?
    let driftBudgetMinutes: Int?
    let score: Int?
    let notes: String?
    let source: String?
    let status: String?

    enum CodingKeys: String, CodingKey {
        case id, task, artifact, score, notes, source, status
        case taskSlug = "task_slug"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case doneWhen = "done_when"
        case artifactGoal = "artifact_goal"
        case driftBudgetMinutes = "drift_budget_minutes"
    }
}

struct FocusDriftMetrics: Codable, Sendable {
    let level: String
    let fragmentationScore: Int
    let sessionCount: Int
    let appCount: Int
    let browserRatio: Double
    let elapsedMinutes: Int
    let reasons: [String]

    enum CodingKeys: String, CodingKey {
        case level, reasons
        case fragmentationScore = "fragmentation_score"
        case sessionCount = "session_count"
        case appCount = "app_count"
        case browserRatio = "browser_ratio"
        case elapsedMinutes = "elapsed_minutes"
    }
}

struct FocusStatusSnapshot: Sendable {
    let current: AutoLogFocusState?
    let drift: FocusDriftMetrics?
    let recentBlocks: [AutoLogFocusBlock]
}

enum FocusStateStore {
    private static let currentStatePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/autolog/focus-state.json")
    private static let blocksLogPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/autolog/focus-blocks.jsonl")
    private static let formatter = ISO8601DateFormatter()
    private static let browserApps: Set<String> = [
        "Safari", "Google Chrome", "Chrome", "Brave Browser", "Arc", "Firefox",
    ]
    private static let researchKeywords = [
        "research", "paper", "docs", "read", "reading", "browse", "search",
    ]

    static func loadCurrent() -> AutoLogFocusState? {
        guard let data = try? Data(contentsOf: currentStatePath) else { return nil }
        return try? JSONDecoder().decode(AutoLogFocusState.self, from: data)
    }

    static func loadBlocks(limit: Int = 20, includeOpen: Bool = false) -> [AutoLogFocusBlock] {
        var blocks: [AutoLogFocusBlock] = readLoggedBlocks(limit: limit)
        if includeOpen, let current = loadCurrent() {
            blocks.insert(
                AutoLogFocusBlock(
                    id: current.id,
                    task: current.task,
                    taskSlug: current.taskSlug,
                    startedAt: current.startedAt,
                    endedAt: nil,
                    doneWhen: current.doneWhen,
                    artifactGoal: current.artifactGoal,
                    artifact: current.artifact,
                    driftBudgetMinutes: current.driftBudgetMinutes,
                    score: nil,
                    notes: nil,
                    source: current.source,
                    status: current.status ?? "active"
                ),
                at: 0
            )
        }
        return blocks
    }

    static func currentSnapshot(storageManager: StorageManager?) -> FocusStatusSnapshot {
        let current = loadCurrent()
        let recent = loadBlocks(limit: 8, includeOpen: false)
        let drift = computeDrift(current: current, storageManager: storageManager)
        return FocusStatusSnapshot(current: current, drift: drift, recentBlocks: recent)
    }

    private static func readLoggedBlocks(limit: Int) -> [AutoLogFocusBlock] {
        guard let text = try? String(contentsOf: blocksLogPath, encoding: .utf8) else {
            return []
        }
        let lines = text.split(separator: "\n").suffix(limit)
        return Array(lines.compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(AutoLogFocusBlock.self, from: data)
        }.reversed())
    }

    private static func computeDrift(
        current: AutoLogFocusState?,
        storageManager: StorageManager?
    ) -> FocusDriftMetrics? {
        guard let current, let storageManager, let startedAt = parseDate(current.startedAt) else {
            return nil
        }

        let now = Date()
        let windowStart = max(startedAt, now.addingTimeInterval(-10 * 60))
        let sessions = (try? storageManager.appSessions(
            from: windowStart, to: now, limit: 50, offset: 0
        )) ?? []
        let elapsedMinutes = max(1, Int(now.timeIntervalSince(startedAt) / 60))
        let appCount = Set(sessions.map(\.appName)).count

        var totalSeconds = 0.0
        var browserSeconds = 0.0
        for session in sessions {
            let duration = max(0, session.duration)
            totalSeconds += duration
            if browserApps.contains(session.appName) {
                browserSeconds += duration
            }
        }
        let browserRatio = totalSeconds > 0 ? browserSeconds / totalSeconds : 0
        let isResearchTask = isResearchHeavyTask(current.task)

        var score = 0
        score += max(0, sessions.count - 4) * 8
        score += max(0, appCount - 2) * 12
        score += Int(browserRatio * (isResearchTask ? 18 : 35))
        if elapsedMinutes > (current.driftBudgetMinutes ?? 10) && sessions.count <= 1 {
            score += 10
        }
        score = min(100, max(0, score))

        var reasons: [String] = []
        if sessions.count > 8 {
            reasons.append("high app switching")
        }
        if appCount > 3 {
            reasons.append("too many apps in block")
        }
        if browserRatio > (isResearchTask ? 0.75 : 0.45) {
            reasons.append("browser-heavy relative to task")
        }
        if reasons.isEmpty {
            reasons.append("within drift budget")
        }

        let level: String
        if score < 25 {
            level = "focused"
        } else if score < 50 {
            level = "watch"
        } else {
            level = "drifting"
        }

        return FocusDriftMetrics(
            level: level,
            fragmentationScore: score,
            sessionCount: sessions.count,
            appCount: appCount,
            browserRatio: browserRatio,
            elapsedMinutes: elapsedMinutes,
            reasons: reasons
        )
    }

    private static func isResearchHeavyTask(_ task: String) -> Bool {
        let lower = task.lowercased()
        return researchKeywords.contains { lower.contains($0) }
    }

    static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        if let date = formatter.date(from: value) {
            return date
        }
        return ISO8601DateFormatter.basic.date(from: value)
    }
}

extension ISO8601DateFormatter {
    static let basic: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
