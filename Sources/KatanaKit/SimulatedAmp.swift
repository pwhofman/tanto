import Foundation
import Synchronization

/// An in-memory Katana MkII for tests and for development while the amp is off.
///
/// It answers identity requests and RQ1 reads from its memory, stores DT1 writes, and records every message it
/// receives with its arrival time. It copies what hardware checks 1 and 2 showed of the real amp: it ignores RQ1 and DT1
/// messages for another device ID, the VOLUME knob register sets the amp volume one to one, and a channel switch sends
/// the channel number followed by the whole patch in messages of 241 bytes. A colour-button press moves an effect that
/// is on to its next colour, and a VARIATION press toggles VARIATION; both report what changed. An effect knob switches
/// its effect on above −1 and sets some of the effect's parameters, as hardware check 3 logged.
public final class SimulatedAmp: MIDITransport {
    /// A message the simulated amp received.
    public struct Received: Sendable {
        /// The message.
        public let message: [UInt8]
        /// When it arrived.
        public let time: ContinuousClock.Instant
        /// For a write: what the amp's memory held there before, which the amp may have changed itself since Tanto's
        /// last write.
        public let previous: [UInt8]?
    }

    /// The identity reply of the user's Katana-100 MkII, recorded in hardware check 1: device ID 00, model code 06.
    public static let katanaIdentityReply: [UInt8] = [
        0xF0, 0x7E, 0x00, 0x06, 0x02, 0x41, 0x33, 0x03, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00, 0xF7,
    ]

    /// The device ID the simulated amp answers to: byte 2 of its identity reply.
    public let deviceID: UInt8
    public let incoming: AsyncStream<[UInt8]>
    private let continuation: AsyncStream<[UInt8]>.Continuation
    private let state: Mutex<State>
    private let patchSize: Int
    private let volumeKnobOffset: Int?
    private let ampVolumeOffset: Int?
    // Per panel button: the offset of its LED, and for a colour button the offset of its colour selection.
    private let buttonOffsets: [PanelButton: (led: Int, selection: Int?)]
    // Per TAP button: the DELAY TIME it sets.
    private let tapTimes: [TapButton: Parameter]
    // Per effect knob's offset: what turning it does.
    private let effectKnobs: [Int: EffectKnob]

    // An effect knob of the front panel and what the amp does when it turns.
    private struct EffectKnob {
        let knob: Parameter
        let onOff: Parameter
        let led: Parameter
        let selection: Parameter
        // The parameters it sets, each with the type it was measured with (`nil`: any type) and its value at knob 0, 10,
        // …, 100.
        let curves: [(parameter: Parameter, type: (parameter: Parameter, value: Int)?, values: [Int])]
    }

    // What the amp set as each effect knob turned in hardware check 3, at knob 0, 10, …, 100. One type per effect was
    // measured; the booster, delay and reverb values are taken for all their types, MOD's and FX's only for theirs.
    private static let measuredKnobs: [(knob: String, block: String, onOff: String, curves: [(String, Int?, [Int])])] =
        {
            let rates: [(String, Int?, [Int])] = [
                ("PRM_FX1_2x2CHORUS_LOW_RATE", 29, [21, 27, 33, 37, 43, 51, 57, 62, 67, 75, 79]),
                ("PRM_FX1_2x2CHORUS_HIGH_RATE", 29, [11, 17, 23, 27, 32, 41, 47, 52, 57, 65, 69]),
                ("PRM_FX1_TREMOLO_RATE", 21, [31, 33, 37, 41, 45, 51, 60, 64, 75, 83, 89]),
            ]
            return [
                (
                    "BOOST", "Patch_0", "PRM_ODDS_SW",
                    [
                        ("PRM_ODDS_DRIVE", nil, [1, 8, 15, 22, 28, 36, 41, 48, 57, 64, 69]),
                        ("PRM_ODDS_EFFECT_LEVEL", nil, [74, 71, 69, 64, 62, 57, 55, 50, 48, 43, 41]),
                    ]
                ),
                ("MOD", "Fx(1)", "PRM_FX1_SW", rates),
                ("FX", "Fx(2)", "PRM_FX1_SW", rates),
                (
                    "DELAY", "Delay(1)", "PRM_DLY_SW",
                    [
                        ("PRM_DLY_COMMON_EFFECT_LEVEL", nil, [2, 17, 34, 50, 64, 70, 76, 82, 87, 93, 99]),
                        ("PRM_DLY_COMMON_FEEDBACK", nil, [35, 34, 33, 32, 29, 29, 28, 27, 24, 24, 23]),
                    ]
                ),
                (
                    "REVERB", "Patch_1", "PRM_REVERB_SW",
                    [("PRM_REVERB_EFFECT_LEVEL", nil, [2, 20, 40, 52, 60, 66, 74, 79, 88, 93, 99])]
                ),
            ]
        }()

