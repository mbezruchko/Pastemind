import AppKit
import SwiftUI

/// The motion of the panels: search opening into its results, switching between search and the clipboard history.
/// Windows move on springs without bounce (critically damped), the way the system's own panels move: a motion sets off
/// from rest, gathers speed over the first frames and settles softly, and one that's redirected mid-way (results
/// arriving while it grows) carries its speed into the new one. The steep ease-out these used before covered half the
/// distance in the first two frames and then crawled, which read as a jump. With Reduce Motion, nothing moves.
enum Motion {
    /// A window growing: search opening into its results, the clipboard history out of search.
    static let grow = Spring(response: 0.26)
    /// Shrinking: a little quicker than growing.
    static let shrink = Spring(response: 0.22)
    /// Search opening up to its results as you type: quicker than a panel turning into another, as it follows the
    /// keyboard.
    static let results = Spring(response: 0.2)
    /// The body fading out on the way to search.
    static let fadeOut: CFTimeInterval = 0.08
    /// Where the body comes in from: a few points above (the layer is flipped: negative is up).
    static let revealDistance: CGFloat = -8
    static let frameRate = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)

    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// A critically damped spring. `response` is SwiftUI's and Core Animation's: roughly how long the motion takes
/// (ω = 2π / response); it's 90% of the way at about 0.6 × response.
nonisolated struct Spring: Sendable {
    let response: Double

    var omega: Double { 2 * .pi / response }

    /// The same spring for a Core Animation property.
    func animation(keyPath: String) -> CASpringAnimation {
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.mass = 1
        animation.stiffness = omega * omega
        animation.damping = 2 * omega
        animation.duration = animation.settlingDuration
        return animation
    }
}

/// Where a window is and how fast its edges move (points per second: left, top, width, height): for one panel to take
/// over another's motion mid-way and carry it on.
struct WindowMotion {
    let frame: NSRect
    let velocity: [Double]
    /// When it's there: the frame on screen, so the window taking over carries on from it (from where it would be
    /// now instead, it stepped back a few points, held a frame, then made up for it).
    let time: CFTimeInterval
}

/// Moves a window's frame on a spring, on the display's own clock: one step per refresh (120 Hz on ProMotion), each
/// placed at the time its frame will be shown, in whole pixels. With the panels' content pinned, a step is a window
/// resize and the field row's layout, nothing more.
final class WindowFrameAnimator: NSObject {
    /// One edge or size: x(t) = target + (c1 + c2·t)·e^(−ωt), the critically damped spring's motion from any position
    /// and speed.
    private struct Channel {
        var target: Double
        var c1: Double
        var c2: Double

        func offset(_ t: Double, _ decay: Double) -> Double { (c1 + c2 * t) * decay }
        func velocity(_ t: Double, _ decay: Double, _ omega: Double) -> Double {
            (c2 - omega * (c1 + c2 * t)) * decay
        }
    }

    private weak var window: NSWindow?
    private var link: CADisplayLink?
    private var channels: [Channel] = []
    private var omega = Motion.grow.omega
    private var start: CFTimeInterval = 0
    /// Setting off from rest, the motion starts with the first frame it shows, not when it's asked for: what holds the
    /// main thread until then (a window's first layout and draw, ~20 to 40 ms) had it set off a sixth of the way in,
    /// at full speed, a lurch.
    private var startsOnFirstStep = false
    private var from = NSRect.zero
    private var to = NSRect.zero
    /// Called once the window is within a point of where it's going (a spring's last pixel takes a while: what
    /// follows needn't wait for it).
    private var completion: () -> Void = {}
    private var steps = 0
    /// When the last step's frame went on screen.
    private var shown: CFTimeInterval = 0
    private var stepCost: CFTimeInterval = 0
    private var stamps: [CFTimeInterval] = []

    var isRunning: Bool { link != nil }
    /// Where it's heading, while it runs.
    var target: NSRect? { isRunning ? to : nil }

    /// The window's frame and speed as shown: mid-motion, or at rest.
    func motion(of window: NSWindow) -> WindowMotion {
        let now = CACurrentMediaTime()
        guard isRunning, self.window === window else {
            return WindowMotion(frame: window.frame, velocity: [0, 0, 0, 0], time: now)
        }
        let time = steps > 0 ? shown : now
        let t = elapsed(at: time)
        let decay = exp(-omega * t)
        let position = channels.map { $0.target + $0.offset(t, decay) }
        return WindowMotion(frame: NSRect(x: position[0], y: position[1] - position[3], width: position[2],
                                          height: position[3]),
                            velocity: channels.map { $0.velocity(t, decay, omega) }, time: time)
    }

