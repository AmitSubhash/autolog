import Foundation

/// Runs Obsidian vault sync/report maintenance from the app process so it
/// keeps working even when background launch agents lack Documents access.
final class VaultAutomationCoordinator {
    private let logger = DualLogger(category: "VaultAutomation")
    private let fileManager = FileManager.default
    private let syncIntervalSeconds: UInt64 = 15 * 60
    private let maxCatchupHours = 240
    private let minimumSyncHours = 2

    private var syncLoopTask: Task<Void, Never>?
    private var startupBackfillTask: Task<Void, Never>?
    private var dailyReportTask: Task<Void, Never>?
    private var weeklyReportTask: Task<Void, Never>?

    private var scriptDirectory: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("contextd", isDirectory: true)
            .appendingPathComponent("scripts", isDirectory: true)
    }

    private var stateDirectory: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("ContextD", isDirectory: true)
    }

    private var lastSyncStateURL: URL {
        stateDirectory.appendingPathComponent("obsidian-sync-last-success.txt")
    }

    func start() {
        guard syncLoopTask == nil else { return }

        logger.info("Starting vault automation")

        syncLoopTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            self.runObsidianSync(trigger: "startup")

            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: self.syncIntervalSeconds * 1_000_000_000)
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                self.runObsidianSync(trigger: "interval")
            }
        }

        startupBackfillTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self.runStartupReportBackfill()
        }

        dailyReportTask = makeCalendarTask(
            name: "daily report",
            components: DateComponents(hour: 22, minute: 45)
        ) { [weak self] in
            self?.runDailyReport(for: Date(), trigger: "schedule")
        }

        weeklyReportTask = makeCalendarTask(
            name: "weekly rollup",
            components: DateComponents(hour: 21, minute: 0, weekday: 1)
        ) { [weak self] in
            self?.runWeeklyRollup(for: Date(), trigger: "schedule")
        }
    }

    func stop() {
        syncLoopTask?.cancel()
        startupBackfillTask?.cancel()
        dailyReportTask?.cancel()
        weeklyReportTask?.cancel()
        syncLoopTask = nil
        startupBackfillTask = nil
        dailyReportTask = nil
        weeklyReportTask = nil
        logger.info("Stopped vault automation")
    }

    private func makeCalendarTask(
        name: String,
        components: DateComponents,
        action: @escaping @Sendable () -> Void
    ) -> Task<Void, Never> {
        Task.detached(priority: .utility) { [weak self] in
            while let self, !Task.isCancelled {
                let calendar = Calendar.current
                guard let nextRun = calendar.nextDate(
                    after: Date(),
                    matching: components,
                    matchingPolicy: .nextTime,
                    direction: .forward
                ) else {
                    self.logger.error("Could not schedule \(name)")
                    do {
                        try await Task.sleep(nanoseconds: 60 * 60 * 1_000_000_000)
                    } catch {
                        break
                    }
                    continue
                }

                let delaySeconds = max(1, Int(nextRun.timeIntervalSinceNow.rounded(.up)))
                self.logger.info("Next \(name) scheduled for \(nextRun.ISO8601Format())")

                do {
                    try await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000)
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                action()
            }
        }
    }

    private func runStartupReportBackfill() {
        let calendar = Calendar.current
        logger.info("Running startup report backfill")

        for offset in stride(from: 7, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: Date()) else {
                continue
            }
            runDailyReport(for: date, trigger: "startup-backfill")
        }

        if let sunday = mostRecentSunday() {
            runWeeklyRollup(for: sunday, trigger: "startup-backfill")
        }
    }

    private func runObsidianSync(trigger: String) {
        let hours = recommendedSyncHours()
        logger.info("Running Obsidian sync (\(trigger), \(hours)h)")
        let result = runPythonScript(named: "obsidian-sync.py", arguments: [String(hours)])
        if result.exitCode == 0 {
            recordSuccessfulSync()
            logger.info("Obsidian sync completed")
        } else {
            logger.error("Obsidian sync failed: \(result.summary)")
        }
    }

    private func runDailyReport(for date: Date, trigger: String) {
        let dateString = Self.dateFormatter.string(from: date)
        logger.info("Running daily pattern report (\(trigger), \(dateString))")
        let result = runPythonScript(
            named: "daily_pattern_report.py",
            arguments: ["--date", dateString]
        )
        if result.exitCode == 0 {
            logger.info("Daily pattern report updated for \(dateString)")
        } else {
            logger.error("Daily pattern report failed for \(dateString): \(result.summary)")
        }
    }

    private func runWeeklyRollup(for date: Date, trigger: String) {
        let dateString = Self.dateFormatter.string(from: date)
        logger.info("Running weekly rollup (\(trigger), \(dateString))")
        let result = runPythonScript(
            named: "weekly_pattern_rollup.py",
            arguments: ["--end-date", dateString]
        )
        if result.exitCode == 0 {
            logger.info("Weekly rollup updated for \(dateString)")
        } else {
            logger.error("Weekly rollup failed for \(dateString): \(result.summary)")
        }
    }

    private func mostRecentSunday() -> Date? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        let daysBack = (weekday + 6) % 7
        return calendar.date(byAdding: .day, value: -daysBack, to: today)
    }

    private func recommendedSyncHours() -> Int {
        let fallbackHours = maxCatchupHours
        guard
            let raw = try? String(contentsOf: lastSyncStateURL, encoding: .utf8).trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            let lastSuccess = ISO8601DateFormatter().date(from: raw)
        else {
            return fallbackHours
        }

        let elapsedHours = Int(ceil(Date().timeIntervalSince(lastSuccess) / 3600))
        return min(maxCatchupHours, max(minimumSyncHours, elapsedHours + 1))
    }

    private func recordSuccessfulSync() {
        do {
            try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
            try Date().ISO8601Format().write(to: lastSyncStateURL, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to record successful sync: \(error.localizedDescription)")
        }
    }

    private func runPythonScript(named scriptName: String, arguments: [String]) -> ScriptResult {
        let scriptURL = scriptDirectory.appendingPathComponent(scriptName)
        guard fileManager.fileExists(atPath: scriptURL.path) else {
            return ScriptResult(
                exitCode: 1,
                summary: "script missing at \(scriptURL.path)"
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [scriptURL.path] + arguments
        process.currentDirectoryURL = scriptDirectory

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ScriptResult(
                exitCode: 1,
                summary: "launch failed: \(error.localizedDescription)"
            )
        }

        let output = readPipe(stdout)
        let errorOutput = readPipe(stderr)
        let combined = [output, errorOutput]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return ScriptResult(
            exitCode: Int(process.terminationStatus),
            summary: combined.isEmpty ? "no output" : combined
        )
    }

    private func readPipe(_ pipe: Pipe) -> String {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private struct ScriptResult {
        let exitCode: Int
        let summary: String
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