    private struct State {
        var memory: [Int: UInt8]
        var received: [Received] = []
        var answersReads = true
        var confirmsSaves = true
        var sendsDumps = true
        var dumpTailDelay: Duration?
        var dumpTailTimes: [ContinuousClock.Instant] = []
        let identityReply: [UInt8]
        var crossingKnobTurn: (address: Address, value: [UInt8])?
        var lastTap: [TapButton: ContinuousClock.Instant] = [:]
    }

    /// Creates a simulated amp whose nine stored patches and live patch hold the table's initial values.
    ///
    /// Stored patches are named `SIM PATCH 0` to `SIM PATCH 8`, the live patch `SIM LIVE`. The current channel is A1
    /// and the editor communication level 8.
    ///
    /// - Parameters:
    ///   - map: Layout used to fill the patches.
    ///   - identityReply: Reply to identity requests; byte 2 sets the device ID.
    public init(map: ParameterMap, identityReply: [UInt8] = SimulatedAmp.katanaIdentityReply) {
        deviceID = identityReply[2]
        patchSize = map.patchSize
        volumeKnobOffset = map.parameter(block: "Status", prm: "PRM_KNOB_POS_VOLUME")?.offset
        ampVolumeOffset = map.parameter(block: "Patch_0", prm: "PRM_PREAMP_A_LEVEL")?.offset
        var buttonOffsets: [PanelButton: (led: Int, selection: Int?)] = [:]
        let selections = [PanelButton.booster: "BOOST", .mod: "MOD", .fx: "FX", .delay: "DELAY", .reverb: "REVERB"]
        for button in PanelButton.allCases {
            if let led = map.parameter(block: "Status", prm: button.led) {
                let selection = selections[button].flatMap {
                    map.parameter(block: "Patch_2", prm: "PRM_FXBOX_SEL_\($0)")
                }
                buttonOffsets[button] = (led.offset, selection?.offset)
            }
        }
        self.buttonOffsets = buttonOffsets
        tapTimes = Dictionary(
            uniqueKeysWithValues: TapButton.allCases.compactMap { button in
                map.parameter(block: button.block, prm: "PRM_DLY_COMMON_DLY_TIME").map { (button, $0) }
            })
        var effectKnobs: [Int: EffectKnob] = [:]
        for measured in Self.measuredKnobs {
            guard let knob = map.parameter(block: "Status", prm: "PRM_KNOB_POS_\(measured.knob)"),
                let onOff = map.parameter(block: measured.block, prm: measured.onOff),
                let led = map.parameter(block: "Status", prm: "PRM_LED_STATE_\(measured.knob)"),
                let selection = map.parameter(block: "Patch_2", prm: "PRM_FXBOX_SEL_\(measured.knob)")
            else { continue }
            let type = map.parameter(block: measured.block, prm: "PRM_FX1_FXTYPE")
            let curves = measured.curves.compactMap { prm, typeValue, values in
                map.parameter(block: measured.block, prm: prm).map { parameter in
                    (parameter, typeValue.flatMap { value in type.map { ($0, value) } }, values)
                }
            }
            effectKnobs[knob.offset] = EffectKnob(
                knob: knob, onOff: onOff, led: led, selection: selection, curves: curves)
        }
        self.effectKnobs = effectKnobs
        (incoming, continuation) = AsyncStream.makeStream(of: [UInt8].self)
        var memory: [Int: UInt8] = [:]
        let patches =
            (0...8).map { (Address.userPatch($0), "SIM PATCH \($0)") } + [(Address.temporaryPatch, "SIM LIVE")]
        for (base, name) in patches {
            for parameter in map.table.parameters {
                let bytes =
                    if let initial = parameter.initial {
                        parameter.encoding.encode(initial + parameter.rawOffset)
                    } else {
                        Array(name.padding(toLength: 16, withPad: " ", startingAt: 0).utf8)
                    }
                for (index, byte) in bytes.enumerated() {
                    memory[base.linear + parameter.offset + index] = byte
                }
            }
        }
        memory[Address.currentPatchNumber.linear] = 0
        memory[Address.currentPatchNumber.linear + 1] = 1
        memory[Address.editorCommunicationLevel.linear] = 8
        state = Mutex(State(memory: memory, identityReply: identityReply))
    }

