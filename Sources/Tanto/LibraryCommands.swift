import AppKit
import KatanaKit
import SwiftUI
import UniformTypeIdentifiers

/// The File menu's backup and restore of channels A1–B4 (design spec, section 7), with the system's panels.
struct LibraryCommands: Commands {
    let model: EditorModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Back Up Channels…") { Task { await backUpChannels(model) } }
                .disabled(model.connection != .connected)
            Button("Restore Channels…") { Task { await restoreChannels(model) } }
                .disabled(model.connection != .connected)
        }
    }
}

/// Reads channels 1–8, saves them where the user chooses, and reads the file back to check it.
///
/// - Parameter model: The connected model.
@MainActor
func backUpChannels(_ model: EditorModel) async {
    guard let backup = await model.backup() else { return }
    let panel = NSSavePanel()
    panel.title = "Back Up Channels"
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue =
        "Katana \(backup.created.formatted(.iso8601.year().month().day())).\(ChannelBackup.fileExtension)"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
        try backup.encoded().write(to: url, options: .atomic)
        _ = model.checkBackupFile(try Data(contentsOf: url), against: backup)
    } catch {
        showProblem("The backup was not saved", error)
    }
}

/// Reads a backup file, asks with the eight names and MASTER at minimum, then restores channels 1–8. Cancel is the
/// default button (design spec, section 5.4).
///
/// - Parameter model: The connected model.
@MainActor
func restoreChannels(_ model: EditorModel) async {
    let panel = NSOpenPanel()
    panel.title = "Restore Channels"
    panel.allowedContentTypes = [.json]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let data: Data
    do {
        data = try Data(contentsOf: url)
    } catch {
        showProblem("The file cannot be read", error)
        return
    }
    guard let backup = model.loadBackup(data) else { return }
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "Restore channels A1 to B4 from “\(url.lastPathComponent)”?"
    alert.informativeText =
        "Turn the amp's MASTER to minimum first. These channels are written, and no channel is selected afterwards:\n\n"
        + backup.channels.map { "\(EditorModel.channelLabel($0.slot))   \($0.name)" }.joined(separator: "\n")
    alert.addButton(withTitle: "Cancel")
    alert.addButton(withTitle: "Restore")
    guard alert.runModal() == .alertSecondButtonReturn else { return }
    await model.restore(backup)
}

@MainActor
private func showProblem(_ title: String, _ error: any Error) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = error.localizedDescription
    alert.runModal()
}
