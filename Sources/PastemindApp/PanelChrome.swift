import AppKit
import SwiftUI

/// The look both panels share: glass (vibrancy before macOS 26) under the SwiftUI content, all of it clipped to one
/// continuous rounded rectangle.
enum PanelChrome {
    /// Rounded corners once a panel has a body. With only its field, a panel is a capsule (Spotlight's search bar),
    /// and it turns from one into the other over its first 60 points of growth.
    static let cornerRadius: CGFloat = 26

    static func cornerRadius(forHeight height: CGFloat) -> CGFloat {
        let capsule = fieldHeight / 2
        let progress = min(max((height - fieldHeight) / 60, 0), 1)
        return capsule + (cornerRadius - capsule) * progress
    }

    /// Nothing over the glass: Liquid Glass shows through; its own tint darkens it.
    static let tint = Color.clear

    /// Both panels share their field's geometry, so switching between them reads as one panel changing mode: the
    /// field stays put, and the clipboard's body appears under it or goes away. Search is Spotlight's size (macOS 26,
    /// measured from screenshots 2026-10-13: 640 × 56, the text 26 points, the magnifier 24): turning into the
    /// clipboard, it widens to the clipboard's width as the body comes in.
    static let width: CGFloat = 760
    static let searchWidth: CGFloat = 640
    static let fieldHeight: CGFloat = 56
    /// The glass is never shorter than this (the clipboard's height), whatever the window's: Liquid Glass draws a short
    /// pane thinner, and the search capsule blurred less of what's behind than the clipboard did.
    static let glassHeight: CGFloat = 470
    static let fieldFontSize: CGFloat = 26
    static let iconSize: CGFloat = 24
    /// The field's symbol and placeholder: brighter than the secondary label color, as Spotlight's (measured: about
    /// two thirds of white on its glass).
    static let fieldSecondary = NSColor.labelColor.withAlphaComponent(0.65)
    /// The placeholder, quieter than the symbol: at two thirds it read almost as typed text.
    static let fieldPlaceholder = NSColor.labelColor.withAlphaComponent(0.42)

    /// How high up the screen's visible area a panel's field opens, its top edge where Spotlight's is: 22.5% of the
    /// way down.
    static let openingHeight: CGFloat = 0.775

    /// Where a panel opens on its own, as the middle of its field's top edge, on the screen with the pointer: centered,
    /// at `openingHeight`. A dragged panel stays where it's put only until it closes.
    static func topCenter() -> NSPoint {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: area.midX.rounded(), y: (area.minY + openingHeight * area.height).rounded())
    }

    /// The tallest the window gets, in either mode (search with nine rows).
    static var tallest: CGFloat { max(PanelController.height, LauncherController.maxHeight) }

    /// A panel of `size` with its field's top edge centered on `anchor`, moved in where it would leave the screen.
    static func frame(_ size: NSSize, at anchor: NSPoint) -> NSRect {
        var frame = NSRect(x: (anchor.x - size.width / 2).rounded(), y: anchor.y - size.height, width: size.width,
                           height: size.height)
        let screen = NSScreen.screens.first { NSPointInRect(NSPoint(x: anchor.x, y: anchor.y - 1), $0.frame) }
        if let area = (screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = min(max(frame.minX, area.minX), area.maxX - frame.width)
            frame.origin.y = max(min(frame.minY, area.maxY - frame.height), area.minY)
        }
        return frame
    }

    /// Dragged this close to the screen's middle, a panel snaps to it (and holds there until dragged further).
    static let snapDistance: CGFloat = 12

    /// The window's content view. Clipping the container (not only the glass and the SwiftUI view inside it) means not
    /// one pixel outside the rounded shape is ever drawn, so the shadow WindowServer derives from the window's alpha
    /// follows the corners. Without it a panel showed a square outline and shadow around its rounded corners
    /// (seen 2026-10-13 in an installed build, never in a debug run: it depends on when the glass first renders).
    ///
    /// With `pinnedHeight`, the content keeps that height and stays at the top while the window is shorter: a growing
    /// window uncovers it like a blind going up, instead of laying it out again every frame.
    ///
    /// `frosted`: the glass blurs what's behind it harder (see `PanelContainer.boostBlur`): for the settings, read at
    /// length over whatever window is behind.
    static func container(containing content: NSView, pinnedHeight: CGFloat? = nil, frosted: Bool = false) -> NSView {
        PanelContainer(content: content, pinnedHeight: pinnedHeight, frosted: frosted)
    }

    /// The shadow follows what's drawn now: after showing or resizing a panel.
    static func refreshShadow(of window: NSWindow) {
        window.displayIfNeeded()
        window.invalidateShadow()
        // Glass renders a moment after the window's first display: once more when it has.
        DispatchQueue.main.async { window.invalidateShadow() }
    }
}

