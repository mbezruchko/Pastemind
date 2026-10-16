import AppKit
import SwiftUI

/// The field row's symbol (the magnifier, the document, the clipboard, the sparkle). When it changes it crossfades on
/// Core Animation, in the render server at the display's rate: the old one shrinks a little and blurs away while the
/// new one grows into place and sharpens, so the two never read as two icons. SwiftUI's symbol transition held the
/// whole window to 60 Hz while it played (measured 2026-10-13).
struct FieldSymbol: NSViewRepresentable {
    let name: String
    var onMake: (SymbolLayerView) -> Void = { _ in }

    func makeNSView(context: Context) -> SymbolLayerView {
        let view = SymbolLayerView()
        view.set(name, animated: false)
        onMake(view)
        return view
    }

    func updateNSView(_ view: SymbolLayerView, context: Context) {
        guard context.coordinator.name != name else { return }
        context.coordinator.name = name
        view.set(name, animated: view.window?.isVisible == true)
    }

    func makeCoordinator() -> Given { Given(name: name) }

    /// The name SwiftUI last gave, so that only its changes animate (a panel may also set one itself).
    final class Given {
        var name: String
        init(name: String) { self.name = name }
    }
}

final class SymbolLayerView: NSView {
    private var current: String?
    private var shown: CALayer?
    private static let duration: CFTimeInterval = 0.2
    private static let curve = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerUsesCoreImageFilters = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Clicks go through to what's behind: the symbol is a handle to drag the panel by.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        shown?.frame = frame(for: shown)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard let current else { return }
        self.current = nil
        set(current, animated: false)   // drawn again in the new appearance's color
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let current else { return }
        self.current = nil
        set(current, animated: false)
    }

    /// Shows `name`: at once, or crossfading from the symbol shown now.
    func set(_ name: String, animated: Bool) {
        guard name != current, let layer = self.layer else { return }
        current = name
        let incoming = makeLayer(name)
        layer.addSublayer(incoming)
        let outgoing = shown
        shown = incoming
        guard animated, let outgoing, !Motion.reduced else {
            outgoing?.removeFromSuperlayer()
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { outgoing.removeFromSuperlayer() }
        animate(incoming, from: (0, 0.6, 4), to: (1, 1, 0))
        animate(outgoing, from: (1, 1, 0), to: (0, 0.6, 4))
        CATransaction.commit()
    }

    private func makeLayer(_ name: String) -> CALayer {
        let symbol = CALayer()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        // The color resolved for this appearance: a layer's contents don't follow it.
        var color = NSColor.secondaryLabelColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = PanelChrome.fieldSecondary.usingColorSpace(.sRGB) ?? color
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: PanelChrome.iconSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) {
            symbol.contents = image.layerContents(forContentsScale: scale)
            symbol.bounds = NSRect(origin: .zero, size: image.size)
        }
        symbol.contentsScale = scale
        symbol.contentsGravity = .center
        let blur = CIFilter(name: "CIGaussianBlur")!
        blur.setValue(0, forKey: kCIInputRadiusKey)
        blur.name = "blur"
        symbol.filters = [blur]
        symbol.frame = frame(for: symbol)
        return symbol
    }

    private func frame(for symbol: CALayer?) -> NSRect {
        let size = symbol?.bounds.size ?? .zero
        return NSRect(x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded(),
                      width: size.width, height: size.height)
    }

    /// Opacity, scale and blur radius, from one state to the other.
    private func animate(_ symbol: CALayer, from: (Float, CGFloat, CGFloat), to: (Float, CGFloat, CGFloat)) {
        symbol.opacity = to.0
        symbol.transform = CATransform3DMakeScale(to.1, to.1, 1)
        symbol.setValue(to.2, forKeyPath: "filters.blur.inputRadius")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from.0
        fade.toValue = to.0
        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = CATransform3DMakeScale(from.1, from.1, 1)
        grow.toValue = CATransform3DMakeScale(to.1, to.1, 1)
        let blur = CABasicAnimation(keyPath: "filters.blur.inputRadius")
        blur.fromValue = from.2
        blur.toValue = to.2
        let group = CAAnimationGroup()
        group.animations = [fade, grow, blur]
        group.duration = Self.duration
        group.timingFunction = Self.curve
        group.preferredFrameRateRange = Motion.frameRate
        symbol.add(group, forKey: "swap")
    }
}
