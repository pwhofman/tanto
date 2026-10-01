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
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack {
                    ConnectionBadge(connection: model.connection)
                    if let channel = model.currentChannel {
                        Text(ChannelList.label(channel)).monospaced()
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

/// The nine channels; switching them comes with the librarian (plan 3).
private struct ChannelList: View {
    let model: EditorModel

    var body: some View {
        List {
            Section("Channels") {
                ForEach(Array(model.channelNames.enumerated()), id: \.offset) { slot, name in
                    HStack {
                        Text(Self.label(slot)).monospaced().foregroundStyle(.secondary)
                        Text(name)
                    }
                    .fontWeight(slot == model.currentChannel ? .bold : .regular)
                }
            }
        }
    }

    static func label(_ slot: Int) -> String {
        slot == 0 ? "PANEL" : "\(slot <= 4 ? "A" : "B")\((slot - 1) % 4 + 1)"
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

/// The live patch: its name, then one box per editor section.
private struct EditorView: View {
    let model: EditorModel
    @State private var name = ""

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Name").frame(width: 170, alignment: .leading)
                    TextField("Name", text: $name)
                        .frame(maxWidth: 220)
                        .onSubmit { Task { await model.rename(to: name) } }
                    if let refusal = model.nameRefusal {
                        Text(refusal).font(.caption).foregroundStyle(.red)
                    }
                }
                ForEach(model.sections) { section in
                    GroupBox(section.title) {
                        // The front panel first, as on the amp: knobs, then buttons, then the rest of the section.
                        let parameters = section.parameters.filter(model.isVisible)
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(parameters.filter { $0.block == "Status" }, id: \.offset) { parameter in
                                ParameterRow(model: model, parameter: parameter)
                            }
                            ForEach(section.buttons, id: \.self) { button in
                                PanelButtonRow(model: model, button: button)
                            }
                            ForEach(parameters.filter { $0.block != "Status" }, id: \.offset) { parameter in
                                ParameterRow(model: model, parameter: parameter)
                            }
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding()
        }
        .disabled(model.connection != .connected)
        .onChange(of: model.liveName, initial: true) { name = model.liveName }
    }
}