/// The panel's content view: glass, then the SwiftUI content, clipped to a rounded shape whose radius follows the
/// height on every resize (animation steps included): a capsule with only the field, rounded corners with a body.
final class PanelContainer: NSView {
    private let backdrop: NSView
    /// Content as tall as the window (Settings), kept so here: resized along from its own first size, it came out
    /// taller than the window, its top cut off. Nil: pinned to the top at its height (the panels).
    private let filling: NSView?
    /// The glass's own blur, made stronger (see `boostBlur`); nil: as it comes.
    private let blurRadius: CGFloat?
    private var observers: [NSObjectProtocol] = []
    private var blurTimer: Timer?

    init(content: NSView, pinnedHeight: CGFloat?, frosted: Bool = false) {
        // 4 as it comes: a busy window behind showed through in streaks. Past ~40 it looks no different.
        blurRadius = frosted ? 40 : nil
        filling = pinnedHeight == nil ? content : nil
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            // Apple's standard Liquid Glass, untinted, as Spotlight's: a light blur of what's behind (clear glass,
            // unblurred, read badly over busy windows). A black tint at 30% made the panels far darker than Spotlight.
            glass.style = .regular
            backdrop = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.state = .active
            effect.blendingMode = .behindWindow
            backdrop = effect
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        addSubview(backdrop)
        if let pinnedHeight {
            content.frame = NSRect(x: 0, y: bounds.height - pinnedHeight, width: bounds.width, height: pinnedHeight)
            content.autoresizingMask = [.width, .minYMargin]
        } else {
            content.frame = bounds
        }
        addSubview(content)
        updateShape()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        filling?.frame = bounds
        updateShape()
    }

    private func updateShape() {
        let radius = PanelChrome.cornerRadius(forHeight: bounds.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = radius
        CATransaction.commit()
        // Down from the top, as tall as it needs to be; the rounded clip above cuts it to the window's shape.
        let glassHeight = max(bounds.height, PanelChrome.glassHeight)
        backdrop.frame = NSRect(x: 0, y: bounds.height - glassHeight, width: bounds.width, height: glassHeight)
        if #available(macOS 26.0, *), let glass = backdrop as? NSGlassEffectView { glass.cornerRadius = radius }
        boostBlur()
    }

    override func layout() {
        super.layout()
        boostBlur()
    }

    // The glass sets its filter again as it draws anew: first showing, the window becoming key or not, resizing.
    // Again then (and a moment after, as it draws), and every second while it's up, should something else redo it.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard blurRadius != nil else { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        blurTimer?.invalidate()
        blurTimer = nil
        guard let window else { return }
        let names: [Notification.Name] = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                                          NSWindow.didResizeNotification, NSWindow.didChangeOcclusionStateNotification,
                                          NSWindow.didChangeBackingPropertiesNotification]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.boostBlurSoon() }
            }
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window?.isVisible == true else { return }
                self.boostBlur()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        blurTimer = timer
        boostBlurSoon()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        boostBlurSoon()
    }

    private func boostBlurSoon() {
        boostBlur()
        for delay in [0.05, 0.25] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.boostBlur() }
        }
    }

    /// Liquid Glass has no setting for how much it blurs: its filter (on the backdrop layer it draws what's behind
    /// with) has one. The colour stays the glass's. Should that layer or key change, the glass is as it comes.
    func boostBlur() {
        guard let blurRadius, let root = backdrop.layer else { return }
        func visit(_ layer: CALayer) {
            if layer.filters?.contains(where: { ($0 as AnyObject).value(forKey: "name") as? String == "glassBackground" }) == true {
                let key = "filters.glassBackground.inputBlurRadius"
                if (layer.value(forKeyPath: key) as? NSNumber)?.doubleValue != Double(blurRadius) {
                    layer.setValue(blurRadius, forKeyPath: key)
                }
            }
            for sublayer in layer.sublayers ?? [] { visit(sublayer) }
        }
        visit(root)
    }
}

