import KatanaKit
import SwiftUI

/// Settings: the ceiling, off until the user turns it on. Raising it or turning it off asks for confirmation (design
/// spec, section 5.2).
struct SettingsView: View {
    let model: EditorModel
    @State private var confirming: Change?
    @State private var error: String?

    /// A change of the ceiling that waits for confirmation: a new percentage, or `nil` to turn the ceiling off.
    private struct Change {
        let percent: Int?
    }

    var body: some View {
        // While the ceiling is off, the stepper shows the percentage that turning it on restores.
        let percent = model.ceilingPercent ?? StoredSettings.lastCeilingPercent
        // A column rather than a Form, whose columns would part the checkbox from the stepper and cut the text short.
        VStack(alignment: .leading, spacing: 10) {
            Toggle(
                "Ceiling",
                isOn: Binding(
                    get: { model.ceilingPercent != nil },
                    set: { request($0 ? StoredSettings.lastCeilingPercent : nil) })
            )
            Stepper(value: Binding(get: { percent }, set: { request($0) }), in: 0...100, step: 5) {
                // Dimmed with the stepper, which a disabled state does not do for its label.
                Text("\(percent) % of each guarded control's travel")
                    .foregroundStyle(model.ceilingPercent == nil ? .secondary : .primary)
            }
            .disabled(model.ceilingPercent == nil)
            .padding(.leading, 20)
            Text(
                "Tantō always raises VOLUME, GAIN, levels and the other guarded controls gradually; a ceiling also keeps them below a share of their travel. The amp's MASTER knob limits the speaker and the PHONES jack, but not LINE OUT and USB: turn the ceiling on when those feed a PA, monitors or headphones."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error).foregroundStyle(.red)
            }
        }
        .padding()
        .frame(width: 460)
        .confirmationDialog(
            confirming?.percent.map { "Raise the ceiling to \($0) %?" } ?? "Turn the ceiling off?",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
        ) {
            Button(confirming?.percent == nil ? "Turn Off" : "Raise the Ceiling") {
                if let confirming { apply(confirming.percent) }
                confirming = nil
            }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: {
            Text(
                confirming?.percent == nil
                    ? "Without a ceiling, Tantō can raise the guarded controls to their maximum."
                    : "A higher ceiling lets Tantō make the amp louder.")
        }
    }

    private func request(_ percent: Int?) {
        if model.needsConfirmation(toSetCeilingPercent: percent) {
            confirming = Change(percent: percent)
        } else {
            apply(percent)
        }
    }

    private func apply(_ percent: Int?) {
        Task {
            do {
                try await model.setCeilingPercent(percent)
                StoredSettings.ceilingPercent = percent
                error = nil
            } catch {
                self.error = "\(error)"
            }
        }
    }
}