    /// Handles a message from Tanto as the amp would.
    ///
    /// - Parameter message: A complete SysEx message.
    public func send(_ message: [UInt8]) throws {
        let now = ContinuousClock.now
        var reports: [[UInt8]] = []
        var tailDelay: Duration?
        let reply: [UInt8]? = state.withLock { state in
            var previous: [UInt8]?
            if message.count > 2, message[2] == deviceID,
                case .dataSet(let address, let data) = IncomingMessage(message)
            {
                previous = (0..<data.count).map { state.memory[address.linear + $0] ?? 0 }
            }
            state.received.append(Received(message: message, time: now, previous: previous))
            if message == SysEx.identityRequest {
                return state.identityReply
            }
            if let (address, size) = Self.parseRQ1(message, deviceID: deviceID) {
                guard state.answersReads else { return nil }
                let data = (0..<size).map { state.memory[address.linear + $0] ?? 0 }
                return SysEx.dt1(address, data: data, deviceID: deviceID)
            }
            if message.count > 2, message[2] == deviceID,
                case .dataSet(let address, let data) = IncomingMessage(message)
            {
                if let button = PanelButton.allCases.first(where: { $0.address == address }) {
                    reports = press(button, &state.memory)
                    return nil
                }
                if let button = TapButton.allCases.first(where: { $0.address == address }) {
                    reports = tap(button, at: now, &state)
                    return nil
                }
                if address == .currentPatchNumber || address == .patchWrite, data.count == 2,
                    (0...8).contains(Int(data[1]))
                {
                    let slot = Int(data[1])
                    if address == .currentPatchNumber {
                        let dump = load(slot, &state.memory)
                        if state.sendsDumps {
                            reports = dump
                            tailDelay = state.dumpTailDelay
                        }
                    } else {
                        copy(from: .temporaryPatch, to: .userPatch(slot), &state.memory)
                        if state.confirmsSaves {
                            reports = [SysEx.dt1(.patchWrite, data: data, deviceID: deviceID)]
                        }
                    }
                    return nil
                }
                for (index, byte) in data.enumerated() {
                    state.memory[address.linear + index] = byte
                }
                // A colour chosen on Tone Studio's EFFECTS page lights up as its button would, if the effect is on.
                for offsets in buttonOffsets.values {
                    guard let selection = offsets.selection, address == .temporaryPatch.advanced(by: selection),
                        let colour = data.first, (state.memory[Address.temporaryPatch.linear + offsets.led] ?? 0) > 0
                    else { continue }
                    state.memory[Address.temporaryPatch.linear + offsets.led] = colour + 1
                    reports.append(
                        SysEx.dt1(.temporaryPatch.advanced(by: offsets.led), data: [colour + 1], deviceID: deviceID))
                }
                if let turn = state.crossingKnobTurn, turn.address == address {
                    // The knob turn happened first on the amp, so Tanto's write wins there; its report arrives late.
                    state.crossingKnobTurn = nil
                    reports.append(SysEx.dt1(address, data: turn.value, deviceID: deviceID))
                }
                if let volumeKnobOffset, let ampVolumeOffset,
                    address == Address.temporaryPatch.advanced(by: volumeKnobOffset), let volume = data.first
                {
                    state.memory[Address.temporaryPatch.linear + ampVolumeOffset] = volume
                }
                if let knob = effectKnobs[address.linear - Address.temporaryPatch.linear], let raw = data.first {
                    reports += turn(knob, to: knob.knob.value(fromRaw: Int(raw)), &state.memory)
                }
            }
            return nil
        }
        if let reply {
            continuation.yield(reply)
        }
        for report in reports {
            continuation.yield(report)
        }
        if let tailDelay {
            Task { [self] in
                do {
                    try await Task.sleep(for: tailDelay)
                } catch {
                    return  // cancelled: never happens
                }
                state.withLock { $0.dumpTailTimes.append(.now) }
                continuation.yield(SysEx.dt1(Address(packed: 0x6000_0F44), data: [0, 0, 0, 0], deviceID: deviceID))
            }
        }
    }