    /// `motion`: where it starts and how fast, when this window takes over another's motion.
    func run(_ window: NSWindow, to frame: NSRect, spring: Spring, from motion: WindowMotion? = nil,
             completion: @escaping () -> Void = {}) {
        // From where the window is, at the speed it's moving (still, unless this redirects a motion under way).
        let now = CACurrentMediaTime()
        var origin = now
        var positions = Self.channels(of: motion?.frame ?? window.frame)
        var velocities = motion?.velocity ?? [Double](repeating: 0, count: 4)
        if motion == nil, isRunning, self.window === window {
            let t = elapsed(at: now)
            let decay = exp(-omega * t)
            for index in channels.indices {
                positions[index] = channels[index].target + channels[index].offset(t, decay)
                velocities[index] = channels[index].velocity(t, decay, omega)
            }
        } else {
            // Taking over another window's motion, it carries on from that one's last frame.
            startsOnFirstStep = motion == nil
            origin = motion?.time ?? now
            from = window.frame
            steps = 0
            stepCost = 0
            stamps = []
        }
        link?.invalidate()
        self.window = window
        to = frame
        omega = spring.omega
        self.completion = completion
        channels = zip(Self.channels(of: frame), zip(positions, velocities)).map { target, state in
            let c1 = state.0 - target
            return Channel(target: target, c1: c1, c2: state.1 + spring.omega * c1)
        }
        start = origin
        let link = window.displayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = Motion.frameRate
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// A new destination mid-way (results arrived while it grows): the motion bends toward it at the speed it has.
    func retarget(to frame: NSRect, spring: Spring) {
        guard let window, isRunning else { return }
        run(window, to: frame, spring: spring, completion: completion)
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    /// How far into the motion `now` is: not under way before its first frame.
    private func elapsed(at now: CFTimeInterval) -> Double {
        startsOnFirstStep ? 0 : max(now - start, 0)
    }

    /// The left edge, the top edge (the field stays put), the width and the height.
    private static func channels(of frame: NSRect) -> [Double] {
        [frame.minX, frame.maxY, frame.width, frame.height]
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let window else { return stop() }
        if DebugHooks.enabled { stamps.append(CACurrentMediaTime()) }
        if startsOnFirstStep {   // a frame's worth of motion in this first frame
            startsOnFirstStep = false
            start = link.timestamp
        }
        let t = max(link.targetTimestamp - start, 0)
        let decay = exp(-omega * t)
        let scale = window.backingScaleFactor
        // Settled: under a quarter of a pixel from the target, and all but still.
        let settled = channels.allSatisfy {
            abs($0.offset(t, decay)) * scale < 0.25 && abs($0.velocity(t, decay, omega)) < 4
        }
        let arrived = channels.allSatisfy { abs($0.offset(t, decay)) < 1 }
        let began = CACurrentMediaTime()
        if settled {
            stop()
            window.setFrame(to, display: true)
            PanelChrome.refreshShadow(of: window)
        } else {
            let value = channels.map { pixel($0.target + $0.offset(t, decay), scale) }
            let frame = NSRect(x: value[0], y: value[1] - value[3], width: value[2], height: value[3])
            // display: false, then only what needs it now (the field row, when the width changes), so the content
            // moves with the window's edges in the same frame. The shadow follows the shape as it goes.
            window.setFrame(frame, display: false)
            window.displayIfNeeded()
            window.invalidateShadow()
        }
        stepCost += CACurrentMediaTime() - began
        steps += 1
        shown = link.targetTimestamp
        if arrived {
            let completion = self.completion
            self.completion = {}
            completion()
        }
        guard settled else { return }
        if DebugHooks.enabled {
            let elapsed = (link.targetTimestamp - stamps.first!) * 1000
            log(String(format: "motion: %.0f×%.0f→%.0f×%.0f pt, %d frames in %.0f ms (%.1f ms apart), step %.2f ms",
                       from.width, from.height, to.width, to.height, steps, elapsed, elapsed / Double(max(steps - 1, 1)),
                       stepCost * 1000 / Double(steps)))
            let gaps = zip(stamps.dropFirst(), stamps).map { Int((($0 - $1) * 1000).rounded()) }
            log("motion gaps (ms): \(gaps.map(String.init).joined(separator: " "))")
        }
    }

    private func pixel(_ value: Double, _ scale: CGFloat) -> CGFloat {
        (CGFloat(value) * scale).rounded() / scale
    }
}
