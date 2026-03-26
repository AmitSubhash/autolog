import Foundation
import Hummingbird
import NIOCore

/// Inferred activity and activity graph routes for the AutoLog API.
extension APIServer {

    func registerInferredActivitiesRoutes(
        on router: Router<BasicRequestContext>,
        storage: StorageManager,
        log: DualLogger
    ) {
        registerActivitiesListRoute(on: router, storage: storage, log: log)
        registerCurrentActivitiesRoute(on: router, storage: storage, log: log)
        registerActivitySessionsRoute(on: router, storage: storage, log: log)
        registerRelatedActivitiesRoute(on: router, storage: storage, log: log)
        registerGraphRoute(on: router, storage: storage, log: log)
        registerEntitiesRoute(on: router, storage: storage, log: log)
    }

    // MARK: - GET /v1/activities

    private func registerActivitiesListRoute(
        on router: Router<BasicRequestContext>,
        storage: StorageManager,
        log: DualLogger
    ) {
        router.get("v1/activities") { request, _ -> Response in
            let minutesParam = request.uri.queryParameters.get("minutes", as: Int.self) ?? 60
            let limitParam = request.uri.queryParameters.get("limit", as: Int.self) ?? 50
            let offsetParam = request.uri.queryParameters.get("offset", as: Int.self) ?? 0

            let minutes = max(1, min(minutesParam, 1440))
            let limit = max(1, min(limitParam, 200))
            let offset = max(0, offsetParam)

            let now = Date()
            let start = now.addingTimeInterval(-Double(minutes * 60))

            do {
                let records = try storage.activities(
                    from: start, to: now, limit: limit, offset: offset
                )
                let items = Self.mapActivityRecords(records)
                let response = ActivitiesResponse(
                    activities: items, time_range_minutes: minutes, total: items.count
                )
                return try Self.jsonResponse(response, status: .ok)
            } catch {
                log.error("Activities query failed: \(error.localizedDescription)")
                return try Self.jsonResponse(
                    APIErrorResponse(error: "activities_error", detail: error.localizedDescription),
                    status: .internalServerError
                )
            }
        }
    }

    // MARK: - GET /v1/activities/current

    private func registerCurrentActivitiesRoute(
        on router: Router<BasicRequestContext>,
        storage: StorageManager,
        log: DualLogger
    ) {
        router.get("v1/activities/current") { _, _ -> Response in
            do {
                let records = try storage.activeActivities()
                let items = Self.mapActivityRecords(records)
                let response = ActivitiesResponse(
                    activities: items, time_range_minutes: 0, total: items.count
                )
                return try Self.jsonResponse(response, status: .ok)
            } catch {
                log.error("Current activities query failed: \(error.localizedDescription)")
                return try Self.jsonResponse(
                    APIErrorResponse(error: "activities_error", detail: error.localizedDescription),
                    status: .internalServerError
                )
            }
        }
    }

    // MARK: - GET /v1/activities/:id/sessions

    private func registerActivitySessionsRoute(
        on router: Router<BasicRequestContext>,
        storage: StorageManager,
        log: DualLogger
    ) {
        router.get("v1/activities/:id/sessions") { request, context -> Response in
            guard let idStr = context.parameters.get("id"),
                  let activityId = Int64(idStr) else {
                return try Self.jsonResponse(
                    APIErrorResponse(error: "invalid_request", detail: "Invalid activity ID"),
                    status: .badRequest
                )
            }

            let isoFormatter = ISO8601DateFormatter()
            do {
                let sessions = try storage.sessionsForActivity(activityId)
                let items: [SessionItem] = sessions.map { record in
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
                    sessions: items, time_range_minutes: 0, total: items.count
                )
                return try Self.jsonResponse(response, status: .ok)
            } catch {
                log.error("Activity sessions query failed: \(error.localizedDescription)")
                return try Self.jsonResponse(
                    APIErrorResponse(error: "sessions_error", detail: error.localizedDescription),
                    status: .internalServerError
                )
            }
        }
    }

    // MARK: - GET /v1/activities/:id/related

