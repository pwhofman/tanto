import KatanaKit
import SwiftUI

/// Settings: the ceiling. Raising it asks for confirmation (design spec, section 5.2).
struct SettingsView: View {
    let model: EditorModel
    @State private var raiseTo: Int?
    @State private var error: String?

    var body: some View {
        Form {
            Stepper(
                value: Binding(get: { model.ceilingPercent }, set: request),
                in: 0...100,
                step: 5
            ) {
                Text("Ceiling: \(model.ceilingPercent) % of each guarded control's travel")
            }
            Text(
                "Tanto never raises VOLUME, GAIN, levels and the other guarded controls above the ceiling, and raises them gradually up to it."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if let error {
                Text(error).foregroundStyle(.red)
            }
        }
        .padding()
        .frame(width: 460)
        .confirmationDialog(
            "Raise the ceiling to \(raiseTo ?? 0) %?",
            isPresented: Binding(get: { raiseTo != nil }, set: { if !$0 { raiseTo = nil } })
        ) {
            Button("Raise the Ceiling") {
                if let raiseTo { apply(raiseTo) }
                raiseTo = nil
            }
            Button("Cancel", role: .cancel) { raiseTo = nil }
        } message: {
            Text("A higher ceiling lets Tanto make the amp louder.")
        }
    }

    private func request(_ percent: Int) {
        if model.needsConfirmation(toSetCeilingPercent: percent) {
            raiseTo = percent
        } else {
            apply(percent)
        }
    }

    private func apply(_ percent: Int) {
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
