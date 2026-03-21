import Foundation
import AppKit

/// Manages checking and requesting macOS permissions required by AutoLog.
/// Required: Screen Recording (for screencapture CLI) and Accessibility (AXUIElement).
@MainActor
final class PermissionManager: ObservableObject {
    static let shared = PermissionManager()

    private let logger = DualLogger(category: "Permissions")

    @Published var screenRecordingGranted: Bool = false
    @Published var accessibilityGranted: Bool = false

    /// Periodic re-check task. Only started after onboarding completes.
    private var periodicCheckTask: Task<Void, Never>?

    /// Rapid-poll tasks for each permission (after user clicks Grant).
    private var screenRecordingPollTask: Task<Void, Never>?
    private var accessibilityPollTask: Task<Void, Never>?

    var allPermissionsGranted: Bool {
        screenRecordingGranted && accessibilityGranted
    }

    private init() {
        // Check once at init. Do NOT start periodic polling here --
        // polling starts only after onboarding via startPeriodicCheck().
        refreshStatus()
    }

    deinit {
        periodicCheckTask?.cancel()
        screenRecordingPollTask?.cancel()
        accessibilityPollTask?.cancel()
    }

    /// Re-check all permission statuses.
    func refreshStatus() {
        let newScreen = checkScreenRecording()
        let newAccessibility = checkAccessibility()
        if newScreen != screenRecordingGranted {
            screenRecordingGranted = newScreen
        }
        if newAccessibility != accessibilityGranted {
            accessibilityGranted = newAccessibility
        }
        logger.info("Permissions - Screen Recording: \(self.screenRecordingGranted), Accessibility: \(self.accessibilityGranted)")
    }

    // MARK: - Periodic Re-check

    /// Start periodic polling. Call ONLY after onboarding completes.
    func startPeriodicCheck() {
        guard periodicCheckTask == nil else { return }
        periodicCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { break }
                self?.refreshStatus()
            }
        }
    }

    // MARK: - Screen Recording

    /// Read-only check. CGPreflightScreenCaptureAccess does not prompt.
    func checkScreenRecording() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Register the app in TCC (shows system prompt once), then open Settings.
    /// After the user responds, CGPreflightScreenCaptureAccess reflects the grant.
    func requestScreenRecording() {
        // This is the ONLY way to make the app appear in
        // System Settings > Privacy > Screen Recording.
        // Safe to call multiple times; after first response it's a no-op.
        CGRequestScreenCaptureAccess()

        openScreenRecordingSettings()

        // Rapid-poll for 60 seconds after user opens settings
        screenRecordingPollTask?.cancel()
        screenRecordingPollTask = Task { [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                self?.refreshStatus()
                if self?.screenRecordingGranted == true { break }
            }
        }
    }

    // MARK: - Accessibility

    /// Check if Accessibility permission is granted.
    /// AXIsProcessTrusted() is authoritative in production builds.
    func checkAccessibility() -> Bool {
        AXIsProcessTrusted()
    }

    /// Open Accessibility settings and rapid-poll for grant.
    func requestAccessibility() {
        // Prompt + open settings
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        openAccessibilitySettings()

        // Rapid-poll for 60 seconds
        accessibilityPollTask?.cancel()
        accessibilityPollTask = Task { [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                self?.refreshStatus()
                if self?.accessibilityGranted == true { break }
            }
        }
    }

    // MARK: - Open System Settings

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
