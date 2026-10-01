import KatanaKit
import SwiftUI

/// The main window: channels on the left, the live patch on the right, the connection, the current channel and Panic in
/// the toolbar.
struct ContentView: View {
    let model: EditorModel

    var body: some View {
        NavigationSplitView {
            ChannelList(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            EditorView(model: model)
                .alert(
                    "Channels", isPresented: Binding(get: { model.librarianMessage != nil }, set: { _ in })
                ) {
                    Button("OK") { model.dismissLibrarianMessage() }
                } message: {
                    Text(model.librarianMessage ?? "")
                }
        }
        // Both answers come from the buttons; Esc picks Cancel.
        .alert(
            Self.switchTitle(model.pendingSwitch),
            isPresented: Binding(get: { model.pendingSwitch != nil }, set: { _ in }),
            presenting: model.pendingSwitch
        ) { pending in
            Button("Cancel", role: .cancel) { Task { await model.answerSwitch(false) } }
                .keyboardShortcut(.defaultAction)
            Button(pending.question == .unsavedEdits ? "Discard Changes" : "Switch", role: .destructive) {
                Task { await model.answerSwitch(true) }
            }
        } message: { pending in
            Text(Self.switchMessage(pending, model: model))
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack {
                    ConnectionBadge(connection: model.connection)
                    if let channel = model.currentChannel {
                        Text(EditorModel.channelLabel(channel)).monospaced()
                    }
                }
                .labelStyle(.titleAndIcon)
            }
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) {
                    Task { await model.panic() }
                } label: {
                    Label("Panic", systemImage: "speaker.slash.fill")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .keyboardShortcut(.escape, modifiers: [])
                .help("VOLUME knob to 0 (Esc)")
            }
        }
    }
}

extension ContentView {
    static func switchTitle(_ pending: EditorModel.PendingSwitch?) -> String {
        guard let pending else { return "" }
        let channel = EditorModel.channelLabel(pending.slot)
        return switch pending.question {
        case .unsavedEdits: "Discard the changes to the live sound?"
        case .valuesAboveCeiling: "\(channel) is louder than the ceiling"
        }
    }

    static func switchMessage(_ pending: EditorModel.PendingSwitch, model: EditorModel) -> String {
        let channel = EditorModel.channelLabel(pending.slot)
        switch pending.question {
        case .unsavedEdits:
            return "Switching to \(channel) loads its stored sound, and the changes made in Tanto are lost."
        case .valuesAboveCeiling(let values):
            let lines = values.map { value in
                let ceiling = model.ceiling(of: value.parameter).map { value.parameter.displayText(for: $0) } ?? "?"
                return "\(value.parameter.label) \(value.parameter.displayText(for: value.value)) (ceiling \(ceiling))"
            }
            return "The amp loads these values at once when you switch:\n" + lines.joined(separator: "\n")
        }
    }
}

/// The nine channels. Clicking one switches to it; channels 1–8 can take the live sound and a new name.
private struct ChannelList: View {
    let model: EditorModel
    @State private var dialog: Dialog?
    @State private var newName = ""

    private enum Dialog: Identifiable {
        case save(Int)
        case rename(Int)

        var id: String {
            switch self {
            case .save(let slot): "save \(slot)"
            case .rename(let slot): "rename \(slot)"
            }
        }
    }

    var body: some View {
        // Selecting asks the model; the highlight follows the channel the amp reports, so a cancelled switch stays put.
        List(
            selection: Binding(
                get: { model.currentChannel },
                set: { slot in
                    if let slot, slot != model.currentChannel { Task { await model.requestSwitch(to: slot) } }
                })
        ) {
            Section("Channels") {
                ForEach(Array(model.channelNames.enumerated()), id: \.offset) { slot, name in
                    HStack {
                        Text(EditorModel.channelLabel(slot)).monospaced().foregroundStyle(.secondary)
                        Text(name)
                    }
                    .tag(slot)
                    .contextMenu {
                        if slot > 0 {
                            Button("Save Live Sound Here…") { dialog = .save(slot) }
                            Button("Rename…") {
                                newName = name
                                dialog = .rename(slot)
                            }
                        }
                    }
                }
            }
        }
        .disabled(model.connection != .connected)
        .alert(
            title, isPresented: Binding(get: { dialog != nil }, set: { if !$0 { dialog = nil } }), presenting: dialog
        ) {
            dialog in
            switch dialog {
            case .save(let slot):
                Button("Cancel", role: .cancel) {}
                Button("Save", role: .destructive) { Task { await model.save(to: slot) } }
            case .rename(let slot):
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Rename") { Task { await model.rename(slot, to: newName) } }
            }
        } message: { dialog in
            switch dialog {
            case .save(let slot):
                Text(
                    "This replaces \(EditorModel.channelLabel(slot)) “\(model.channelNames[slot])”. The sound does not change."
                )
            case .rename:
                Text("At most 16 characters. The sound does not change.")
            }
        }
    }

    private var title: String {
        switch dialog {
        case .save(let slot): "Save the live sound to \(EditorModel.channelLabel(slot))?"
        case .rename(let slot): "Rename \(EditorModel.channelLabel(slot))"
        case nil: ""
        }
    }
}

private struct ConnectionBadge: View {
    let connection: EditorModel.Connection

    var body: some View {
        switch connection {
        case .notConnected: Label("Not connected", systemImage: "cable.connector.slash")
        case .connecting: Label("Connecting…", systemImage: "cable.connector")
        case .connected: Label("Connected", systemImage: "cable.connector").foregroundStyle(.green)
        case .failed(let reason): Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }
}

/// The live patch: its name, the front panel and the pages.
private struct EditorView: View {
    let model: EditorModel
    @State private var name = ""

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                HStack {
                    TextField("Name", text: $name, prompt: Text("Patch name"))
                        .font(.title3)
                        .frame(maxWidth: 240)
                        .help("The live sound's name; Return renames it")
                        .onSubmit { Task { await model.rename(to: name) } }
                    if let refusal = model.nameRefusal {
                        Text(refusal).font(.caption).foregroundStyle(.red)
                    }
                }
                FrontPanel(model: model)
                Pages(model: model)
            }
            .padding()
        }
        .disabled(model.connection != .connected)
        .onChange(of: model.liveName, initial: true) { name = model.liveName }
    }
}
