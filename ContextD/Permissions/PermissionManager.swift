import Foundation
import AppKit

/// Manages checking and requesting macOS permissions required by AutoLog.
///
/// Screen Recording: NOT checked via any CG API. The app uses the system
/// `screencapture` CLI which is pre-authorized. Calling CGPreflightScreenCaptureAccess
/// or CGRequestScreenCaptureAccess triggers the macOS permission prompt on every
/// upgrade (ad-hoc signing generates a new signature each time, invalidating TCC).
/// Instead, screen recording is always reported as granted and captures fail gracefully.
///
/// Accessibility: Checked via AXIsProcessTrusted().
@MainActor
final class PermissionManager: ObservableObject {
    static let shared = PermissionManager()

    private let logger = DualLogger(category: "Permissions")

    @Published var screenRecordingGranted: Bool = true
    @Published var accessibilityGranted: Bool = false

    private var periodicCheckTask: Task<Void, Never>?
    private var accessibilityPollTask: Task<Void, Never>?

    var allPermissionsGranted: Bool {
        screenRecordingGranted && accessibilityGranted
    }

    private init() {
        accessibilityGranted = checkAccessibility()
        logger.info("Permissions - Accessibility: \(self.accessibilityGranted)")
    }

    deinit {
        periodicCheckTask?.cancel()
        accessibilityPollTask?.cancel()
    }

    func refreshStatus() {
        let newAccessibility = checkAccessibility()
        if newAccessibility != accessibilityGranted {
            accessibilityGranted = newAccessibility
        }
    }

    // MARK: - Periodic Re-check

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

    /// Always true. We use the system `screencapture` CLI which does not require
    /// per-app Screen Recording permission. No CG APIs are called.
    func checkScreenRecording() -> Bool { true }

    /// Opens Screen Recording settings for informational purposes.
    /// Does NOT call CGRequestScreenCaptureAccess (would trigger prompt on upgrades).
    func requestScreenRecording() {
        openScreenRecordingSettings()
    }

    // MARK: - Accessibility

    func checkAccessibility() -> Bool {
        AXIsProcessTrusted()
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        openAccessibilitySettings()

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