    // Switches the knob's effect and sets what the knob sets, as the amp does, and returns the reports of what changed.
    private func turn(_ knob: EffectKnob, to position: Int, _ memory: inout [Int: UInt8]) -> [[UInt8]] {
        var reports: [[UInt8]] = []
        func value(of parameter: Parameter) -> Int {
            let address = Address.temporaryPatch.advanced(by: parameter.offset).linear
            let bytes = (0..<parameter.encoding.byteCount).map { memory[address + $0] ?? 0 }
            return parameter.value(fromRaw: parameter.encoding.decode(bytes))
        }
        func store(_ value: Int, in parameter: Parameter) {
            let address = Address.temporaryPatch.advanced(by: parameter.offset)
            let bytes = parameter.encoding.encode(value + parameter.rawOffset)
            guard (0..<bytes.count).map({ memory[address.linear + $0] ?? 0 }) != bytes else { return }
            for (index, byte) in bytes.enumerated() {
                memory[address.linear + index] = byte
            }
            reports.append(SysEx.dt1(address, data: bytes, deviceID: deviceID))
        }
        // Off at −1 leaves the parameters where knob 0 puts them.
        let turned = min(max(position, 0), 100)
        for curve in knob.curves {
            if let type = curve.type, value(of: type.parameter) != type.value {
                continue
            }
            let lower = curve.values[turned / 10]
            let upper = curve.values[min(turned / 10 + 1, curve.values.count - 1)]
            store(lower + Int((Double((upper - lower) * (turned % 10)) / 10).rounded()), in: curve.parameter)
        }
        store(position >= 0 ? 1 : 0, in: knob.onOff)
        store(position >= 0 ? value(of: knob.selection) + 1 : 0, in: knob.led)
        return reports
    }

    // Sets DELAY TIME to the interval since the previous tap, as the amp's TAP does; a first tap only starts the count.
    private func tap(_ button: TapButton, at time: ContinuousClock.Instant, _ state: inout State) -> [[UInt8]] {
        defer { state.lastTap[button] = time }
        guard let previous = state.lastTap[button], let parameter = tapTimes[button] else { return [] }
        let milliseconds = Int(((time - previous) / .milliseconds(1)).rounded())
        guard (parameter.minimum...parameter.maximum).contains(milliseconds) else { return [] }
        let address = Address.temporaryPatch.advanced(by: parameter.offset)
        let bytes = parameter.encoding.encode(milliseconds + parameter.rawOffset)
        for (index, byte) in bytes.enumerated() {
            state.memory[address.linear + index] = byte
        }
        return [SysEx.dt1(address, data: bytes, deviceID: deviceID)]
    }

    // Does what the amp's own button does and returns the reports of what changed.
    private func press(_ button: PanelButton, _ memory: inout [Int: UInt8]) -> [[UInt8]] {
        guard let offsets = buttonOffsets[button] else { return [] }
        let live = Address.temporaryPatch.linear
        let led = Int(memory[live + offsets.led] ?? 0)
        let ledAddress = Address.temporaryPatch.advanced(by: offsets.led)
        guard let selection = offsets.selection else {
            let toggled = UInt8(1 - min(led, 1))
            memory[live + offsets.led] = toggled
            return [SysEx.dt1(ledAddress, data: [toggled], deviceID: deviceID)]
        }
        // An effect that is off stays off, as in Tone Studio's offline mode.
        guard led > 0 else { return [] }
        let next = (Int(memory[live + selection] ?? 0) + 1) % 3
        memory[live + selection] = UInt8(next)
        memory[live + offsets.led] = UInt8(next + 1)
        return [
            SysEx.dt1(Address.temporaryPatch.advanced(by: selection), data: [UInt8(next)], deviceID: deviceID),
            SysEx.dt1(ledAddress, data: [UInt8(next + 1)], deviceID: deviceID),
        ]
    }

    /// Simulates a knob turn that crosses Tanto's next write to `address`: the amp applies the turn just before the
    /// write, so the write wins, and the turn's report reaches Tanto just after the write.
    ///
    /// - Parameters:
    ///   - value: The bytes the knob turn reports.
    ///   - address: The register the knob changes.
    public func turnKnobWhenNextWritten(_ value: [UInt8], at address: Address) {
        state.withLock { $0.crossingKnobTurn = (address, value) }
    }

    /// Sends any message to Tanto as if the amp had sent it, e.g. a corrupted one.
    ///
    /// - Parameter message: The bytes.
    public func sendFromAmp(_ message: [UInt8]) {
        continuation.yield(message)
    }

    /// Simulates pressing a channel button: the stored patch becomes the live patch, and the amp sends the channel
    /// number followed by the whole patch.
    ///
    /// - Parameter slot: 0 = PANEL, 1–4 = A1–A4, 5–8 = B1–B4.
    public func switchChannelOnAmp(_ slot: Int) {
        let messages = state.withLock { load(slot, &$0.memory) }
        for message in messages {
            continuation.yield(message)
        }
    }

