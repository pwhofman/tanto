import KatanaKit
import SwiftUI

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