/// A panel's content: the field row on top, the body under it in a layer of its own. Transitions move only that
/// layer (Core Animation, run by the render server at the display's rate: 120 Hz on ProMotion), so the main thread
/// has nothing to do per frame but step the window.
final class PanelStack: NSView {
    let header: NSView
    /// The body's hosting view, inside a layer-backed wrapper whose layer the transitions animate.
    let body: NSView

    /// The body keeps this width, centered: a window changing width (search turning into the clipboard) uncovers it
    /// from the middle instead of laying it out again on every step. The field row follows the window.
    private let bodyWidth: CGFloat

    init(header: NSView, body content: NSView, width: CGFloat, height: CGFloat) {
        self.header = header
        bodyWidth = width
        let wrapper = NSView()
        wrapper.wantsLayer = true
        // Fading a layer with hundreds of sublayers (the grids' tiles) as a group renders it offscreen every frame;
        // per sublayer, it composites directly (the tiles don't overlap, so it looks the same).
        wrapper.layer?.allowsGroupOpacity = false
        content.frame = wrapper.bounds
        content.autoresizingMask = [.width, .height]
        wrapper.addSubview(content)
        body = wrapper
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        addSubview(wrapper)
        addSubview(header)
        layoutParts()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutParts()
    }

    private func layoutParts() {
        let field = PanelChrome.fieldHeight
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: field)
        body.frame = NSRect(x: ((bounds.width - bodyWidth) / 2).rounded(), y: field, width: bodyWidth,
                            height: max(bounds.height - field, 0))
    }

    // MARK: Transitions

    func setBody(visible: Bool) {
        body.layer?.removeAllAnimations()
        setOpacity(visible ? 1 : 0)
    }

    /// Lays out and draws the (hidden) body now, so that work happens before a transition starts, not during it.
    func prepareBody() {
        body.layoutSubtreeIfNeeded()
        body.displayIfNeeded()
    }

    /// Fades in while settling down from a few points above.
    func revealBody() {
        guard let layer = body.layer else { return }
        layer.removeAllAnimations()
        setOpacity(1)
        // On the window's spring, so the body and the edges uncovering it move as one.
        let fade = Motion.grow.animation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        var animations: [CAAnimation] = [fade]
        if !Motion.reduced {
            let slide = Motion.grow.animation(keyPath: "transform")
            slide.fromValue = CATransform3DMakeTranslation(0, Motion.revealDistance, 0)
            slide.toValue = CATransform3DIdentity
            animations.append(slide)
        }
        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = fade.duration
        group.beginTime = CACurrentMediaTime() + 0.02
        group.fillMode = .backwards
        group.preferredFrameRateRange = Motion.frameRate
        layer.add(group, forKey: "reveal")
    }

    /// Fades out, all of it at once (leaving is quicker than coming). The fade and the opacity it leaves behind go to
    /// the screen together: the opacity alone first (its own transaction, the fade a turn later behind ~30 ms of work)
    /// blanked the body for a couple of frames, then the fade brought it back.
    func fadeOutBody() {
        guard let layer = body.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = Motion.fadeOut
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.preferredFrameRateRange = Motion.frameRate
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAllAnimations()
        layer.opacity = 0
        layer.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    private func setOpacity(_ value: Float) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body.layer?.opacity = value
        CATransaction.commit()
    }
}

/// The one window both panels show in: the clipboard history and search are two modes of it, each a `PanelStack` over
/// the same glass. Switching shows the other's stack while the window changes shape: no second window to bring up
/// (its glass drew a frame late, and lighter until it had the keyboard: a blink), no keyboard to hand from one window
/// to another, nothing for the window server to set up mid-motion (it held the motion two or three frames).
final class PanelHost {
    enum Mode { case clipboard, search }

