import AppKit
import KatanaKit
import SwiftUI
import os

/// Tanto: an editor for the BOSS Katana-100 MkII.
///
/// Launch arguments for development: `-simulated YES` uses the simulated amp instead of MIDI, `-snapshot FILE` (with
/// `-simulated YES`) saves the window as a PNG after start-up and quits, and `-page TITLE` opens another page than
/// BOOSTER. They are read as user defaults because AppKit takes a plain path argument for a document to open and then
/// opens no window.
@main
struct TantoApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = EditorModel(map: loadParameterMap())

    var body: some Scene {
        Window("Tanto", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 760, minHeight: 520)
                .task {
                    delegate.model = model
                    await start()
                }
        }
        .commands {
            LibraryCommands(model: model)
        }
        Settings {
            SettingsView(model: model)
        }
    }

    private func start() async {
        do {
            try await model.setCeilingPercent(StoredSettings.ceilingPercent)
        } catch {
            Logger.app.error("stored ceiling rejected: \(error)")
        }
        if UserDefaults.standard.bool(forKey: "simulated") {
            await model.connect(SimulatedAmp(map: model.map))
            if let path = UserDefaults.standard.string(forKey: "snapshot") {
                delegate.saveSnapshot(to: URL(filePath: path))
            }
            return
        }
        do {
            await model.follow(try CoreMIDIPorts())
        } catch {
            Logger.app.error("cannot watch MIDI ports: \(error)")
        }
    }
}

/// Loads the parameter table: the copy in the app bundle, or KatanaKit's resource when run with `swift run`.
private func loadParameterMap() -> ParameterMap {
    do {
        if let url = Bundle.main.url(forResource: "parameters", withExtension: "json") {
            return try ParameterMap(contentsOf: url)
        }
        return try ParameterMap.bundled()
    } catch {
        fatalError("the parameter table cannot be loaded: \(error)")
    }
}

extension Logger {
    static let app = Logger(subsystem: "io.github.pwhofman.tanto", category: "app")
}

/// Settings kept between launches.
enum StoredSettings {
    private static let ceilingKey = "ceilingPercent"

    /// The ceiling percentage; 50 until the user changes it.
    static var ceilingPercent: Int {
        get { UserDefaults.standard.object(forKey: ceilingKey) as? Int ?? 50 }
        set { UserDefaults.standard.set(newValue, forKey: ceilingKey) }
    }
}

/// Makes a `swift run` build behave like an app, switches editor mode off before quitting, and takes snapshots.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: EditorModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.disconnectWhileQuitting(timeout: .seconds(1))
    }

    /// Saves the main window as a PNG after the layout has settled, then quits.
    ///
    /// - Parameter url: Where to write the PNG.
    func saveSnapshot(to url: URL) {
        Task {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            // The window's layers, because `cacheDisplay` leaves out SwiftUI's text.
            guard let window = NSApplication.shared.windows.first(where: \.isVisible),
                let view = window.contentView?.superview, let layer = view.layer,
                let space = CGColorSpace(name: CGColorSpace.sRGB),
                let context = CGContext(
                    data: nil, width: Int(view.bounds.width * window.backingScaleFactor),
                    height: Int(view.bounds.height * window.backingScaleFactor), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
            else {
                Logger.app.error("no window to snapshot")
                NSApplication.shared.terminate(nil)
                return
            }
            context.scaleBy(x: window.backingScaleFactor, y: window.backingScaleFactor)
            layer.render(in: context)
            do {
                guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
            } catch {
                Logger.app.error("snapshot not written: \(error)")
            }
            NSApplication.shared.terminate(nil)
        }
    }
}
