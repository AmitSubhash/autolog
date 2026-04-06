import AppKit
import Combine
import SwiftUI

// MARK: - AppDelegate

/// NSApplicationDelegate for handling lifecycle events that SwiftUI App can't.
/// Handles: onboarding window on first launch, starting services when ready,
/// NSStatusItem for menu bar icon, and side panel toggle.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = DualLogger(category: "AppDelegate")
    private var onboardingWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var sidePanelController: SidePanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DefaultsMigration.migrateLegacyContextDDefaults()

        // LSUIElement apps default to .prohibited activation policy, which prevents
        // windows from coming to the foreground and receiving keyboard input.
        // Set .accessory so windows can be activated on demand while staying out of the Dock.
        NSApp.setActivationPolicy(.accessory)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        setupStatusItem()
        setupSidePanel()
        setupHotkeys()

        let hasOnboarded = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")

        if hasOnboarded {
            // Already onboarded -- start services immediately.
            // Optimistically mark screen recording as granted since CGPreflight can
            // return stale results on macOS 15+ after re-codesign. Captures fail
            // gracefully if permission was truly revoked.
            logger.info("Previously onboarded -- starting services directly")
            PermissionManager.shared.markOnboardingComplete()
            PermissionManager.shared.startPeriodicCheck()
            ServiceContainer.shared.startServices()
            startIconUpdater()
        } else if PermissionManager.shared.allPermissionsGranted {
            // First launch, permissions already granted (rare but possible)
            logger.info("Permissions granted on first launch -- starting services")
            UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
            PermissionManager.shared.startPeriodicCheck()
            ServiceContainer.shared.startServices()
            startIconUpdater()
        } else {
            // First launch, needs onboarding
            logger.info("First launch -- showing permissions dialog")
            showOnboardingWindow()
        }
    }

    // MARK: - Status Bar Icon

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "eye.fill",
                accessibilityDescription: "AutoLog"
            )
            button.action = #selector(statusItemClicked)
            button.target = self
        }
        self.statusItem = item
    }

    @objc private func statusItemClicked() {
        sidePanelController?.toggle()
    }

    private func setupHotkeys() {
        HotkeyManager.shared.onHotkey = {
            Task { @MainActor in
                ServiceContainer.shared.panelController?.toggle()
            }
        }
        HotkeyManager.shared.register()
    }

    private func startIconUpdater() {
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateStatusIcon()
            }
        }
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let name = computeIconName()
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "AutoLog")
        if button.image?.name() != image?.name() {
            button.image = image
        }
    }

    private func computeIconName() -> String {
        let focusSnapshot = FocusStateStore.currentSnapshot(
            storageManager: ServiceContainer.shared.storageManager
        )
        if focusSnapshot.current != nil, focusSnapshot.drift?.level == "drifting" {
            return "exclamationmark.circle"
        }
        guard let engine = ServiceContainer.shared.captureEngine else {
            return "eye.slash"
        }
        guard engine.isRunning else {
            return "eye.slash"
        }
        if engine.isWinking {
            return "eye"
        }
        switch engine.state {
        case .recording:
            return "eye.fill"
        case .paused:
            return "eye.slash"
        case .privacyPaused:
            return "lock.shield"
        case .sleeping:
            return "moon.fill"
        }
    }

    // MARK: - Side Panel

    private func setupSidePanel() {
        let controller = SidePanelController {
            SidePanelContent()
        }
        self.sidePanelController = controller
    }

    @objc private func screensDidChange() {}

    private func showOnboardingWindow() {
        let permissionManager = PermissionManager.shared

        let onboardingView = OnboardingView(
            permissionManager: permissionManager,
            onComplete: { [weak self] in
                UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                // Optimistically mark screen recording as granted so services start
                // even if CGPreflight returns stale results after re-codesign.
                PermissionManager.shared.markOnboardingComplete()
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
                PermissionManager.shared.startPeriodicCheck()
                ServiceContainer.shared.startServices()
                self?.startIconUpdater()
            }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to AutoLog"
        window.contentView = NSHostingView(rootView: onboardingView)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)

        // Bring to front even though we're an LSUIElement app
        NSApp.activate(ignoringOtherApps: true)

        self.onboardingWindow = window
    }
}

// MARK: - Side Panel Content

private struct SidePanelContent: View {
    @ObservedObject private var permissionManager = PermissionManager.shared

    private var services: ServiceContainer { ServiceContainer.shared }

    var body: some View {
        if let captureEngine = services.captureEngine {
            AutoLogSidePanelView(
                captureEngine: captureEngine,
                permissionManager: permissionManager,
                storageManager: services.storageManager,
                onOpenEnrichment: {
                    services.panelController?.toggle()
                },
                onOpenDebug: {
                    services.debugController?.toggle()
                }
            )
        } else {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Failed to initialize.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }
}

private struct AutoLogSidePanelView: View {
    @ObservedObject var captureEngine: CaptureEngine
    @ObservedObject var permissionManager: PermissionManager
    var storageManager: StorageManager?

