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

    /// Poll permissions every 5 seconds so the UI updates promptly.
    private func startPeriodicCheck() {
        periodicCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { break }
                self?.refreshStatus()
            }
        }
    }

    // MARK: - Screen Recording

    /// Read-only check using CGPreflightScreenCaptureAccess (does NOT trigger a prompt).
    /// Only CGRequestScreenCaptureAccess triggers the system dialog.
    func checkScreenRecording() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Open Screen Recording settings and poll for permission grant.
    func requestScreenRecording() {
        openScreenRecordingSettings()

        screenRecordingPollTask?.cancel()
        screenRecordingPollTask = Task { [weak self] in
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                self?.refreshStatus()
                if self?.screenRecordingGranted == true { break }
            }
        }
    }

    // MARK: - Accessibility

    /// Check if Accessibility permission is granted.
    /// Uses a functional test (reading frontmost app's AX attributes) instead of
    /// AXIsProcessTrusted() which returns stale results after re-signing on macOS 15+.
    func checkAccessibility() -> Bool {
        // First try the API check
        if AXIsProcessTrusted() { return true }

        // AXIsProcessTrusted() can return false even when granted (macOS 15+ re-signing).
        // Try actually using the AX API as a functional test.
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return false }
        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value)
        // If we get .success or .noValue (app has no window), AX is working.
        // Only .apiDisabled or .notImplemented means truly not granted.
        return result == .success || result == .noValue
    }

    /// Request Accessibility permission. Opens System Settings directly.
    func requestAccessibility() {
        openAccessibilitySettings()

        // Poll rapidly for 30 seconds after the user opens settings
        screenRecordingPollTask?.cancel()
        screenRecordingPollTask = Task { [weak self] in
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                self?.refreshStatus()
                if self?.accessibilityGranted == true { break }
            }
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
