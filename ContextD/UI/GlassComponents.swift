import AppKit
import QuartzCore
import SwiftUI

struct GlassCard<Content: View>: View {
    let cornerRadius: CGFloat
    let baseFillOpacity: Double
    let hoverFillOpacity: Double
    let baseSheenOpacity: Double
    let hoverSheenOpacity: Double
    @ViewBuilder let content: Content
    @State private var isHovered = false

    init(
        cornerRadius: CGFloat = 22,
        baseFillOpacity: Double = 0.006,
        hoverFillOpacity: Double = 0.014,
        baseSheenOpacity: Double = 0.02,
        hoverSheenOpacity: Double = 0.045,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.baseFillOpacity = baseFillOpacity
        self.hoverFillOpacity = hoverFillOpacity
        self.baseSheenOpacity = baseSheenOpacity
        self.hoverSheenOpacity = hoverSheenOpacity
        self.content = content()
    }

    var body: some View {
        Group {
            if #available(macOS 26, *) {
                content
                    .background(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(.white.opacity(isHovered ? hoverFillOpacity : baseFillOpacity))
                    )
                    .overlay { reflectiveGlassBorder }
                    .overlay(alignment: .top) { clearGlassSheen }
                    .shadow(
                        color: .black.opacity(isHovered ? 0.12 : 0.08),
                        radius: isHovered ? 18 : 14,
                        y: 4
                    )
                    .glassEffect(
                        .clear.interactive(),
                        in: .rect(cornerRadius: cornerRadius)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                content
                    .background { cardBackdrop }
                    .overlay { cardOutline }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    private var cardBackdrop: some View {
        ZStack {
            GaussianBackdropBlur(
                material: .popover,
                blendingMode: .behindWindow,
                intensity: isHovered ? 0.55 : 0.46
            )

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.white.opacity(isHovered ? 0.035 : 0.018))
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var cardOutline: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        .white.opacity(isHovered ? 0.22 : 0.14),
                        .white.opacity(0.05),
                        .white.opacity(isHovered ? 0.14 : 0.1),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.75
            )
    }

    private var clearGlassSheen: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        .white.opacity(isHovered ? hoverSheenOpacity : baseSheenOpacity),
                        .white.opacity(0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(height: 16)
            .blur(radius: 6)
            .mask(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var reflectiveGlassBorder: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        .white.opacity(isHovered ? 0.34 : 0.22),
                        .white.opacity(0.08),
                        .white.opacity(isHovered ? 0.18 : 0.12),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.85
            )
    }
}

struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

final class PanelBlurView: NSVisualEffectView {
    private var customBlurRadius: CGFloat = 30.0
    private var isObservingLayers = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        blendingMode = .behindWindow
        material = .hudWindow
        state = .active
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    func updateIntensity(_ amount: Double) {
        let clamped = CGFloat(min(max(amount, 0), 1))
        customBlurRadius = 15.0 + clamped * 35.0
        alphaValue = 0.7 + clamped * 0.3
        applyCustomBlurRadius()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.applyCustomBlurRadius()
            self?.startObservingLayers()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.applyCustomBlurRadius()
        }
    }

    private func applyCustomBlurRadius() {
        guard let rootLayer = layer else { return }
        applyBlurToLayerTree(rootLayer)
    }

    private func applyBlurToLayerTree(_ layer: CALayer) {
        if let filters = layer.filters {
            for case let filter as NSObject in filters {
                applyRadiusIfBlurFilter(filter)
            }
        }
        if let bgFilters = layer.backgroundFilters {
            for case let filter as NSObject in bgFilters {
                applyRadiusIfBlurFilter(filter)
            }
        }
        for sublayer in layer.sublayers ?? [] {
            applyBlurToLayerTree(sublayer)
        }
    }

    private func applyRadiusIfBlurFilter(_ filter: NSObject) {
        let selector = NSSelectorFromString("setValue:forKey:")
        guard filter.responds(to: selector) else { return }
        filter.setValue(NSNumber(value: Float(customBlurRadius)), forKey: "inputRadius")
    }

    private func startObservingLayers() {
        guard !isObservingLayers, let rootLayer = layer else { return }
        isObservingLayers = true
        rootLayer.addObserver(self, forKeyPath: "sublayers", options: [.new], context: nil)
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        if keyPath == "sublayers" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.applyCustomBlurRadius()
            }
        }
    }
}

struct GaussianBackdropBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    let intensity: Double

    func makeNSView(context: Context) -> PanelBlurView {
        let view = PanelBlurView(frame: .zero)
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = false
        view.updateIntensity(intensity)
        return view
    }

    func updateNSView(_ nsView: PanelBlurView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.updateIntensity(intensity)
    }
}
