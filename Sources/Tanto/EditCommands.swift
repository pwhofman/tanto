import KatanaKit
import SwiftUI

/// The Edit menu's Undo and Redo of Tanto's edits of the live sound (design spec, section 6). They replace the system's,
/// so in the name field too they undo sound edits, not typing.
struct EditCommands: Commands {
    let model: EditorModel

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button(model.undoTitle.map { "Undo \($0)" } ?? "Undo") {
                Task { await model.undo() }
            }
            .keyboardShortcut("z")
            .disabled(model.undoTitle == nil)
            Button(model.redoTitle.map { "Redo \($0)" } ?? "Redo") {
                Task { await model.redo() }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(model.redoTitle == nil)
        }
    }
}
