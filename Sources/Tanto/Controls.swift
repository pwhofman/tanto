import AppKit
import KatanaKit
import SwiftUI

/// One parameter, drawn as Tone Studio draws it but with macOS's own controls: a knob, a slider, a switch, a pop-up menu
/// or a segmented control. Every change goes through `EditorModel`, so through `SafetyGuard`; a refusal shows below.
struct ControlView: View {
    let model: EditorModel
    let parameter: Parameter

    var body: some View {
        VStack(spacing: 3) {
            switch parameter.control {
            case .knob, nil:
                KnobView(model: model, parameter: parameter, vertical: false)
            case .slider:
                KnobView(model: model, parameter: parameter, vertical: true)
            case .switch:
                SwitchView(model: model, parameter: parameter)
            case .menu:
                MenuView(model: model, parameter: parameter, segmented: false)
            case .segmented:
                MenuView(model: model, parameter: parameter, segmented: true)
            }
            if let refusal = model.refusals[parameter.offset] {
                Text(refusal).font(.caption2).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
        .frame(minWidth: 84)
    }
}

/// A knob, or for the graphic EQs a vertical slider, with its value and label below. A guarded control stops at the
/// higher of its ceiling and its current value (design spec, section 6), and a drag that Panic interrupted sends
/// nothing more. A knob with positions, such as AMP TYPE, sends its choice when the drag ends.
private struct KnobView: View {
    let model: EditorModel
    let parameter: Parameter
    let vertical: Bool
    @State private var dragged: Int?
    @State private var dragPanics: Int?

    var body: some View {
        let value = model.value(of: parameter) ?? parameter.minimum
        let ceiling = model.ceiling(of: parameter)
        let stop = ceiling.map { max($0, value) } ?? parameter.maximum
        let interrupted = dragPanics.map { $0 != model.panicCount } ?? false
        let shown = interrupted ? value : dragged ?? value
        let positions = parameter.kind == .numeric ? nil : parameter.maximum - parameter.minimum + 1
        let onChange = { (new: Int) in
            dragged = new
            if positions == nil, !interrupted {
                Task { await model.set(parameter, to: new) }
            }
        }
        let onTracking = { (tracking: Bool) in
            if tracking {
                dragPanics = model.panicCount
            } else {
                if positions != nil, let dragged, !interrupted, dragged != value {
                    Task { await model.set(parameter, to: dragged) }
                }
                dragged = nil
                dragPanics = nil
            }
        }
        VStack(spacing: 2) {
            if vertical {
                VerticalSlider(
                    value: shown, range: parameter.minimum...parameter.maximum, stop: stop, onChange: onChange,
                    onTracking: onTracking
                )
                .frame(width: 24, height: 120)
            } else {
                Dial(
                    value: shown, range: parameter.minimum...parameter.maximum, stop: stop, ceiling: ceiling,
                    positions: positions, label: parameter.label, valueText: parameter.displayText(for: shown),
                    onChange: onChange, onTracking: onTracking)
            }
            Text(parameter.displayText(for: shown))
                .font(.callout).monospacedDigit()
                .foregroundStyle(ceiling.map { shown > $0 } == true ? .orange : .primary)
            Text(parameter.label).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let ceiling {
                Text("max \(parameter.displayText(for: ceiling))").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

/// A rotary knob drawn the way Apple's music apps draw theirs. It turns from 7 to 5 o'clock like the amp's knobs, shows
/// its value as an arc in the accent colour (from the middle for values around 0), marks the ceiling, and never turns
/// past `stop`. Dragging up turns it up.
private struct Dial: View {
    let value: Int
    let range: ClosedRange<Int>
    let stop: Int
    let ceiling: Int?
    let positions: Int?
    let label: String
    let valueText: String
    let onChange: (Int) -> Void
    let onTracking: (Bool) -> Void
    @State private var dragStart: Int?
    @Environment(\.isEnabled) private var isEnabled

    // Dragging this far turns the knob through its whole travel.
    private static let travel = 200.0

    var body: some View {
        let origin = range.contains(0) && range.lowerBound < 0 ? 0 : range.lowerBound
        let tint: Color = ceiling.map { value > $0 } == true ? .orange : .accentColor
        ZStack {
            Arc(from: angle(range.lowerBound), to: angle(range.upperBound))
                .stroke(.quaternary, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            // A knob with positions selects; only an amount gets an arc.
            if positions == nil {
                Arc(from: angle(min(origin, value)), to: angle(max(origin, value)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
            if let positions {
                ForEach(0..<positions, id: \.self) { index in
                    Circle().fill(.secondary).frame(width: 3, height: 3)
                        .offset(y: -26).rotationEffect(angle(range.lowerBound + index))
                }
            }
            if let ceiling, ceiling < range.upperBound {
                Capsule().fill(.orange).frame(width: 2, height: 7).offset(y: -22).rotationEffect(angle(ceiling))
            }
            Circle()
                .fill(Color(nsColor: .controlColor))
                .overlay(Circle().strokeBorder(.separator))
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                .frame(width: 30, height: 30)
            Capsule().fill(.primary).frame(width: 2.5, height: 9).offset(y: -8).rotationEffect(angle(value))
        }
        .frame(width: 48, height: 48)
        .opacity(isEnabled ? 1 : 0.5)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    if dragStart == nil {
                        dragStart = value
                        onTracking(true)
                    }
                    let span = Double(range.upperBound - range.lowerBound)
                    let turned = Double(dragStart ?? value) - drag.translation.height / Self.travel * span
                    let new = min(max(Int(turned.rounded()), range.lowerBound), stop)
                    if new != value {
                        onChange(new)
                    }
                }
                .onEnded { _ in
                    dragStart = nil
                    onTracking(false)
                }
        )
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(valueText)
        .accessibilityAdjustableAction { direction in
            let new = direction == .increment ? min(value + 1, stop) : max(value - 1, range.lowerBound)
            onTracking(true)
            onChange(new)
            onTracking(false)
        }
    }

    // The knob's angle for a value: −150° (7 o'clock) to 150° (5 o'clock), 0° being 12 o'clock.
    private func angle(_ value: Int) -> Angle {
        let span = Double(max(range.upperBound - range.lowerBound, 1))
        return .degrees(-150 + 300 * Double(value - range.lowerBound) / span)
    }
}

/// A circular arc between two knob angles, 0° being 12 o'clock and angles growing clockwise.
private struct Arc: Shape {
    var from: Angle
    var to: Angle

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // SwiftUI's arcs start at 3 o'clock; `clockwise: false` runs clockwise on screen.
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY), radius: min(rect.width, rect.height) / 2 - 2,
            startAngle: from - .degrees(90), endAngle: to - .degrees(90), clockwise: false)
        return path
    }
}

/// An on/off switch with its label below.
private struct SwitchView: View {
    let model: EditorModel
    let parameter: Parameter

    var body: some View {
        let value = model.value(of: parameter) ?? parameter.minimum
        VStack(spacing: 4) {
            Toggle(
                parameter.label,
                isOn: Binding(
                    get: { value == parameter.maximum },
                    set: { on in Task { await model.set(parameter, to: on ? parameter.maximum : parameter.minimum) } })
            )
            .toggleStyle(.switch)
            .labelsHidden()
            Text(parameter.label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A pop-up menu, or a segmented control, with its label below.
private struct MenuView: View {
    let model: EditorModel
    let parameter: Parameter
    let segmented: Bool

    var body: some View {
        let value = model.value(of: parameter) ?? parameter.minimum
        let choices =
            parameter.options?.map { ($0.value, $0.label) }
            ?? (parameter.minimum...parameter.maximum).map { ($0, parameter.displayText(for: $0)) }
        let picker = Picker(
            parameter.label,
            selection: Binding(get: { value }, set: { new in Task { await model.set(parameter, to: new) } })
        ) {
            ForEach(choices, id: \.0) { choice in
                Text(choice.1).tag(choice.0)
            }
        }
        .labelsHidden()
        VStack(spacing: 4) {
            if segmented {
                picker.pickerStyle(.segmented).fixedSize()
            } else {
                picker.pickerStyle(.menu).fixedSize()
            }
            Text(parameter.label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// AppKit's vertical slider, for the graphic EQs. It never moves past `stop`, and reports when a drag starts and ends.
private struct VerticalSlider: NSViewRepresentable {
    var value: Int
    var range: ClosedRange<Int>
    var stop: Int
    var onChange: (Int) -> Void
    var onTracking: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingSlider {
        let slider = TrackingSlider()
        slider.isVertical = true
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.onTracking = { [coordinator = context.coordinator] in coordinator.parent.onTracking($0) }
        return slider
    }

    func updateNSView(_ slider: TrackingSlider, context: Context) {
        context.coordinator.parent = self
        slider.minValue = Double(range.lowerBound)
        slider.maxValue = Double(range.upperBound)
        if !slider.isTracking {
            slider.integerValue = value
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: VerticalSlider

        init(_ parent: VerticalSlider) {
            self.parent = parent
        }

        @objc func changed(_ slider: NSSlider) {
            var new = Int(slider.doubleValue.rounded())
            if new > parent.stop {
                new = parent.stop
                slider.integerValue = new
            }
            parent.onChange(new)
        }
    }
}

/// An `NSSlider` that says when the mouse takes hold of it and lets go.
private final class TrackingSlider: NSSlider {
    var onTracking: ((Bool) -> Void)?
    private(set) var isTracking = false

    override func mouseDown(with event: NSEvent) {
        isTracking = true
        onTracking?(true)
        // Returns once the mouse goes up.
        super.mouseDown(with: event)
        isTracking = false
        onTracking?(false)
    }
}