    let window: PanelWindow
    /// The mode showing, or last shown.
    private(set) var mode: Mode?
    private let holder = NSView()
    private var stacks: [Mode: NSView] = [:]
    /// What a mode does as the other takes the window (its keys, its motion, Quick Look: let go of; the window stays).
    private var leaving: [Mode: () -> Void] = [:]

    /// `height`: the tallest a mode gets (search with nine rows).
    init(height: CGFloat) {
        window = PanelWindow(size: NSSize(width: PanelChrome.width, height: height))
        holder.frame = NSRect(x: 0, y: 0, width: PanelChrome.width, height: height)
        window.contentView = PanelChrome.container(containing: holder, pinnedHeight: height)
    }

    /// A mode's stack, kept at `height` at the top as the window changes (as each panel's own window kept it).
    func add(_ stack: NSView, for mode: Mode, height: CGFloat, leaving: @escaping () -> Void) {
        stack.frame = NSRect(x: 0, y: holder.bounds.height - height, width: holder.bounds.width, height: height)
        stack.autoresizingMask = [.width, .minYMargin]
        stack.isHidden = true
        holder.addSubview(stack)
        stacks[mode] = stack
        self.leaving[mode] = leaving
    }

    /// On screen in this mode.
    func isShowing(_ mode: Mode) -> Bool { window.isVisible && self.mode == mode }

    /// The window in `mode`: its stack shown, the other's hidden, and the other mode told it has left.
    func show(_ mode: Mode) {
        let previous = self.mode
        self.mode = mode
        for (each, stack) in stacks {
            stack.isHidden = each != mode
            stack.alphaValue = 1
        }
        if let previous, previous != mode { leaving[previous]?() }
    }

    /// `mode`'s stack laid out and drawn now, unseen over the one showing, for a switch to it a moment later. (Hidden
    /// until then, it was all drawn at the switch: 10 to 18 ms in that frame.)
    func prepare(_ mode: Mode) {
        guard self.mode != mode, let stack = stacks[mode] else { return }
        stack.alphaValue = 0
        stack.isHidden = false
        stack.layoutSubtreeIfNeeded()
        stack.displayIfNeeded()
    }

    /// A switch that didn't happen: `mode`'s stack hidden again.
    func unprepare(_ mode: Mode) {
        guard self.mode != mode, let stack = stacks[mode] else { return }
        stack.isHidden = true
        stack.alphaValue = 1
    }
}

/// Under a panel's field row: dragging there moves the panel till it closes (switching to the other panel keeps the
/// place, moved in only where the other would leave the screen), snapping to the middle of the screen as it passes,
/// with a tap of the trackpad.
struct PanelDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        /// The drag moves the middle of the field's top edge, the place both modes keep. Mid-motion (results coming
        /// in, a switch to the other mode), from where the window's heading, and the motion moves along.
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            let grabbed = NSEvent.mouseLocation
            let heading = WindowFrameAnimator.moving(window)?.target ?? window.frame
            let start = NSPoint(x: heading.midX, y: heading.maxY)
            var placed = start
            var snapped = false
            while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type != .leftMouseUp {
                let mouse = NSEvent.mouseLocation
                var anchor = NSPoint(x: start.x + mouse.x - grabbed.x, y: start.y + mouse.y - grabbed.y)
                if let area = (window.screen ?? NSScreen.main)?.visibleFrame {
                    let near = abs(anchor.x - area.midX) < PanelChrome.snapDistance
                    if near { anchor.x = area.midX.rounded() }
                    if near, !snapped { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
                    snapped = near
                    anchor.y = min(anchor.y, area.maxY)   // the field stays below the menu bar
                }
                let offset = NSSize(width: anchor.x - placed.x, height: anchor.y - placed.y)
                placed = anchor
                WindowFrameAnimator.moving(window)?.shift(by: offset)
                window.setFrameOrigin(NSPoint(x: window.frame.minX + offset.width, y: window.frame.minY + offset.height))
            }
        }
    }
}
