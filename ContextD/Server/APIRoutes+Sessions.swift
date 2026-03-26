import Foundation
import Hummingbird
import NIOCore

/// Session and app-usage routes for the AutoLog API.
/// Split into its own file to keep APIRoutes.swift under 300 lines.
extension APIServer {

    // MARK: - Sessions

    func registerSessionsRoute(
        on router: Router<BasicRequestContext>,
        storage: StorageManager,
        log: DualLogger
    ) {
        router.get("v1/sessions") { request, _ -> Response in
            let minutesParam = request.uri.queryParameters.get("minutes", as: Int.self) ?? 60
            let limitParam = request.uri.queryParameters.get("limit", as: Int.self) ?? 50
            let offsetParam = request.uri.queryParameters.get("offset", as: Int.self) ?? 0
            let appNameParam = request.uri.queryParameters.get("app_name")

            let minutes = max(1, min(minutesParam, 1440))
            let limit = max(1, min(limitParam, 200))
            let offset = max(0, offsetParam)

            let now = Date()
            let start = now.addingTimeInterval(-Double(minutes * 60))
            let isoFormatter = ISO8601DateFormatter()

            do {
                // Filter by app name using bundle ID or app name matching
                let records = try storage.appSessions(
                    from: start, to: now, appBundleID: nil,
                    limit: limit, offset: offset
                )

                // If app_name filter is provided, filter in-memory
                // (supports both bundle ID and display name matching)
                let filtered: [AppSessionRecord]
                if let appName = appNameParam, !appName.isEmpty {
                    filtered = records.filter { record in
                        record.appName.localizedCaseInsensitiveContains(appName)
                            || record.appBundleID?.localizedCaseInsensitiveContains(appName) == true
                    }
                } else {
                    filtered = records
                }

                let items: [SessionItem] = filtered.map { record in
                    SessionItem(
                        id: record.id ?? 0,
                        app_name: record.appName,
                        app_bundle_id: record.appBundleID,
                        start_timestamp: isoFormatter.string(from: record.startDate),
                        end_timestamp: isoFormatter.string(from: record.endDate),
                        capture_count: record.captureCount,
                        window_titles: record.decodedWindowTitles,
                        document_paths: record.decodedDocumentPaths,
                        browser_urls: record.decodedBrowserURLs
                    )
                }

                let response = SessionsResponse(
                    sessions: items,
                    time_range_minutes: minutes,
                    total: items.count
                )
                return try Self.jsonResponse(response, status: .ok)
            } catch {
                log.error("Sessions query failed: \(error.localizedDescription)")
                return try Self.jsonResponse(
                    APIErrorResponse(error: "sessions_error", detail: error.localizedDescription),
                    status: .internalServerError
                )
            }
        }
    }

    // MARK: - App Usage

    func registerAppUsageRoute(
        on router: Router<BasicRequestContext>,
        storage: StorageManager,
        log: DualLogger
    ) {
        router.get("v1/app-usage") { request, _ -> Response in
            let minutesParam = request.uri.queryParameters.get("minutes", as: Int.self) ?? 60
            let minutes = max(1, min(minutesParam, 1440))

            let now = Date()
            let start = now.addingTimeInterval(-Double(minutes * 60))

            do {
                let usageData = try storage.appUsageSummary(from: start, to: now)

                let items: [AppUsageItem] = usageData.map { entry in
                    AppUsageItem(
                        app_name: entry.appName,
                        total_seconds: entry.totalSeconds,
                        session_count: entry.sessionCount
                    )
                }

                let response = AppUsageResponse(
                    usage: items,
                    time_range_minutes: minutes
                )
                return try Self.jsonResponse(response, status: .ok)
            } catch {
                log.error("App usage query failed: \(error.localizedDescription)")
                return try Self.jsonResponse(
                    APIErrorResponse(error: "app_usage_error", detail: error.localizedDescription),
                    status: .internalServerError
                )
            }
        }
    }
}
