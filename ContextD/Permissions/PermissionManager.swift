import AppKit
import CoreGraphics
import Foundation

/// Manages checking and requesting macOS permissions required by AutoLog.
///
/// Screen Recording: Requested via `CGRequestScreenCaptureAccess()` during
/// onboarding to get AutoLog into the TCC Screen Recording list. Because
/// `CGPreflightScreenCaptureAccess()` can be stale after re-codesign, we back it
/// up with a functional capture probe before reporting success.
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
        screenRecordingGranted = checkScreenRecording()
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
        let newAccessibility = checkAccessibility()
        if newAccessibility != accessibilityGranted {
            accessibilityGranted = newAccessibility
        }

        if checkScreenRecording() {
            screenRecordingPollTask?.cancel()
            if !screenRecordingGranted {
                screenRecordingGranted = true
            }
            return
        }
        refreshScreenRecordingStatus()
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

    func checkScreenRecording() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Request Screen Recording permission. This calls CGRequestScreenCaptureAccess()
    /// which adds AutoLog to the TCC Screen Recording list and opens the system prompt.
    /// Also opens System Settings as a fallback.
    func requestScreenRecording() {
        NSApp.activate(ignoringOtherApps: true)
        if !CGPreflightScreenCaptureAccess() {
            let granted = CGRequestScreenCaptureAccess()
            logger.info("CGRequestScreenCaptureAccess returned \(granted)")
        }
        openScreenRecordingSettings()

        // Poll with a real capture probe because CGPreflight can remain stale.
        screenRecordingPollTask?.cancel()
        screenRecordingPollTask = Task { [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                let granted = await Self.probeScreenRecordingAccess()
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

    /// After onboarding completes, refresh using the functional probe instead of
    /// forcing a granted state.
    func markOnboardingComplete() {
        refreshScreenRecordingStatus()
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

    private func refreshScreenRecordingStatus() {
        screenRecordingPollTask?.cancel()
        screenRecordingPollTask = Task { [weak self] in
            let granted = await Self.probeScreenRecordingAccess()
            guard !Task.isCancelled else { return }
            self?.screenRecordingGranted = granted
        }
    }

    private static func probeScreenRecordingAccess() async -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }

        return await Task.detached(priority: .utility) {
            let probeRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            return CGDisplayCreateImage(CGMainDisplayID(), rect: probeRect) != nil
        }.value
    }
}
