import KatanaKit
import SwiftUI

/// One parameter: a slider, a switch or a pop-up menu, with the refusal of `SafetyGuard` underneath.
struct ParameterRow: View {
    let model: EditorModel
    let parameter: Parameter

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch parameter.kind {
            case .numeric:
                NumericControl(model: model, parameter: parameter)
            case .toggle:
                ToggleControl(model: model, parameter: parameter)
            case .picker:
                PickerControl(model: model, parameter: parameter)
            case .text:
                EmptyView()
            }
            if let refusal = model.refusals[parameter.offset] {
                Text(refusal).font(.caption).foregroundStyle(.red).padding(.leading, 178)
            }
        }
    }
}

private struct NumericControl: View {
    let model: EditorModel
    let parameter: Parameter
    @State private var dragged: Double?
    // The Panic count when the drag began; a drag that Panic interrupted sends nothing more (design spec, 5.1).
    @State private var dragPanics: Int?

    var body: some View {
        let value = model.value(of: parameter) ?? parameter.minimum
        let ceiling = model.ceiling(of: parameter)
        // A guarded slider ends at the higher of its ceiling and its current value (design spec, section 6).
        let upper = max(ceiling.map { max($0, value) } ?? parameter.maximum, parameter.minimum + 1)
        let interrupted = dragPanics.map { $0 != model.panicCount } ?? false
        HStack {
            Text(ceiling.map { "\(parameter.label) (max \(parameter.displayText(for: $0)))" } ?? parameter.label)
                .frame(width: 170, alignment: .leading)
            Slider(
                value: Binding(
                    get: { interrupted ? Double(value) : dragged ?? Double(value) },
                    set: { new in
                        dragged = new
                        guard !interrupted else { return }
                        Task { await model.set(parameter, to: Int(new.rounded())) }
                    }),
                in: Double(parameter.minimum)...Double(upper),
                step: 1,
                onEditingChanged: { editing in
                    if editing {
                        dragPanics = model.panicCount
                    } else {
                        dragged = nil
                        dragPanics = nil
                    }
                }
            )
            .frame(maxWidth: 320)
            Text(parameter.displayText(for: value))
                .monospacedDigit()
                .foregroundStyle(ceiling.map { value > $0 } == true ? .orange : .primary)
                .frame(width: 80, alignment: .trailing)
        }
    }
}

private struct ToggleControl: View {
    let model: EditorModel
    let parameter: Parameter

    var body: some View {
        let value = model.value(of: parameter) ?? parameter.minimum
        let binding = Binding(
            get: { value },
            set: { new in Task { await model.set(parameter, to: new) } })
        HStack {
            Text(parameter.label).frame(width: 170, alignment: .leading)
            if let labels = parameter.valueLabels, labels != ["OFF", "ON"] {
                Picker(parameter.label, selection: binding) {
                    ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                        Text(label).tag(parameter.minimum + index)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 200)
            } else {
                Toggle(
                    parameter.label,
                    isOn: Binding(
                        get: { value == parameter.maximum },
                        set: { binding.wrappedValue = $0 ? parameter.maximum : parameter.minimum })
                )
                .labelsHidden()
                .toggleStyle(.switch)
            }
        }
    }
}

private struct PickerControl: View {
    let model: EditorModel
    let parameter: Parameter

    var body: some View {
        let value = model.value(of: parameter) ?? parameter.minimum
        let choices =
            parameter.options?.map { ($0.value, $0.label) }
            ?? (parameter.minimum...parameter.maximum).map { ($0, parameter.displayText(for: $0)) }
        HStack {
            Text(parameter.label).frame(width: 170, alignment: .leading)
            Picker(
                parameter.label,
                selection: Binding(
                    get: { value },
                    set: { new in Task { await model.set(parameter, to: new) } })
            ) {
                ForEach(choices, id: \.0) { choice in
                    Text(choice.1).tag(choice.0)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 220)
        }
    }
}

/// A front-panel button: pressing it does what the amp's own button does, and the window shows what the amp reports.
struct PanelButtonRow: View {
    let model: EditorModel
    let button: PanelButton

    var body: some View {
        let state = model.led(of: button).flatMap { model.value(of: $0) } ?? 0
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(button.label).frame(width: 170, alignment: .leading)
                Button {
                    Task { await model.press(button) }
                } label: {
                    Label(Self.text(button, state), systemImage: state > 0 ? "circle.fill" : "circle")
                        .foregroundStyle(Self.colour(button, state))
                }
                .help(button == .variation ? "Press VARIATION" : "Next colour, as the button on the amp")
            }
            if let refusal = model.buttonRefusals[button] {
                Text(refusal).font(.caption).foregroundStyle(.red).padding(.leading, 178)
            }
        }
    }

    // The LED: off, or for a colour button GREEN, RED or YELLOW.
    private static func text(_ button: PanelButton, _ state: Int) -> String {
        if button == .variation {
            return state > 0 ? "ON" : "OFF"
        }
        return ["OFF", "GREEN", "RED", "YELLOW"][min(max(state, 0), 3)]
    }

    private static func colour(_ button: PanelButton, _ state: Int) -> Color {
        if button == .variation {
            return state > 0 ? .orange : .secondary
        }
        return [.secondary, .green, .red, .yellow][min(max(state, 0), 3)]
    }
}
