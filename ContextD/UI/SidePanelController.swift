import AppKit
import SwiftUI

/// Manages a floating side panel anchored to the right edge of the screen.
@MainActor
final class SidePanelController {
    private var panel: NSPanel?
    private var clickMonitor: Any?
    private let contentProvider: () -> AnyView

    var isVisible: Bool { panel?.isVisible ?? false }

    init<Content: View>(@ViewBuilder content: @escaping () -> Content) {
        self.contentProvider = { AnyView(content()) }
    }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        if panel == nil { createPanel() }
        guard let panel, let screen = NSScreen.main else { return }

        let width: CGFloat = 360
        let margin: CGFloat = 10
        let visible = screen.visibleFrame

        let x = visible.maxX - width - margin
        let y = visible.minY + margin
        let h = visible.height - margin * 2

        panel.setFrame(NSRect(x: x, y: y, width: width, height: h), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1.0
        }

        setupClickOutsideMonitor()
    }

    func hide() {
        teardownClickOutsideMonitor()
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                panel.alphaValue = 1.0
            }
        })
    }

    private func createPanel() {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow

        let content = ScrollView(.vertical, showsIndicators: false) {
            contentProvider()
                .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        let hostingView = NSHostingView(rootView: content)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        panel.contentView = hostingView
        self.panel = panel
    }

    private func setupClickOutsideMonitor() {
        teardownClickOutsideMonitor()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                if !panel.frame.contains(NSEvent.mouseLocation) {
                    self.hide()
                }
            }
        }
    }

    private func teardownClickOutsideMonitor() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }
}