    private func registerRelatedActivitiesRoute(
        on router: Router<BasicRequestContext>,
        storage: StorageManager,
        log: DualLogger
    ) {
        router.get("v1/activities/:id/related") { request, context -> Response in
            guard let idStr = context.parameters.get("id"),
                  let activityId = Int64(idStr) else {
                return try Self.jsonResponse(
                    APIErrorResponse(error: "invalid_request", detail: "Invalid activity ID"),
                    status: .badRequest
                )
            }

            let limitParam = request.uri.queryParameters.get("limit", as: Int.self) ?? 10
            let limit = max(1, min(limitParam, 50))

            do {
                let records = try storage.relatedActivities(activityId, limit: limit)
                let items = Self.mapActivityRecords(records)
                let response = ActivitiesResponse(
                    activities: items, time_range_minutes: 0, total: items.count
                )
                return try Self.jsonResponse(response, status: .ok)
            } catch {
                log.error("Related activities query failed: \(error.localizedDescription)")
                return try Self.jsonResponse(
                    APIErrorResponse(error: "activities_error", detail: error.localizedDescription),
                    status: .internalServerError
                )
            }
        }
    }

    // MARK: - GET /v1/graph

    private func registerGraphRoute(
        on router: Router<BasicRequestContext>,
        storage: StorageManager,
        log: DualLogger
    ) {
        router.get("v1/graph") { request, _ -> Response in
            let minutesParam = request.uri.queryParameters.get("minutes", as: Int.self) ?? 60
            let minutes = max(1, min(minutesParam, 1440))

            let now = Date()
            let start = now.addingTimeInterval(-Double(minutes * 60))

            do {
                let graph = try storage.activityGraph(from: start, to: now)
                let activityItems = Self.mapActivityRecords(graph.activities)
                let linkItems: [ActivityLinkItem] = graph.links.map { link in
                    ActivityLinkItem(
                        id: link.id ?? 0,
                        source_activity_id: link.sourceActivityId,
                        target_activity_id: link.targetActivityId,
                        link_type: link.linkType,
                        weight: link.weight,
                        shared_entity: link.sharedEntity
                    )
                }
                let response = ActivityGraphResponse(
                    activities: activityItems, links: linkItems,
                    time_range_minutes: minutes
                )
                return try Self.jsonResponse(response, status: .ok)
            } catch {
                log.error("Graph query failed: \(error.localizedDescription)")
                return try Self.jsonResponse(
                    APIErrorResponse(error: "graph_error", detail: error.localizedDescription),
                    status: .internalServerError
                )
            }
        }
    }

    // MARK: - GET /v1/entities

    private func registerEntitiesRoute(
        on router: Router<BasicRequestContext>,
        storage: StorageManager,
        log: DualLogger
    ) {
        router.get("v1/entities") { request, _ -> Response in
            guard let entityType = request.uri.queryParameters.get("type"),
                  let entityValue = request.uri.queryParameters.get("value") else {
                return try Self.jsonResponse(
                    APIErrorResponse(
                        error: "invalid_request",
                        detail: "Both \"type\" and \"value\" query parameters are required"
                    ),
                    status: .badRequest
                )
            }

            do {
                let records = try storage.activitiesForEntity(
                    type: entityType, value: entityValue
                )
                let items = Self.mapActivityRecords(records)
                let response = EntityQueryResponse(
                    entity_type: entityType, entity_value: entityValue,
                    activities: items
                )
                return try Self.jsonResponse(response, status: .ok)
            } catch {
                log.error("Entity query failed: \(error.localizedDescription)")
                return try Self.jsonResponse(
                    APIErrorResponse(error: "entity_error", detail: error.localizedDescription),
                    status: .internalServerError
                )
            }
        }
    }

    // MARK: - Helpers

    /// Map ActivityRecord array to InferredActivityItem array for JSON output.
    static func mapActivityRecords(_ records: [ActivityRecord]) -> [InferredActivityItem] {
        let isoFormatter = ISO8601DateFormatter()
        return records.map { record in
            InferredActivityItem(
                id: record.id ?? 0,
                name: record.name,
                description: record.description,
                start_timestamp: isoFormatter.string(from: record.startDate),
                end_timestamp: isoFormatter.string(from: record.endDate),
                key_topics: record.decodedKeyTopics,
                document_paths: record.decodedDocumentPaths,
                browser_urls: record.decodedBrowserURLs,
                confidence: record.confidence,
                is_active: record.isActive
            )
        }
    }
}
