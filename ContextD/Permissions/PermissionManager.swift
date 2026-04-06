import AppKit
import Foundation

/// Manages checking and requesting macOS permissions required by AutoLog.
///
/// Screen Recording: Requested via `CGRequestScreenCaptureAccess()` during
/// onboarding to get AutoLog into the TCC Screen Recording list. After that,
/// we do NOT re-check with `CGPreflightScreenCaptureAccess()` because macOS 15+
/// returns stale results after re-codesign. Screen recording is optimistically
/// reported as granted after onboarding; captures fail gracefully if revoked.
///
/// Accessibility: Checked via AXIsProcessTrusted().
@MainActor
final class PermissionManager: ObservableObject {
    static let shared = PermissionManager()

    private let logger = DualLogger(category: "Permissions")

    @Published var screenRecordingGranted: Bool = false
    @Published var accessibilityGranted: Bool = false

    private var periodicCheckTask: Task<Void, Never>?
    private var accessibilityPollTask: Task<Void, Never>?
    private var screenRecordingPollTask: Task<Void, Never>?

    var allPermissionsGranted: Bool {
        screenRecordingGranted && accessibilityGranted
    }

    private init() {
        // Check screen recording once at init. After onboarding, we stop re-checking
        // because macOS 15+ can report stale status after re-codesign.
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        accessibilityGranted = checkAccessibility()
        logger.info(
            "Permissions - Screen: \(self.screenRecordingGranted), Accessibility: \(self.accessibilityGranted)"
        )
    }

    deinit {
        periodicCheckTask?.cancel()
        accessibilityPollTask?.cancel()
        screenRecordingPollTask?.cancel()
    }

    func refreshStatus() {
        let newScreen = CGPreflightScreenCaptureAccess()
        let newAccessibility = checkAccessibility()
        if newScreen != screenRecordingGranted {
            screenRecordingGranted = newScreen
        }
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
                // Only re-check accessibility. Screen recording status can be stale
                // after re-codesign, so we trust the initial grant + graceful failure.
                let newAccessibility = self?.checkAccessibility() ?? false
                if newAccessibility != self?.accessibilityGranted {
                    self?.accessibilityGranted = newAccessibility
                }
            }
        }
    }

    // MARK: - Screen Recording

    func checkScreenRecording() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Request Screen Recording permission. This calls CGRequestScreenCaptureAccess()
    /// which adds AutoLog to the TCC Screen Recording list and opens the system prompt.
    /// Also opens System Settings as a fallback.
    func requestScreenRecording() {
        if !CGPreflightScreenCaptureAccess() {
            let granted = CGRequestScreenCaptureAccess()
            logger.info("CGRequestScreenCaptureAccess returned \(granted)")
        }
        openScreenRecordingSettings()

        // Poll for permission grant
        screenRecordingPollTask?.cancel()
        screenRecordingPollTask = Task { [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                let granted = CGPreflightScreenCaptureAccess()
                if granted {
                    self?.screenRecordingGranted = true
                    break
                }
            }
        }
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

    // MARK: - Post-Onboarding

    /// After onboarding completes, optimistically mark screen recording as granted.
    /// The user went through the permission flow; captures will fail gracefully
    /// if they actually didn't grant it. This avoids stale CGPreflight results
    /// blocking service startup on macOS 15+.
    func markOnboardingComplete() {
        screenRecordingGranted = true
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
