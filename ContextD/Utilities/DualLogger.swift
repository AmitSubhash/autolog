import Foundation
import os.log

/// A logger that writes to both Apple's Unified Logging (os.log) and stdout.
///
/// Drop-in replacement for `os.log.Logger`. All log messages go to the system
/// log (viewable via Console.app / `log stream`) AND are printed to stdout
/// (viewable in the terminal where the process was launched).
///
/// Usage: replace `Logger(subsystem:category:)` with `DualLogger(subsystem:category:)`.
/// The call-site API is identical: `logger.info("message")`, `logger.error("message")`, etc.
struct DualLogger: Sendable {
    private let logger: Logger
    private let category: String

    private static let subsystem = "com.autolog.app"
    private static let fileLock = NSLock()
    private static let logDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs", isDirectory: true)
    private static let stdoutLogURL = logDirectory.appendingPathComponent("autolog-app.log")
    private static let stderrLogURL = logDirectory.appendingPathComponent("autolog-app.err")

    /// Thread-safe timestamp format for stdout. Uses Date.FormatStyle instead of DateFormatter.
    private static let timestampStyle: Date.FormatStyle = .dateTime
        .hour(.twoDigits(amPM: .omitted))
        .minute(.twoDigits)
        .second(.twoDigits)
        .secondFraction(.fractional(3))

    init(subsystem: String = DualLogger.subsystem, category: String) {
        self.logger = Logger(subsystem: subsystem, category: category)
        self.category = category
    }

    func debug(_ message: String) {
        emit(level: "DEBUG", message: message)
        logger.debug("\(message, privacy: .public)")
    }

    func info(_ message: String) {
        emit(level: "INFO", message: message)
        logger.info("\(message, privacy: .public)")
    }

    func notice(_ message: String) {
        emit(level: "NOTICE", message: message)
        logger.notice("\(message, privacy: .public)")
    }

    func warning(_ message: String) {
        emit(level: "WARN", message: message)
        logger.warning("\(message, privacy: .public)")
    }

    func error(_ message: String) {
        emit(level: "ERROR", message: message)
        logger.error("\(message, privacy: .public)")
    }

    private func emit(level: String, message: String) {
        let ts = Date.now.formatted(DualLogger.timestampStyle)
        let line = "[\(ts)] [\(level)] [\(category)] \(message)"
        print(line)
        writeToFile(line + "\n", errorOnly: level == "ERROR")
    }

    private func writeToFile(_ line: String, errorOnly: Bool) {
        guard let data = line.data(using: .utf8) else { return }

        DualLogger.fileLock.lock()
        defer { DualLogger.fileLock.unlock() }

        try? FileManager.default.createDirectory(
            at: DualLogger.logDirectory,
            withIntermediateDirectories: true
        )

        append(data, to: DualLogger.stdoutLogURL)
        if errorOnly {
            append(data, to: DualLogger.stderrLogURL)
        }
    }

    private func append(_ data: Data, to url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: data)
            return
        }

        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
