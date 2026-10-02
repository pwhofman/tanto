/// What scrolling does over Tanto's knobs and sliders (design spec, section 6). As in Tone Studio, a scroll over a
/// control turns it instead of scrolling the page, a mouse wheel turns it one step per notch, and a trackpad or a
/// smooth-scrolling mouse one step per `minimumStepPoints` of scrolling; a change of direction starts the count again.
/// A knob with few positions needs as many points per step as a drag. Three rules go further than Tone Studio's: the
/// momentum after the fingers lift turns nothing, a trackpad scroll that began over the page stays with the page, and a
/// scroll that begins within `pageHold` of the page's last one scrolls the page too.
///
/// The app passes every scroll event with the control under the pointer and does what the outcome says.
public struct ScrollRules<Control: Hashable> {
    /// Where a trackpad scroll stands. A mouse wheel's events and the momentum have no phase.
    public enum Phase: Sendable {
        case none
        case began
        case changed
        case ended
    }

    /// A scroll event.
    public struct Event: Sendable {
        /// How far the fingers or the wheel moved, up if positive, whatever the natural-scrolling setting: points if
        /// `isPrecise`, notches otherwise.
        public var delta: Double
        /// Whether `delta` is in points, as from a trackpad or a Magic Mouse.
        public var isPrecise: Bool
        public var phase: Phase
        /// Whether the event belongs to the momentum after the fingers lifted.
        public var isMomentum: Bool
        /// When the event happened, in seconds.
        public var time: Double

        /// Creates an event.
        public init(delta: Double, isPrecise: Bool, phase: Phase, isMomentum: Bool, time: Double) {
            self.delta = delta
            self.isPrecise = isPrecise
            self.phase = phase
            self.isMomentum = isMomentum
            self.time = time
        }
    }

    /// What an event does.
    public enum Outcome: Equatable {
        /// The page scrolls.
        case scrollsPage
        /// Nothing happens.
        case isSwallowed
        /// The control turns by this many steps, up if positive; 0 while a trackpad's movement adds up to a step.
        case turns(Control, by: Int)
    }

    /// How long after the page's last scroll event a scroll over a control still scrolls the page, in seconds.
    public static var pageHold: Double { 0.5 }
    /// The fewest points of scrolling per step, as in Tone Studio. macOS speeds up scrolling, so a trackpad's points are
    /// more than the fingers' travel, and a drag's distance per step turned knobs too fast (the user's test).
    public static var minimumStepPoints: Double { 6 }

    // A control that a trackpad scroll or a smooth-scrolling mouse turns, and the points towards its next step.
    private struct Turning {
        let control: Control
        let stepPoints: Double
        var points = 0.0

        init(control: Control, stepPoints: Double) {
            self.control = control
            self.stepPoints = max(stepPoints, ScrollRules.minimumStepPoints)
        }
    }

    private var turning: Turning?
    private var lastPageScroll: Double?

    /// Creates the rules, with no scroll going on.
    public init() {}

    /// Decides what an event does.
    ///
    /// - Parameters:
    ///   - event: The event.
    ///   - target: The enabled control under the pointer, if any, and how many points of a drag turn it one step.
    /// - Returns: What the event does.
    public mutating func handle(_ event: Event, over target: (control: Control, stepPoints: Double)?) -> Outcome {
        // The momentum belongs to the scroll before it: the page's scrolls the page, a control's does nothing.
        if event.isMomentum {
            return turning == nil ? scrollPage(at: event.time) : .isSwallowed
        }
        switch event.phase {
        case .began:
            guard let target, !pageScrolled(before: event.time) else {
                turning = nil
                return scrollPage(at: event.time)
            }
            return turn(Turning(control: target.control, stepPoints: target.stepPoints), by: event.delta)
        case .changed:
            guard let turning else { return scrollPage(at: event.time) }
            return turn(turning, by: event.delta)
        case .ended:
            return turning == nil ? scrollPage(at: event.time) : .isSwallowed
        case .none:
            guard let target, !pageScrolled(before: event.time) else { return scrollPage(at: event.time) }
            guard event.isPrecise else {
                // One step per notch, however fast the wheel spins, as in Tone Studio.
                return .turns(target.control, by: event.delta > 0 ? 1 : event.delta < 0 ? -1 : 0)
            }
            if let turning, turning.control == target.control {
                return turn(turning, by: event.delta)
            }
            return turn(Turning(control: target.control, stepPoints: target.stepPoints), by: event.delta)
        }
    }

    private func pageScrolled(before time: Double) -> Bool {
        lastPageScroll.map { time - $0 < Self.pageHold } ?? false
    }

    private mutating func scrollPage(at time: Double) -> Outcome {
        lastPageScroll = time
        return .scrollsPage
    }

    private mutating func turn(_ start: Turning, by delta: Double) -> Outcome {
        var turning = start
        if delta * turning.points < 0 {
            turning.points = 0
        }
        turning.points += delta
        let steps = Int(turning.points / turning.stepPoints)
        turning.points -= Double(steps) * turning.stepPoints
        self.turning = turning
        return .turns(turning.control, by: steps)
    }
}
