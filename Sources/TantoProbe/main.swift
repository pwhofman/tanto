// The hardware checks of docs/hardware-checklist.md. Without --connect the probe only lists MIDI endpoints. Check 1
// (--connect) reads, plus the editor-mode flag. Check 2 (--connect --check2 STEP --master-at-minimum) writes, one step
// per run, and only through SafetyGuard.

import Foundation
import KatanaKit
import Synchronization

let usage = """
    usage: swift run TantoProbe [--connect [--listen SECONDS] [--log FILE] [--check2 STEP --master-at-minimum]]

      (no options)   list MIDI sources and destinations; sends nothing
      --connect      identity request, editor mode on, read the current channel, the channel names and the live
                     patch, editor mode off
      --listen N     before disconnecting, print what the amp sends for N seconds
      --log FILE     write every message sent and received to FILE
      --check2 STEP  hardware check 2, through SafetyGuard; STEP is one of
                       rename   write a test name into the live patch, read it back, restore the name
                       lower    lower the VOLUME knob by 10
                       panic    Panic: VOLUME knob to 0
                       ramp     raise the VOLUME knob by up to 10, ramped and within the ceiling
      --master-at-minimum
                     required with --check2: confirms the amp's MASTER knob is at minimum
    """

struct Options {
    static let check2Steps: Set = ["rename", "lower", "panic", "ramp"]

    var connect = false
    var listenSeconds = 0
    var logPath: String?
    var check2: String?
    var masterAtMinimum = false

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
            case "--check2":
                guard let value = remaining.popFirst(), Self.check2Steps.contains(value) else { return nil }
                check2 = value
            case "--master-at-minimum":
                masterAtMinimum = true
            default:
                return nil
            }
        }
        if !connect && (listenSeconds > 0 || logPath != nil || check2 != nil) { return nil }
        if check2 != nil && (!masterAtMinimum || listenSeconds > 0) { return nil }
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

func describe(_ address: Address, _ data: [UInt8], map: ParameterMap) -> String {
    let offset = address.linear - Address.temporaryPatch.linear
    let values = map.values(in: data, at: offset)
    guard (0..<map.patchSize).contains(offset), !values.isEmpty else {
        return "\(address)  \(hex(data))"
    }
    return values.map { "\(address)  \($0.parameter.block) \($0.parameter.label) = \($0.value)" }
        .joined(separator: "\n")
}

func readAndListen(_ session: AmpSession, map: ParameterMap, listenSeconds: Int) async throws {
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
    if listenSeconds > 0 {
        print("listening for \(listenSeconds) s: turn knobs, switch channels, change a colour")
        let listener = Task {
            for await change in session.changes {
                print("DT1   " + describe(change.address, change.data, map: map))
            }
        }
        try await Task.sleep(for: .seconds(listenSeconds))
        listener.cancel()
    }
}

func runCheck2(_ step: String, session: AmpSession, map: ParameterMap) async throws {
    guard let knob = map.parameter(block: "Status", prm: "PRM_KNOB_POS_VOLUME"),
        let ampVolume = map.parameter(block: "Patch_0", prm: "PRM_PREAMP_A_LEVEL")
    else {
        throw SafetyError.invalidTable("no VOLUME knob or amp volume")
    }
    try await session.readLivePatch(map)
    let safety = try SafetyGuard(session: session, map: map)
    // Read from the amp itself, not from Tanto's copy: the VOLUME knob register and the amp volume it should set.
    func report(_ moment: String) async throws {
        let knobValue = ValueEncoding.int1x7.decode(
            try await session.read(.temporaryPatch.advanced(by: knob.offset), size: 1))
        let ampValue = ValueEncoding.int1x7.decode(
            try await session.read(.temporaryPatch.advanced(by: ampVolume.offset), size: 1))
        print(
            "\(moment): VOLUME knob \(knobValue), amp volume \(ampValue), ceiling \(await safety.ceiling(of: knob) ?? -1)"
        )
    }
    // Whatever the amp sends by itself during the step. An echo of Tanto's own writes would show up here, and would
    // look like a knob turn to the guard (plan 2c, m9).
    let listener = Task {
        for await change in session.changes {
            print("amp   " + describe(change.address, change.data, map: map))
        }
    }
    defer { listener.cancel() }
    try await report("before")
    switch step {
    case "rename":
        let original = await session.liveName() ?? ""
        try await safety.rename(to: "TANTO TEST")
        print("name on the amp: \(PatchName.decode(try await session.read(.temporaryPatch, size: 16)))")
        try await safety.rename(to: original)
        print("name restored:   \(PatchName.decode(try await session.read(.temporaryPatch, size: 16)))")
    case "lower":
        let current = await session.liveValue(of: knob) ?? 0
        try await safety.set(knob, to: max(knob.minimum, current - 10))
    case "panic":
        await safety.panic()
    case "ramp":
        let current = await session.liveValue(of: knob) ?? 0
        let target = min(current + 10, await safety.ceiling(of: knob) ?? current)
        if target > current {
            try await safety.set(knob, to: target)
        } else {
            print("VOLUME is at or above its ceiling; nothing to ramp")
        }
    default:
        preconditionFailure("unknown step \(step)")
    }
    await safety.settle()
    try await report("after")
}

/// Whether the amp's main port is there in both directions.
func ampIsPresent() -> Bool {
    CoreMIDITransport.hasMainPort(in: CoreMIDITransport.sources())
        && CoreMIDITransport.hasMainPort(in: CoreMIDITransport.destinations())
}

func run(_ options: Options) async throws {
    if options.connect {
        // MIDIServer quits a few seconds after its last client has gone; when this run starts it again, the amp's ports
        // come back a moment later.
        for _ in 0..<30 where !ampIsPresent() {
            try await Task.sleep(for: .milliseconds(100))
        }
    }
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
        if direction == .sent, case .dataSet(let address, let data) = IncomingMessage(message),
            address != .editorCommunicationMode
        {
            print("sent  " + describe(address, data, map: map))
        }
    }
    let session = AmpSession(transport: transport)
    let info = try await session.connect()
    print("identity reply:    \(hex(info.identityReply))")
    print("device ID \(hex([info.deviceID])), model code \(hex([info.modelCode])) (06 is the Katana-100 MkII)")
    print("editor communication level \(info.communicationLevel); editor mode is on")
    do {
        if let step = options.check2 {
            try await runCheck2(step, session: session, map: map)
        } else {
            try await readAndListen(session, map: map, listenSeconds: options.listenSeconds)
        }
    } catch {
        do {
            try await session.disconnect()
        } catch let disconnectError {
            print("editor mode not switched off: \(disconnectError)")
        }
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
