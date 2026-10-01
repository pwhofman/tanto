import KatanaKit
import SwiftUI

/// The amp's front panel as BOSS TONE STUDIO lays it out: AMPLIFIER, EQUALIZER and EFFECTS, then CAB RESONANCE with
/// PRESENCE, SOLO and CONTOUR. Buttons, switches and menus sit in a row above the knobs, and the groups wrap when the
/// window is narrow.
struct FrontPanel: View {
    let model: EditorModel

    /// A control on the panel.
    private enum Cell {
        case button(PanelButton)
        /// The panel control of the parameter with this Tone Studio id.
        case parameter(String)
        case contour
    }

    // Each group's columns as Tone Studio has them: the control in the upper row, then the one below it.
    private static let groups: [(title: String, columns: [(upper: Cell?, lower: Cell)])] = [
        (
            "Amplifier",
            [
                (.button(.variation), .parameter("PRM_KNOB_POS_TYPE")), (nil, .parameter("PRM_KNOB_POS_GAIN")),
                (nil, .parameter("PRM_KNOB_POS_VOLUME")),
            ]
        ),
        (
            "Equalizer",
            [
                (nil, .parameter("PRM_KNOB_POS_BASS")), (nil, .parameter("PRM_KNOB_POS_MIDDLE")),
                (nil, .parameter("PRM_KNOB_POS_TREBLE")),
            ]
        ),
        (
            "Effects",
            [
                (.button(.booster), .parameter("PRM_KNOB_POS_BOOST")), (.button(.mod), .parameter("PRM_KNOB_POS_MOD")),
                (.button(.fx), .parameter("PRM_KNOB_POS_FX")), (.button(.delay), .parameter("PRM_KNOB_POS_DELAY")),
                (.button(.reverb), .parameter("PRM_KNOB_POS_REVERB")),
            ]
        ),
        (
            "",
            [
                (.parameter("PRM_CABINET_RESONANCE"), .parameter("PRM_KNOB_POS_PRESENCE")),
                (.parameter("PRM_SOLO_SW"), .parameter("PRM_SOLO_LEVEL")), (nil, .contour),
            ]
        ),
    ]

    var body: some View {
        FlowLayout(spacing: 12) {
            ForEach(Self.groups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 8) {
                    // Tone Studio gives the last group no title; the empty line keeps its knobs level with the others.
                    Text(group.title.isEmpty ? " " : group.title.uppercased())
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Grid(alignment: .top, horizontalSpacing: 4, verticalSpacing: 6) {
                        GridRow {
                            ForEach(Array(group.columns.enumerated()), id: \.offset) { _, column in
                                if let upper = column.upper {
                                    view(of: upper).frame(minHeight: 44, alignment: .top)
                                } else {
                                    Color.clear.frame(height: 44).gridCellUnsizedAxes(.horizontal)
                                }
                            }
                        }
                        GridRow {
                            ForEach(Array(group.columns.enumerated()), id: \.offset) { _, column in
                                view(of: column.lower)
                            }
                        }
                    }
                }
                .padding(10)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // At its ideal size, as the grid would otherwise squeeze a menu's column below the menu's width, and at least as wide
    // as a knob's column.
    private func view(of cell: Cell) -> some View {
        Group {
            switch cell {
            case .button(let button):
                LEDButton(model: model, button: button)
            case .parameter(let prm):
                ControlView(model: model, parameter: model.map.panelParameter(prm))
            case .contour:
                ContourKnob(model: model)
            }
        }
        .fixedSize()
        .frame(minWidth: 60)
    }
}

extension ParameterMap {
    /// The parameter of the front panel's control with Tone Studio id `prm`.
    func panelParameter(_ prm: String) -> Parameter {
        guard let parameter = table.parameters.first(where: { $0.prm == prm && $0.panel != nil }) else {
            preconditionFailure("the parameter table has no panel control \(prm)")
        }
        return parameter
    }
}

/// VARIATION or an effect's colour button, with its LED. Pressing it does what the amp's own button does; the LED shows
/// what the amp reports.
private struct LEDButton: View {
    let model: EditorModel
    let button: PanelButton

    var body: some View {
        let state = model.led(of: button).flatMap { model.value(of: $0) } ?? 0
        let text =
            button == .variation
            ? (state > 0 ? "ON" : "OFF") : ["OFF", "GREEN", "RED", "YELLOW"][min(max(state, 0), 3)]
        VStack(spacing: 3) {
            Button {
                Task { await model.press(button) }
            } label: {
                Image(systemName: state > 0 ? "circle.fill" : "circle")
                    .foregroundStyle(Self.colour(button, state))
                    .frame(width: 30)
            }
            .help(button == .variation ? "Press VARIATION" : "Next colour, as the button on the amp")
            .accessibilityLabel(button.label)
            .accessibilityValue(text)
            Text(button == .variation ? "VARIATION" : text).font(.caption2).foregroundStyle(.secondary)
            if let refusal = model.buttonRefusals[button] {
                Text(refusal).font(.caption2).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
    }

    private static func colour(_ button: PanelButton, _ state: Int) -> Color {
        if button == .variation {
            return state > 0 ? .orange : .secondary
        }
        return [.secondary, .green, .red, .yellow][min(max(state, 0), 3)]
    }
}

/// Places its views side by side, top-aligned, and starts a new line when the next one does not fit.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let places = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(
            width: places.map { $0.frame.maxX }.max() ?? 0, height: places.map { $0.frame.maxY }.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for place in arrange(subviews, width: bounds.width) {
            subviews[place.index].place(
                at: CGPoint(x: bounds.minX + place.frame.minX, y: bounds.minY + place.frame.minY),
                proposal: ProposedViewSize(place.frame.size))
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(index: Int, frame: CGRect)] {
        var places: [(index: Int, frame: CGRect)] = []
        var origin = CGPoint.zero
        var lineHeight: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x > 0, origin.x + size.width > width {
                origin = CGPoint(x: 0, y: origin.y + lineHeight + spacing)
                lineHeight = 0
            }
            places.append((index, CGRect(origin: origin, size: size)))
            origin.x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return places
    }
}