    /// Ends the dump after a select as the real amp does, with a short message past the patch, `delay` after the parts
    /// that cover the patch (hardware check 4: about 20 ms); `nil`, as at first, sends no such message.
    ///
    /// - Parameter delay: The delay, or `nil`.
    public func setDumpTail(after delay: Duration?) {
        state.withLock { $0.dumpTailDelay = delay }
    }

    /// When each message of `setDumpTail(after:)` went out.
    public var dumpTailTimes: [ContinuousClock.Instant] {
        state.withLock { $0.dumpTailTimes }
    }

    /// Stops or resumes sending the channel number and the patch after a select, to test the reads that replace them.
    ///
    /// - Parameter sends: Whether a select gets them.
    public func setSendsDumps(_ sends: Bool) {
        state.withLock { $0.sendsDumps = sends }
    }

    /// Stops or resumes confirming saves, to test the save timeout.
    ///
    /// - Parameter confirms: Whether a save gets its confirmation.
    public func setConfirmsSaves(_ confirms: Bool) {
        state.withLock { $0.confirmsSaves = confirms }
    }

    // Loads a stored patch into the live patch and returns the messages the amp sends about it.
    private func load(_ slot: Int, _ memory: inout [Int: UInt8]) -> [[UInt8]] {
        copy(from: .userPatch(slot), to: .temporaryPatch, &memory)
        memory[Address.currentPatchNumber.linear] = 0
        memory[Address.currentPatchNumber.linear + 1] = UInt8(slot)
        var messages = [SysEx.dt1(.currentPatchNumber, data: [0, UInt8(slot)], deviceID: deviceID)]
        let live = Address.temporaryPatch.linear
        for start in stride(from: 0, to: patchSize, by: 241) {
            let data = (start..<min(start + 241, patchSize)).map { memory[live + $0] ?? 0 }
            messages.append(SysEx.dt1(.temporaryPatch.advanced(by: start), data: data, deviceID: deviceID))
        }
        return messages
    }

    private func copy(from source: Address, to target: Address, _ memory: inout [Int: UInt8]) {
        for index in 0..<patchSize {
            memory[target.linear + index] = memory[source.linear + index] ?? 0
        }
    }

    /// Every message received so far, oldest first.
    public var received: [Received] {
        state.withLock { $0.received }
    }

    /// Reads simulated memory; unset bytes read as 0.
    ///
    /// - Parameters:
    ///   - address: First address.
    ///   - count: Number of bytes.
    /// - Returns: The bytes.
    public func memory(at address: Address, count: Int) -> [UInt8] {
        state.withLock { state in (0..<count).map { state.memory[address.linear + $0] ?? 0 } }
    }

    /// Changes simulated memory without telling Tanto, e.g. to prepare a test.
    ///
    /// - Parameters:
    ///   - bytes: New memory content.
    ///   - address: Where it starts.
    public func setMemory(_ bytes: [UInt8], at address: Address) {
        state.withLock { state in
            for (index, byte) in bytes.enumerated() {
                state.memory[address.linear + index] = byte
            }
        }
    }

    /// Simulates a change made on the amp itself: stores `bytes` and sends them to Tanto as a DT1.
    ///
    /// - Parameters:
    ///   - bytes: New memory content, each byte below `0x80`.
    ///   - address: Where the change starts.
    public func changeOnAmp(_ bytes: [UInt8], at address: Address) {
        state.withLock { state in
            for (index, byte) in bytes.enumerated() {
                state.memory[address.linear + index] = byte
            }
        }
        continuation.yield(SysEx.dt1(address, data: bytes, deviceID: deviceID))
    }

    /// Stops or resumes answering RQ1 reads, to test timeouts.
    ///
    /// - Parameter answers: Whether reads get a reply.
    public func setAnswersReads(_ answers: Bool) {
        state.withLock { $0.answersReads = answers }
    }

    static func parseRQ1(_ message: [UInt8], deviceID: UInt8) -> (Address, Int)? {
        let prefix = SysEx.header(deviceID) + [SysEx.rq1Command]
        guard message.count == prefix.count + 10, message.starts(with: prefix), message.last == 0xF7 else {
            return nil
        }
        let body = Array(message[prefix.count..<(prefix.count + 8)])
        guard body.allSatisfy({ $0 < 0x80 }), SysEx.checksum(body) == message[prefix.count + 8] else { return nil }
        return (Address(bytes: body.prefix(4)), Address(bytes: body.suffix(4)).linear)
    }
}
