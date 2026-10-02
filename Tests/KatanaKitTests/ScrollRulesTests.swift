import Testing

@testable import KatanaKit

private typealias Rules = ScrollRules<String>

// GAIN with 100 steps over Tanto's 200-point drag, and AMP TYPE with its five positions. Scrolling takes at least six
// points per step, as in Tone Studio.
private let gain = (control: "GAIN", stepPoints: 2.0)
private let ampType = (control: "AMP TYPE", stepPoints: 50.0)

private func wheel(_ notches: Double, at time: Double) -> Rules.Event {
    Rules.Event(delta: notches, isPrecise: false, phase: .none, isMomentum: false, time: time)
}

private func trackpad(_ points: Double, _ phase: Rules.Phase, at time: Double) -> Rules.Event {
    Rules.Event(delta: points, isPrecise: true, phase: phase, isMomentum: false, time: time)
}

private func momentum(_ points: Double, at time: Double) -> Rules.Event {
    Rules.Event(delta: points, isPrecise: true, phase: .none, isMomentum: true, time: time)
}

@Test func aWheelNotchTurnsAKnobOneStepWhateverItsSize() {
    var rules = Rules()
    #expect(rules.handle(wheel(1, at: 10), over: gain) == .turns("GAIN", by: 1))
    #expect(rules.handle(wheel(-6, at: 10.1), over: gain) == .turns("GAIN", by: -1))
    #expect(rules.handle(wheel(3, at: 10.2), over: ampType) == .turns("AMP TYPE", by: 1))
}

@Test func aWheelOverThePageScrollsItAndKeepsScrollingItPastAKnob() {
    var rules = Rules()
    #expect(rules.handle(wheel(-1, at: 10), over: nil) == .scrollsPage)
    #expect(rules.handle(wheel(-1, at: 10.3), over: gain) == .scrollsPage)
    #expect(rules.handle(wheel(-1, at: 10.7), over: gain) == .scrollsPage)
    // Half a second after the page's last scroll, the wheel turns the knob.
    #expect(rules.handle(wheel(-1, at: 11.3), over: gain) == .turns("GAIN", by: -1))
}

@Test func aTrackpadTurnsOneStepPerSixPointsOrADragsDistanceWhereThatIsMore() {
    var rules = Rules()
    #expect(rules.handle(trackpad(3, .began, at: 10), over: gain) == .turns("GAIN", by: 0))
    #expect(rules.handle(trackpad(5, .changed, at: 10.02), over: gain) == .turns("GAIN", by: 1))
    #expect(rules.handle(trackpad(3, .changed, at: 10.04), over: gain) == .turns("GAIN", by: 0))
    // A change of direction starts the count again: the five points up do not hold back the way down.
    #expect(rules.handle(trackpad(-2, .changed, at: 10.06), over: gain) == .turns("GAIN", by: 0))
    #expect(rules.handle(trackpad(-5, .changed, at: 10.08), over: gain) == .turns("GAIN", by: -1))
    #expect(rules.handle(trackpad(0, .ended, at: 10.1), over: gain) == .isSwallowed)
    #expect(rules.handle(trackpad(30, .began, at: 11), over: ampType) == .turns("AMP TYPE", by: 0))
    #expect(rules.handle(trackpad(30, .changed, at: 11.02), over: ampType) == .turns("AMP TYPE", by: 1))
}

@Test func momentumAfterTheFingersLiftTurnsNothing() {
    var rules = Rules()
    _ = rules.handle(trackpad(10, .began, at: 10), over: gain)
    _ = rules.handle(trackpad(0, .ended, at: 10.05), over: gain)
    #expect(rules.handle(momentum(40, at: 10.07), over: gain) == .isSwallowed)
    #expect(rules.handle(momentum(20, at: 10.3), over: nil) == .isSwallowed)
}

@Test func aTrackpadScrollThatBeganOverThePageStaysWithThePage() {
    var rules = Rules()
    #expect(rules.handle(trackpad(-10, .began, at: 10), over: nil) == .scrollsPage)
    #expect(rules.handle(trackpad(-10, .changed, at: 10.02), over: gain) == .scrollsPage)
    #expect(rules.handle(trackpad(0, .ended, at: 10.04), over: gain) == .scrollsPage)
    #expect(rules.handle(momentum(-40, at: 10.06), over: gain) == .scrollsPage)
    // So does the next swipe right after the page moved; after a pause, a swipe turns the knob.
    #expect(rules.handle(trackpad(-10, .began, at: 10.4), over: gain) == .scrollsPage)
    #expect(rules.handle(trackpad(0, .ended, at: 10.5), over: gain) == .scrollsPage)
    #expect(rules.handle(trackpad(-7, .began, at: 11.1), over: gain) == .turns("GAIN", by: -1))
}

@Test func aTrackpadScrollThatBeganOverAKnobStaysWithThatKnob() {
    var rules = Rules()
    _ = rules.handle(trackpad(2, .began, at: 10), over: gain)
    #expect(rules.handle(trackpad(4, .changed, at: 10.02), over: nil) == .turns("GAIN", by: 1))
    #expect(rules.handle(trackpad(100, .changed, at: 10.04), over: ampType) == .turns("GAIN", by: 16))
}

@Test func aSmoothScrollingMouseAddsUpLikeATrackpad() {
    var rules = Rules()
    let smooth = { (points: Double, time: Double) in
        Rules.Event(delta: points, isPrecise: true, phase: .none, isMomentum: false, time: time)
    }
    #expect(rules.handle(smooth(4, 10), over: gain) == .turns("GAIN", by: 0))
    #expect(rules.handle(smooth(4, 10.01), over: gain) == .turns("GAIN", by: 1))
    // Another control starts from nothing.
    #expect(rules.handle(smooth(40, 10.02), over: ampType) == .turns("AMP TYPE", by: 0))
}
