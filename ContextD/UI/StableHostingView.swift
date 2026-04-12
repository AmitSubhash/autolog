import AppKit
import SwiftUI

/// Creates an NSHostingView configured for standalone AppKit windows and panels.
///
/// Disabling automatic sizing propagation avoids SwiftUI feeding content min/max
/// size updates back into AppKit window constraint cycles.
@MainActor
func makeStableHostingView<Content: View>(rootView: Content) -> NSHostingView<Content> {
    let hostingView = NSHostingView(rootView: rootView)
    if #available(macOS 13.0, *) {
        hostingView.sizingOptions = []
    }
    hostingView.translatesAutoresizingMaskIntoConstraints = true
    hostingView.autoresizingMask = [.width, .height]
    return hostingView
}
