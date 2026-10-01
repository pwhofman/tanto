// Hardware check 1 (docs/hardware-checklist.md): lists MIDI endpoints and, with --connect, reads from the amp.
// AmpSession has no way to write parameters; the only DT1 messages are editor mode on and off.

import Foundation
import KatanaKit
import Synchronization

let usage = """
    usage: swift run TantoProbe [--connect [--listen SECONDS] [--log FILE]]

      (no options)   list MIDI sources and destinations; sends nothing
      --connect      identity request, editor mode on, read the current channel, the channel names and the live
                     patch, editor mode off
      --listen N     before disconnecting, print what the amp sends for N seconds
      --log FILE     write every message sent and received to FILE
    """

struct Options {
    var connect = false
    var listenSeconds = 0
    var logPath: String?

    init?(_ arguments: [String]) {
        var remaining = arguments[...]
        while let argument = remaining.popFirst() {
            switch argument {
            case "--connect":
                connect = true
            case "--listen":
                guard let value = remaining.popFirst().flatMap({ Int($0) }), value > 0 else { return nil }
                listenSeconds = value
            case "--log":
                guard let value = remaining.popFirst() else { return nil }
                logPath = value
            default:
                return nil
            }
        }
        if !connect && (listenSeconds > 0 || logPath != nil) { return nil }
    }
}

/// Appends one line per message to a file; safe to call from any thread.
final class Transcript: Sendable {
    private let file: Mutex<FileHandle>
    private let start = ContinuousClock.now

    init(path: String) throws {
        guard FileManager.default.createFile(atPath: path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
        }
        file = Mutex(try FileHandle(forWritingTo: URL(filePath: path)))
    }

    func write(_ direction: LoggingTransport.Direction, _ message: [UInt8]) {
        let milliseconds = (ContinuousClock.now - start) / .milliseconds(1)
        let line = String(format: "%10.1f ms ", milliseconds) + (direction == .sent ? "> " : "< ") + hex(message)
        file.withLock { $0.write(Data((line + "\n").utf8)) }
    }
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

func channelName(_ slot: Int) -> String {
    slot == 0 ? "PANEL" : "\(slot <= 4 ? "A" : "B")\((slot - 1) % 4 + 1)"
}

func describe(_ change: AmpChange, map: ParameterMap) -> String {
    let offset = change.address.linear - Address.temporaryPatch.linear
    let values = map.values(in: change.data, at: offset)
    guard (0..<map.patchSize).contains(offset), !values.isEmpty else {
        return "DT1   \(change.address)  \(hex(change.data))"
    }
    return values.map { "DT1   \(change.address)  \($0.parameter.block) \($0.parameter.name) = \($0.value)" }
        .joined(separator: "\n")
}

func run(_ options: Options) async throws {
    print("MIDI sources:      \(CoreMIDITransport.sources().map(\.name))")
    print("MIDI destinations: \(CoreMIDITransport.destinations().map(\.name))")
    guard options.connect else { return }

    let map = try ParameterMap.bundled()
    let transcript = try options.logPath.map(Transcript.init(path:))
    let transport = LoggingTransport(wrapping: try CoreMIDITransport.katana()) { direction, message in
        transcript?.write(direction, message)
        if direction == .received, message.first != 0xF0 {
            print("MIDI  \(hex(message))")  // channel messages, e.g. a Program Change on a channel switch
        }
    }
    let session = AmpSession(transport: transport)
    let info = try await session.connect()
    print("identity reply:    \(hex(info.identityReply))")
    print("editor level \(info.communicationLevel), revision \(info.communicationRevision); editor mode is on")
    do {
        let current = ValueEncoding.int2x7.decode(try await session.read(.currentPatchNumber, size: 2))
        print("current channel:   \(current) (\(channelName(current)))")
        for slot in 0...8 {
            let name = PatchName.decode(try await session.read(.userPatch(slot), size: 16))
            print("  slot \(slot) \(channelName(slot).padding(toLength: 5, withPad: " ", startingAt: 0)) \(name)")
        }
        var live: [ParameterValue] = []
        for block in map.table.blocks {
            let data = try await session.read(.temporaryPatch.advanced(by: block.offset), size: block.size)
            live += map.values(in: data, at: block.offset)
        }
        print("live patch: \(PatchName.decode(try await session.read(.temporaryPatch, size: 16)))")
        for value in live where value.parameter.block == "Patch_0" && !value.parameter.name.isEmpty {
            let address = Address.temporaryPatch.advanced(by: value.parameter.offset)
            let prm = value.parameter.prm.padding(toLength: 28, withPad: " ", startingAt: 0)
            print("  \(address)  \(prm) \(value.value)")
        }
        if options.listenSeconds > 0 {
            print("listening for \(options.listenSeconds) s: turn knobs, switch channels, change a colour")
            let listener = Task {
                for await change in session.changes {
                    print(describe(change, map: map))
                }
            }
            try await Task.sleep(for: .seconds(options.listenSeconds))
            listener.cancel()
        }
    } catch {
        try? await session.disconnect()
        throw error
    }
    try await session.disconnect()
    print("editor mode is off")
}

guard let options = Options(Array(CommandLine.arguments.dropFirst())) else {
    print(usage)
    exit(2)
}
do {
    try await run(options)
} catch {
    print("error: \(error)")
    exit(1)
}
