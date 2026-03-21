import Foundation
import AppKit

/// Reads basic accessibility metadata: frontmost app, focused window title,
/// and list of visible windows. Uses AXUIElement API and CGWindowList.
final class AccessibilityReader: Sendable {
    private let logger = DualLogger(category: "Accessibility")
    private let metadataReader = AppMetadataReader()

    /// Metadata about the current screen state.
    struct ScreenMetadata: Sendable {
        let appName: String
        let appBundleID: String?
        let windowTitle: String?
        let visibleWindows: [VisibleWindow]
        let documentPath: String?
        let browserURL: String?
        let focusedElementRole: String?
    }

    /// Read current screen metadata. Safe to call from any thread.
    @MainActor
    func readCurrentState() -> ScreenMetadata {
        let frontmostApp = NSWorkspace.shared.frontmostApplication

        let appName = frontmostApp?.localizedName ?? "Unknown"
        let appBundleID = frontmostApp?.bundleIdentifier
        let windowTitle = getWindowTitle(for: frontmostApp)
        let visibleWindows = getVisibleWindows()
        let enhanced = metadataReader.readEnhancedMetadata(for: frontmostApp)

        return ScreenMetadata(
            appName: appName,
            appBundleID: appBundleID,
            windowTitle: windowTitle,
            visibleWindows: visibleWindows,
            documentPath: enhanced.documentPath,
            browserURL: enhanced.browserURL,
            focusedElementRole: enhanced.focusedElementRole
        )
    }

    /// Get the focused window title using the Accessibility API.
    @MainActor
    private func getWindowTitle(for app: NSRunningApplication?) -> String? {
        guard let app = app else { return nil }
        guard AXIsProcessTrusted() else {
            logger.debug("Accessibility not trusted, cannot read window title")
            return nil
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var windowValue: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        )

        guard result == .success, let windowElement = windowValue else {
            return nil
        }

        // AXUIElement is a CFTypeRef; CFTypeID check is the safe pattern
        let axWindow = windowElement as! AXUIElement

        var titleValue: AnyObject?
        let titleResult = AXUIElementCopyAttributeValue(
            axWindow,
            kAXTitleAttribute as CFString,
            &titleValue
        )

        guard titleResult == .success, let title = titleValue as? String else {
            return nil
        }

        return title
    }

    /// Get a list of visible windows using NSWorkspace + AXUIElement.
    /// Avoids CGWindowListCopyWindowInfo which triggers Screen Recording prompts
    /// on macOS Sequoia when reading window titles from other apps.
    @MainActor
    private func getVisibleWindows() -> [VisibleWindow] {
        var windows: [VisibleWindow] = []

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  !app.isHidden,
                  let name = app.localizedName else { continue }

            // Use Accessibility API to get main window title (already permitted)
            var title: String?
            if AXIsProcessTrusted() {
                let axApp = AXUIElementCreateApplication(app.processIdentifier)
                // Set timeout BEFORE first AX call to avoid blocking on hung apps
                AXUIElementSetMessagingTimeout(axApp, 0.1)
                var windowValue: AnyObject?
                if AXUIElementCopyAttributeValue(
                    axApp, kAXMainWindowAttribute as CFString, &windowValue
                ) == .success,
                   CFGetTypeID(windowValue as CFTypeRef) == AXUIElementGetTypeID() {
                    var titleValue: AnyObject?
                    let axWin = windowValue as! AXUIElement
                    if AXUIElementCopyAttributeValue(
                        axWin, kAXTitleAttribute as CFString, &titleValue
                    ) == .success {
                        title = titleValue as? String
                    }
                }
            }

            windows.append(VisibleWindow(appName: name, windowTitle: title))
        }

        return windows
    }
}
