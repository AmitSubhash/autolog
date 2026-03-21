import Foundation
import AppKit

/// Manages checking and requesting macOS permissions required by ContextD.
/// Required permissions: Screen Recording (ScreenCaptureKit) and Accessibility (AXUIElement).
@MainActor
final class PermissionManager: ObservableObject {
    static let shared = PermissionManager()

    private let logger = DualLogger(category: "Permissions")

    @Published var screenRecordingGranted: Bool = false
    @Published var accessibilityGranted: Bool = false

    /// Active periodic re-check task. Cancelled on deinit.
    private var periodicCheckTask: Task<Void, Never>?

    /// Active polling task used after requesting screen recording permission.
    private var screenRecordingPollTask: Task<Void, Never>?

    var allPermissionsGranted: Bool {
        screenRecordingGranted && accessibilityGranted
    }

    private init() {
        refreshStatus()
        startPeriodicCheck()
    }

    deinit {
        periodicCheckTask?.cancel()
        screenRecordingPollTask?.cancel()
    }

    /// Re-check all permission statuses.
    func refreshStatus() {
        let newScreen = checkScreenRecording()
        let newAccessibility = checkAccessibility()
        // Only publish changes when values actually differ to avoid unnecessary UI updates.
        if newScreen != screenRecordingGranted {
            screenRecordingGranted = newScreen
        }
        if newAccessibility != accessibilityGranted {
            accessibilityGranted = newAccessibility
        }
        logger.info("Permissions - Screen Recording: \(self.screenRecordingGranted), Accessibility: \(self.accessibilityGranted)")
    }

    // MARK: - Periodic Re-check

    /// Poll permissions every 30 seconds so revocations are detected promptly.
    private func startPeriodicCheck() {
        periodicCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                self?.refreshStatus()
            }
        }
    }

    // MARK: - Screen Recording

    /// Check if Screen Recording permission is granted.
    /// Since we use the system `screencapture` CLI (pre-authorized), we always
    /// return true and never call CGPreflightScreenCaptureAccess or
    /// CGRequestScreenCaptureAccess, which trigger the macOS Sequoia permission
    /// dialog on every app launch.
    func checkScreenRecording() -> Bool {
        true
    }

    /// No-op: screencapture CLI does not require per-app Screen Recording permission.
    func requestScreenRecording() {
        screenRecordingGranted = true
        logger.info("Screen Recording: using system screencapture CLI (always authorized)")
    }

    // MARK: - Accessibility

    /// Check if Accessibility permission is granted (does not prompt).
    func checkAccessibility() -> Bool {
        AXIsProcessTrusted()
    }

    /// Request Accessibility permission. Shows the system dialog directing user to System Settings.
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let granted = AXIsProcessTrustedWithOptions(options)
        accessibilityGranted = granted
        if !granted {
            logger.warning("Accessibility permission not granted. User must enable manually.")
        }
    }

    // MARK: - Open System Settings

    /// Open System Settings to the Screen Recording privacy pane.
    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Open System Settings to the Accessibility privacy pane.
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
