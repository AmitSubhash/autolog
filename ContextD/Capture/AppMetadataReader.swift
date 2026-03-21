import Foundation
import AppKit

/// Extracts enhanced accessibility metadata from the focused window:
/// document path, URL, and focused UI element role.
/// Complements AccessibilityReader by extracting metadata beyond window title.
final class AppMetadataReader: Sendable {
    private let logger = DualLogger(category: "AppMetadata")

    /// Enhanced metadata extracted from the focused window's AX tree.
    struct EnhancedMetadata: Sendable {
        /// File path of the document in the focused window (from kAXDocumentAttribute).
        /// Works for Xcode, TextEdit, Pages, Preview, etc.
        let documentPath: String?

        /// URL associated with the focused window (from kAXURLAttribute).
        /// Works for Safari and some document-based apps.
        let browserURL: String?

        /// The AX role of the currently focused UI element (e.g., "AXTextField", "AXWebArea").
        let focusedElementRole: String?
    }

    /// Read enhanced metadata from the focused window of the given app.
    /// Returns nil fields gracefully if attributes are unavailable.
    /// Sets a 100ms messaging timeout to avoid hangs from unresponsive apps.
    @MainActor
    func readEnhancedMetadata(for app: NSRunningApplication?) -> EnhancedMetadata {
        guard let app = app, AXIsProcessTrusted() else {
            return EnhancedMetadata(documentPath: nil, browserURL: nil, focusedElementRole: nil)
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        // Get the focused window
        var windowValue: AnyObject?
        let windowResult = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &windowValue
        )
        guard windowResult == .success, let window = windowValue,
              CFGetTypeID(window as CFTypeRef) == AXUIElementGetTypeID() else {
            return EnhancedMetadata(documentPath: nil, browserURL: nil, focusedElementRole: nil)
        }
        let axWindow = window as! AXUIElement

        // Set 100ms timeout to avoid hangs
        AXUIElementSetMessagingTimeout(axWindow, 0.1)

        let documentPath = readDocumentPath(from: axWindow)
        let browserURL = readURL(from: axWindow)
        let focusedElementRole = readFocusedElementRole(from: appElement)

        return EnhancedMetadata(
            documentPath: documentPath,
            browserURL: browserURL,
            focusedElementRole: focusedElementRole
        )
    }

    // MARK: - Private Helpers

    /// Extract document path from kAXDocumentAttribute (file:// URL -> POSIX path).
    private func readDocumentPath(from window: AXUIElement) -> String? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            window, kAXDocumentAttribute as CFString, &value
        )
        guard result == .success, let urlString = value as? String else { return nil }

        // kAXDocumentAttribute returns a file:// URL string
        if let url = URL(string: urlString), url.isFileURL {
            return url.path
        }
        return urlString
    }

    /// Extract URL from kAXURLAttribute.
    private func readURL(from window: AXUIElement) -> String? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            window, kAXURLAttribute as CFString, &value
        )
        guard result == .success else { return nil }

        if let urlString = value as? String {
            return urlString
        }
        // Some apps return a CFURL instead of a string
        if CFGetTypeID(value) == CFURLGetTypeID() {
            let cfURL = value as! CFURL
            return (cfURL as URL).absoluteString
        }
        return nil
    }

    /// Read the role of the currently focused UI element.
    private func readFocusedElementRole(from appElement: AXUIElement) -> String? {
        var focusedValue: AnyObject?
        let focusedResult = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &focusedValue
        )
        guard focusedResult == .success, let focusedElement = focusedValue,
              CFGetTypeID(focusedElement as CFTypeRef) == AXUIElementGetTypeID() else { return nil }

        let axFocused = focusedElement as! AXUIElement
        AXUIElementSetMessagingTimeout(axFocused, 0.1)

        var roleValue: AnyObject?
        let roleResult = AXUIElementCopyAttributeValue(
            axFocused, kAXRoleAttribute as CFString, &roleValue
        )
        guard roleResult == .success, let role = roleValue as? String else { return nil }
        return role
    }
}