    var onOpenEnrichment: () -> Void
    var onOpenDebug: () -> Void

    @State private var captureCount24h: Int = 0
    @State private var summaryCount24h: Int = 0
    @State private var estimatedCostToday: Double = 0
    @State private var recentCaptures: [CaptureRecord] = []
    @State private var lastError: String?
    @State private var lastSummaryDate: Date?
    @State private var pendingCaptures: Int = 0
    @State private var focusState: AutoLogFocusState?
    @State private var focusDrift: FocusDriftMetrics?

    // Refresh timer fires every 5 seconds to keep stats current
    private let refreshTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: 0) {
                panelCards
            }
            .padding(14)
            .frame(width: 340)
            .onAppear { snapshotState() }
            .onReceive(refreshTimer) { _ in snapshotState() }
        } else {
            panelCards
                .padding(14)
                .frame(width: 340)
                .onAppear { snapshotState() }
                .onReceive(refreshTimer) { _ in snapshotState() }
        }
    }

    private var panelCards: some View {
        VStack(spacing: 10) {
            GlassCard {
                HStack {
                    StatusHeaderView(
                        state: captureEngine.state,
                        isRunning: captureEngine.isRunning
                    )
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }

            GlassCard {
                StatsCardsView(
                    captureCount: captureCount24h,
                    summaryCount: summaryCount24h,
                    estimatedCost: estimatedCostToday
                )
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }

            if focusState != nil {
                GlassCard {
                    FocusStatusView(
                        focusState: focusState,
                        drift: focusDrift
                    )
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            }

            GlassCard {
                VStack(spacing: 8) {
                    SummarizationStatusView(
                        lastSummaryDate: lastSummaryDate,
                        pendingCount: pendingCaptures
                    )
                    Divider().opacity(0.3)
                    IntervalIndicatorView(captureEngine: captureEngine)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }

            GlassCard {
                RecentActivityView(captures: recentCaptures)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }

            let capturesWorking = captureCount24h > 0
            if lastError != nil || (!permissionManager.allPermissionsGranted && !capturesWorking) {
                GlassCard {
                    WarningBannerView(
                        error: lastError,
                        permissionsOK: permissionManager.allPermissionsGranted || capturesWorking
                    )
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }

            GlassCard {
                ActionsView(
                    captureEngine: captureEngine,
                    onOpenEnrichment: onOpenEnrichment,
                    onOpenDebug: onOpenDebug
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            GlassCard {
                QuitButton()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
        }
    }

    private func snapshotState() {
        lastError = captureEngine.lastError

        let focusSnapshot = FocusStateStore.currentSnapshot(storageManager: storageManager)
        focusState = focusSnapshot.current
        focusDrift = focusSnapshot.drift

        guard let storage = storageManager else { return }

        captureCount24h = (try? storage.captureCount24h()) ?? 0
        summaryCount24h = (try? storage.summaryCount24h()) ?? 0
        recentCaptures = (try? storage.recentCaptures(limit: 3)) ?? []

        if let health = try? storage.summarizationHealth() {
            lastSummaryDate = health.lastSummaryDate
            pendingCaptures = health.pendingCount
        }

        if let usage = try? storage.totalTokenUsage24h() {
            let inputCost = usage.inputMtok * 0.25
            let outputCost = usage.outputMtok * 1.25
            estimatedCostToday = inputCost + outputCost
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let startServices = Notification.Name("com.autolog.startServices")
}

// MARK: - Debug Window Controller

/// Manages the debug timeline window for inspecting database contents.
@MainActor
final class DebugWindowController {
    private var window: NSWindow?
    private let storageManager: StorageManager

    init(storageManager: StorageManager) {
        self.storageManager = storageManager
    }

    func toggle() {
        if let window = window, window.isVisible {
            window.orderOut(nil)
        } else {
            show()
        }
    }

    func show() {
        if window == nil {
            createWindow()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createWindow() {
        let contentView = DebugTimelineView(storageManager: storageManager)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 850, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.title = "AutoLog - Database Debug"
        window.contentView = NSHostingView(rootView: contentView)
        window.center()
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("DebugWindow")

        self.window = window
    }
}

// MARK: - Enrichment Panel Controller

/// Manages the floating enrichment panel as an NSPanel.
/// NSPanel with .floating level stays above other windows.
@MainActor
final class EnrichmentPanelController {
    private var panel: NSPanel?
    private let enrichmentEngine: EnrichmentEngine

    init(enrichmentEngine: EnrichmentEngine) {
        self.enrichmentEngine = enrichmentEngine
    }

    func toggle() {
        if let panel = panel, panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        if panel == nil {
            createPanel()
        }
        panel?.center()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func createPanel() {
        let contentView = EnrichmentPanel(enrichmentEngine: enrichmentEngine)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        panel.title = "AutoLog - Enrich Prompt"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: contentView)
        panel.isReleasedWhenClosed = false
        // becomesKeyOnlyIfNeeded must be false so the panel accepts keyboard input
        panel.becomesKeyOnlyIfNeeded = false

        self.panel = panel
    }
}
