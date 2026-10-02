import AppKit
import KatanaKit
import SwiftUI

extension View {
    /// Lets scrolling over this control turn it, by `ScrollRules`.
    ///
    /// - Parameters:
    ///   - stepPoints: How many points of a drag turn the control one step.
    ///   - turn: Turns the control by a number of steps, up if positive.
    /// - Returns: The control.
    func turnsWhenScrolled(stepPoints: Double, turn: @escaping @MainActor (Int) -> Void) -> some View {
        background(ScrollTarget(stepPoints: stepPoints, turn: turn))
    }
}

/// An invisible view behind a knob or slider that tells `ScrollRouter` where the control is.
private struct ScrollTarget: NSViewRepresentable {
    let stepPoints: Double
    let turn: @MainActor (Int) -> Void

    func makeNSView(context: Context) -> ScrollTargetView {
        ScrollTargetView()
    }

    func updateNSView(_ view: ScrollTargetView, context: Context) {
        view.stepPoints = stepPoints
        view.turn = turn
        view.isEnabled = context.environment.isEnabled
    }
}

/// The AppKit side of `ScrollTarget`.
final class ScrollTargetView: NSView {
    var stepPoints = 1.0
    var turn: @MainActor (Int) -> Void = { _ in }
    var isEnabled = true
    /// The view's number at `ScrollRouter` while it is in a window.
    fileprivate var id: Int?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            ScrollRouter.shared.remove(self)
        } else {
            ScrollRouter.shared.add(self)
        }
    }

    // Clicks and drags go to the control in front.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

/// Turns the knobs and sliders that scrolling reaches by `ScrollRules`; all other scrolling goes on as usual. A local
/// event monitor sees every scroll before AppKit dispatches it and keeps the ones that turn a control.
@MainActor
final class ScrollRouter {
    static let shared = ScrollRouter()

    private struct Target {
        weak var view: ScrollTargetView?
    }

    private var rules = ScrollRules<Int>()
    private var targets: [Int: Target] = [:]
    private var nextID = 0
    private var monitor: Any?

    func add(_ view: ScrollTargetView) {
        remove(view)
        view.id = nextID
        targets[nextID] = Target(view: view)
        nextID += 1
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                ScrollRouter.shared.keeps(Self.scroll(event), in: event.window, at: event.locationInWindow)
                    ? nil : event
            }
        }
    }

    func remove(_ view: ScrollTargetView) {
        if let id = view.id {
            targets[id] = nil
            view.id = nil
        }
    }

    /// Lets a scroll turn the control under the pointer, as `ScrollRules` decides.
    ///
    /// - Parameters:
    ///   - scroll: The scroll event.
    ///   - window: The window it happened in.
    ///   - location: Where, in the window's coordinates.
    /// - Returns: Whether the page must not get the scroll.
    func keeps(_ scroll: ScrollRules<Int>.Event, in window: NSWindow?, at location: NSPoint) -> Bool {
        let target = control(at: location, in: window)
        switch rules.handle(scroll, over: target.map { ($0.id, $0.view.stepPoints) }) {
        case .scrollsPage:
            return false
        case .isSwallowed:
            return true
        case .turns(let id, let steps):
            if steps != 0, let view = targets[id]?.view {
                view.turn(steps)
            }
            return true
        }
    }

    // The enabled control under the pointer, unless the toolbar covers it there or a scroll view clips it. Views do not
    // clip to their own bounds, so their visible rectangle can reach past them.
    private func control(at location: NSPoint, in window: NSWindow?) -> (id: Int, view: ScrollTargetView)? {
        guard let window, window.contentLayoutRect.contains(location) else { return nil }
        for (id, target) in targets {
            guard let view = target.view, view.window === window, view.isEnabled else { continue }
            let point = view.convert(location, from: nil)
            if view.bounds.contains(point), view.visibleRect.contains(point) {
                return (id, view)
            }
        }
        return nil
    }

    // Natural scrolling inverts the deltas; a control follows the fingers or the wheel.
    private static func scroll(_ event: NSEvent) -> ScrollRules<Int>.Event {
        let phase: ScrollRules<Int>.Phase =
            if !event.phase.isDisjoint(with: [.began, .mayBegin]) {
                .began
            } else if !event.phase.isDisjoint(with: [.ended, .cancelled]) {
                .ended
            } else if event.phase.isEmpty {
                .none
            } else {
                .changed
            }
        return ScrollRules.Event(
            delta: event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY,
            isPrecise: event.hasPreciseScrollingDeltas, phase: phase, isMomentum: !event.momentumPhase.isEmpty,
            time: event.timestamp)
    }
}
