import Foundation

/// Singleton container for all long-lived services.
/// Lives outside SwiftUI's struct lifecycle so services are created once
/// and never deallocated by view re-renders.
@MainActor
final class ServiceContainer {
    static let shared = ServiceContainer()

    private let logger = DualLogger(category: "Services")

    // Core services
    let database: AppDatabase?
    let storageManager: StorageManager?
    let llmClient: any LLMClient
    let captureEngine: CaptureEngine?
    let sessionDetector: AppSessionDetector?
    let enrichmentEngine: EnrichmentEngine?
    let summarizationEngine: SummarizationEngine?
    let activityInferenceEngine: ActivityInferenceEngine?
    let panelController: EnrichmentPanelController?
    let debugController: DebugWindowController?

    // API server
    private(set) var apiServer: APIServer?
    private let vaultAutomation = VaultAutomationCoordinator()

    private init() {
        llmClient = LLMProvider.current.makeClient()

        let logFile = "/tmp/autolog-debug.log"
        func debugLog(_ msg: String) {
            let line = "[\(Date())] \(msg)\n"
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: logFile),
                   let handle = FileHandle(forWritingAtPath: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                } else {
                    FileManager.default.createFile(atPath: logFile, contents: data)
                }
            }
        }

        do {
            debugLog("Creating database...")
            let db = try AppDatabase()
            debugLog("Database created OK")
            let storage = StorageManager(database: db)

            database = db
            storageManager = storage

            let engine = CaptureEngine(storageManager: storage)
            let detector = AppSessionDetector(storageManager: storage)
            engine.setSessionDetector(detector)
            captureEngine = engine
            sessionDetector = detector

            let enrichment = EnrichmentEngine(storageManager: storage, llmClient: llmClient)
            enrichmentEngine = enrichment

            summarizationEngine = SummarizationEngine(storageManager: storage, llmClient: llmClient)
            activityInferenceEngine = ActivityInferenceEngine(
                storageManager: storage, llmClient: llmClient
            )
            panelController = EnrichmentPanelController(enrichmentEngine: enrichment)
            debugController = DebugWindowController(storageManager: storage)

            logger.info("ServiceContainer initialized successfully")
        } catch {
            debugLog("INIT FAILED: \(error)")
            logger.error("Failed to initialize services: \(error.localizedDescription)")
            database = nil
            storageManager = nil
            captureEngine = nil
            sessionDetector = nil
            enrichmentEngine = nil
            summarizationEngine = nil
            activityInferenceEngine = nil
            panelController = nil
            debugController = nil
        }
    }

    /// Start capture + summarization. Call once after permissions are confirmed.
    func startServices() {
        // Permission detection can lag after grant or re-signing. Start services
        // and let capture failures surface clearly in the UI.
        if !PermissionManager.shared.allPermissionsGranted {
            logger.warning("Permissions may not be fully detected yet - starting services anyway")
        }

        // Apply user settings to capture engine
        if let engine = captureEngine {
            if let rawSpeed = UserDefaults.standard.string(forKey: "captureSpeed"),
               let speed = CaptureEngine.CaptureSpeed(rawValue: rawSpeed) {
                engine.captureSpeed = speed
            }

            let interval = UserDefaults.standard.double(forKey: "captureInterval")
            if interval > 0 {
                engine.captureInterval = max(interval, engine.captureSpeed.baseInterval)
            } else {
                engine.captureInterval = engine.captureSpeed.baseInterval
            }

            let maxKFInterval = UserDefaults.standard.double(forKey: "maxKeyframeInterval")
            if maxKFInterval > 0 { engine.maxKeyframeInterval = maxKFInterval }

            // significantChangeThreshold is a let constant on ImageDiffer (thread safety)

            // Adaptive interval and privacy exclusion are loaded in CaptureEngine.init
            // via UserDefaults, so no explicit wiring needed here.
        }

        captureEngine?.start()
        backfillActivityGraphIfNeeded()

        // Apply user settings to enrichment strategy
        if let enrichment = enrichmentEngine,
           let strategy = enrichment.strategies.first as? TwoPassLLMStrategy {
            let defaults = UserDefaults.standard

            let maxSummP1 = defaults.integer(forKey: "maxSummariesForPass1")
            if maxSummP1 > 0 { strategy.maxSummariesForPass1 = maxSummP1 }

            let maxCapP2 = defaults.integer(forKey: "maxCapturesForPass2")
            if maxCapP2 > 0 { strategy.maxCapturesForPass2 = maxCapP2 }

            let p1Tokens = defaults.integer(forKey: "enrichmentPass1MaxTokens")
            if p1Tokens > 0 { strategy.pass1MaxTokens = p1Tokens }

            let p2Tokens = defaults.integer(forKey: "enrichmentPass2MaxTokens")
            if p2Tokens > 0 { strategy.pass2MaxTokens = p2Tokens }

            let maxKF = defaults.integer(forKey: "enrichmentMaxKeyframes")
            if maxKF > 0 { strategy.maxKeyframes = maxKF }

            let maxDPKF = defaults.integer(forKey: "enrichmentMaxDeltasPerKeyframe")
            if maxDPKF > 0 { strategy.maxDeltasPerKeyframe = maxDPKF }

            let maxKFText = defaults.integer(forKey: "enrichmentMaxKeyframeTextLength")
            if maxKFText > 0 { strategy.maxKeyframeTextLength = maxKFText }

            let maxDText = defaults.integer(forKey: "enrichmentMaxDeltaTextLength")
            if maxDText > 0 { strategy.maxDeltaTextLength = maxDText }
        }

        let provider = LLMProvider.current
        let sumMode = SummarizationMode.current
        let canSummarize = provider.isReady
        logger.info(
            "LLM provider: \(provider.rawValue), ready: \(canSummarize), mode: \(sumMode.rawValue)"
        )

        if canSummarize {
            if let engine = summarizationEngine {
                Task {
                    // Apply user settings to summarization engine
                    let defaults = UserDefaults.standard

                    await engine.setMode(sumMode)

                    let sumMaxTokens = defaults.integer(forKey: "summarizationMaxTokens")
                    if sumMaxTokens > 0 { await engine.setMaxTokens(sumMaxTokens) }

                    let maxSamples = defaults.integer(forKey: "maxSamplesPerChunk")
                    if maxSamples > 0 { await engine.setMaxSamplesPerChunk(maxSamples) }

                    let sumMaxDPKF = defaults.integer(forKey: "summarizationMaxDeltasPerKeyframe")
                    if sumMaxDPKF > 0 { await engine.setMaxDeltasPerKeyframe(sumMaxDPKF) }

                    let sumMaxKFText = defaults.integer(forKey: "summarizationMaxKeyframeTextLength")
                    if sumMaxKFText > 0 { await engine.setMaxKeyframeTextLength(sumMaxKFText) }

                    let sumMaxDText = defaults.integer(forKey: "summarizationMaxDeltaTextLength")
                    if sumMaxDText > 0 { await engine.setMaxDeltaTextLength(sumMaxDText) }

                    await engine.start()
                }
            } else {
                logger.error("summarizationEngine is nil -- cannot start summarization")
            }
        } else {
            logger.warning(
                "LLM provider \(provider.rawValue) is not ready and mode is \(sumMode.rawValue) -- summarization disabled"
            )
        }

        // Start activity inference engine (requires LLM access, same as summarization)
        if canSummarize {
            if let activityEngine = activityInferenceEngine {
                Task { await activityEngine.start() }
            }
        }

        // Start the API server if enabled
        let apiServerEnabled = UserDefaults.standard.bool(forKey: "apiServerEnabled")
        // Default to enabled if the key has never been set
        let hasBeenSet = UserDefaults.standard.object(forKey: "apiServerEnabled") != nil
        if !hasBeenSet || apiServerEnabled {
            startAPIServer()
        }

        vaultAutomation.start()
        logger.info("All services started")
    }

    private func backfillActivityGraphIfNeeded() {
        guard let storage = storageManager else { return }
        Task.detached(priority: .utility) { [logger] in
            do {
                let counts = try storage.activityGraphCounts()
                guard counts.activities > 0 else { return }
                // Startup backfill is only for brand-new empty graphs.
                // Partial repair belongs to explicit maintenance paths, not launch.
                guard counts.entities == 0 && counts.links == 0 else {
                    return
                }
                _ = try ActivityGraphBuilder.backfillGraph(
                    storageManager: storage,
                    logger: logger
                )
            } catch {
                logger.error("Failed to backfill activity graph on startup: \(error.localizedDescription)")
            }
        }
    }

    /// Start the API server on the configured port.
    func startAPIServer() {
        guard let storage = storageManager else {
            logger.error("Cannot start API server: storageManager is nil")
            return
        }

        // Stop existing server if running
        apiServer?.stop()

        let port = UserDefaults.standard.integer(forKey: "apiServerPort")
        let effectivePort = port > 0 ? port : 21890

        let server = APIServer(storageManager: storage, port: effectivePort)
        server.start()
        apiServer = server

        logger.info("API server started on port \(effectivePort)")
    }

    /// Stop the API server.
    func stopAPIServer() {
        apiServer?.stop()
        apiServer = nil
        logger.info("API server stopped")
    }
}
