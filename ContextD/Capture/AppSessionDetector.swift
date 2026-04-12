import Foundation

/// Detects app session boundaries from the capture stream.
/// An "app session" is a contiguous stretch where the same app is frontmost.
/// Brief interruptions (< sessionGapTolerance) do not break a session.
actor AppSessionDetector {
    private let storageManager: StorageManager
    private let logger = DualLogger(category: "SessionDetector")

    /// Gap tolerance: brief app switches shorter than this do not break a session.
    var sessionGapTolerance: TimeInterval = 30.0

    /// Minimum session duration to persist (avoids micro-sessions from rapid switching).
    var minimumSessionDuration: TimeInterval = 5.0

    /// Current in-progress session state.
    private var current: InProgressSession?

    struct InProgressSession {
        let appName: String
        let appBundleID: String?
        let focusBlockId: String?
        var startTimestamp: Double
        var endTimestamp: Double
        var captureCount: Int
        var windowTitles: Set<String>
        var documentPaths: Set<String>
        var browserURLs: Set<String>
    }

    init(storageManager: StorageManager) {
        self.storageManager = storageManager
    }

    /// Process a new capture record. Detects session boundaries.
    func processCapture(_ record: CaptureRecord) {
        // Match by bundle ID when both are non-nil, fall back to app name
        let bothHaveBundleID = current?.appBundleID != nil && record.appBundleID != nil
        let isSameApp = bothHaveBundleID
            ? current?.appBundleID == record.appBundleID
            : current?.appName == record.appName
        let isSameFocusBlock = current?.focusBlockId == record.focusBlockId
        // Use abs() to handle clock skew (negative gap after sleep/wake)
        let gap = current.map { abs(record.timestamp - $0.endTimestamp) } ?? .infinity

        // Same app and brief gap: extend current session
        if isSameApp && isSameFocusBlock && gap < sessionGapTolerance {
            extendCurrent(with: record)
            return
        }

        // Different app or large gap: finalize current, start new
        if current != nil {
            finalizeCurrentSession()
        }
        startNewSession(from: record)
    }

    /// Finalize any in-progress session (call on app shutdown).
    func flush() {
        if current != nil {
            finalizeCurrentSession()
        }
    }

    // MARK: - Private Helpers

    /// Maximum entries per metadata set to prevent unbounded growth in long sessions.
    private let maxMetadataEntries = 100

    private func extendCurrent(with record: CaptureRecord) {
        guard current != nil else { return }
        current!.endTimestamp = record.timestamp
        current!.captureCount += 1

        if let title = record.windowTitle, !title.isEmpty,
           current!.windowTitles.count < maxMetadataEntries {
            current!.windowTitles.insert(title)
        }
        if let docPath = record.documentPath, !docPath.isEmpty,
           current!.documentPaths.count < maxMetadataEntries {
            current!.documentPaths.insert(docPath)
        }
        if let url = record.browserURL, !url.isEmpty,
           current!.browserURLs.count < maxMetadataEntries {
            current!.browserURLs.insert(url)
        }
    }

    private func finalizeCurrentSession() {
        guard let session = current else { return }
        current = nil

        let duration = session.endTimestamp - session.startTimestamp
        if duration < minimumSessionDuration {
            logger.debug("Discarding micro-session for \(session.appName) (\(String(format: "%.1f", duration))s)")
            return
        }

        // Encode sets as JSON arrays
        let windowTitlesJSON = encodeSet(session.windowTitles)
        let documentPathsJSON = encodeSet(session.documentPaths)
        let browserURLsJSON = encodeSet(session.browserURLs)

        var record = AppSessionRecord(
            id: nil,
            appName: session.appName,
            appBundleID: session.appBundleID,
            startTimestamp: session.startTimestamp,
            endTimestamp: session.endTimestamp,
            captureCount: session.captureCount,
            windowTitles: windowTitlesJSON,
            documentPaths: documentPathsJSON,
            browserURLs: browserURLsJSON,
            focusBlockId: session.focusBlockId,
            activityId: nil,
            activityInferred: false
        )

        do {
            record = try storageManager.insertAppSession(record)
            logger.debug("Finalized session id=\(record.id ?? -1) app=\(session.appName) duration=\(String(format: "%.0f", duration))s captures=\(session.captureCount)")
        } catch {
            logger.error("Failed to insert app session: \(error.localizedDescription)")
        }
    }

    private func startNewSession(from record: CaptureRecord) {
        var windowTitles = Set<String>()
        var documentPaths = Set<String>()
        var browserURLs = Set<String>()

        if let title = record.windowTitle, !title.isEmpty {
            windowTitles.insert(title)
        }
        if let docPath = record.documentPath, !docPath.isEmpty {
            documentPaths.insert(docPath)
        }
        if let url = record.browserURL, !url.isEmpty {
            browserURLs.insert(url)
        }

        current = InProgressSession(
            appName: record.appName,
            appBundleID: record.appBundleID,
            focusBlockId: record.focusBlockId,
            startTimestamp: record.timestamp,
            endTimestamp: record.timestamp,
            captureCount: 1,
            windowTitles: windowTitles,
            documentPaths: documentPaths,
            browserURLs: browserURLs
        )
    }

    /// Encode a string set as a JSON array string, or nil if empty.
    private func encodeSet(_ set: Set<String>) -> String? {
        guard !set.isEmpty else { return nil }
        let sorted = set.sorted()
        guard let data = try? JSONEncoder().encode(sorted),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }
}
