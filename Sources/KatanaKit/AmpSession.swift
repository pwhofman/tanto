import os

/// Errors from talking to the amp.
public enum AmpError: Error, Equatable, Sendable {
    /// The identity reply does not come from a Katana MkII.
    case notAKatana([UInt8])
    /// No identity reply arrived, also not after one retry.
    case noIdentityReply
    /// The amp's editor communication level is not 8, the level Tone Studio requires.
    case unsupportedCommunicationLevel(UInt8)
    /// No reply arrived for a read at this address, also not after one retry.
    case timeout(Address)
    /// The amp did not confirm saving to this channel within the time limit (design spec, section 8).
    case noSaveConfirmation(Int)
}

/// Reasons a write is refused before anything is sent.
public enum WriteError: Error, Equatable, Sendable {
    /// No Tone Studio control writes this parameter, so Tanto does not either (design spec, section 3.5).
    case notWritable(String)
    /// The value lies outside the parameter's range.
    case outOfRange(String, Int)
    /// A patch name must be at most 16 characters from space to `}`.
    case invalidName(String)
    /// Channels are 0 (PANEL) to 8 for selecting, and 1 to 8 for saving and writing.
    case noSuchChannel(Int)
    /// A write into a stored channel must lie inside the patch and carry 1 to 128 bytes.
    case outsideChannel(offset: Int, count: Int)
}

/// The lane an outgoing message waits in. A lane goes before the lanes below it; within a lane, first come, first
/// served.
enum WritePriority: Int, Comparable, Sendable {
    /// After everything already queued.
    case normal
    /// Before all queued normal messages; used for decreases (design spec, section 5.2).
    case high
    /// Before everything; only Panic uses it (design spec, section 5.5).
    case panic

    static func < (lhs: WritePriority, rhs: WritePriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// What a write was decided on. The session sends the write only if all of it still holds when the write's turn
/// comes, and drops it otherwise.
struct WriteBasis: Sendable {
    /// The channel generation of the decision; a channel change made on the amp raises it.
    let generation: Int
    /// The Panic count of the decision.
    let panics: Int
    /// Per parameter, the number of the amp's reports about it that the decision knew of.
    let reportCounts: [Parameter: Int]
}

/// What the amp reported while connecting.
public struct ConnectionInfo: Equatable, Sendable {
    /// The identity reply, from `F0` to `F7`.
    public let identityReply: [UInt8]
    /// Editor communication level; always 8, the only level Tone Studio accepts.
    public let communicationLevel: UInt8

    /// The amp's device ID: byte 2 of the identity reply.
    public var deviceID: UInt8 { identityReply[2] }
    /// The model code: byte 10 of the identity reply; `06` is the Katana-100 MkII.
    public var modelCode: UInt8 { identityReply[10] }
}

/// A DT1 from the amp that is not a reply to a read, i.e. a change made on the amp itself.
public struct AmpChange: Equatable, Sendable {
    /// Where the change starts.
    public let address: Address
    /// The new bytes.
    public let data: [UInt8]
}

/// A change of the live patch, from whatever source: a read, the amp, or a write by Tanto.
public enum LiveUpdate: Equatable, Sendable {
    /// Bytes of the live patch changed, starting at `offset` from the patch base.
    case bytes(offset: Int, data: [UInt8])
    /// The amp switched to another channel (0 = PANEL, 1–8 = A1–B4). The amp then sends the new patch as bytes.
    case channel(Int)
    /// The amp saved the live patch to a channel on its own; `nil` if its message did not say which.
    case patchSaved(Int?)
    /// The amp reported a change of the live patch that is not its dump after a channel change, e.g. a knob turned on
    /// the amp; the live patch then differs from the stored channel.
    case editedOnAmp
}

/// Timing of the conversation with the amp.
public struct SessionTiming: Sendable {
    /// Minimum time between two outgoing messages.
    public var spacing: Duration
    /// How long to wait for a reply before retrying once.
    public var readTimeout: Duration

    /// Creates a timing.
    ///
    /// - Parameters:
    ///   - spacing: Minimum time between two outgoing messages.
    ///   - readTimeout: How long to wait for a reply before retrying once.
    public init(spacing: Duration, readTimeout: Duration) {
        self.spacing = spacing
        self.readTimeout = readTimeout
    }

    /// Tone Studio's 20 ms spacing with a 3 s read timeout (design spec, sections 3.3 and 8).
    public static let katana = SessionTiming(spacing: .milliseconds(20), readTimeout: .seconds(3))
}

/// A conversation with the amp over a `MIDITransport`.
///
/// Messages go out one at a time and at least `timing.spacing` apart, Panic first, then decreases, then the rest. A read
/// waits for its reply without holding up other messages; one read waits at a time. After `readLivePatch(_:)` the
/// session keeps a copy of the live patch that follows every change the amp reports. Writing is internal to KatanaKit:
/// the app writes through `SafetyGuard`.
public actor AmpSession {
    /// Largest number of bytes one RQ1 asks for (Tone Studio's `SYSEX_MAXLEN`).
    public static let maxReadSize = 128
    /// How long a reply may arrive after its read has timed out and still count as a reply.
    static let lateReplyWindow = Duration.seconds(10)
    /// How long after a channel change the amp's reports count as its dump of the new channel, not as edits; a select
    /// waits as long for the dump before it reads the channel instead.
    static let dumpTime = Duration.seconds(2)
    /// How long the amp must have sent nothing before a select ends: the amp ignores messages, a select included, until
    /// it has sent the last of its dump and reports, whose gaps were at most 58 ms (hardware check 4).
    static let dumpQuiet = Duration.milliseconds(100)

    /// Changes made on the amp itself, reported while connected.
    public nonisolated let changes: AsyncStream<AmpChange>
    /// Every change of the copy of the live patch, and channel switches.
    public nonisolated let updates: AsyncStream<LiveUpdate>
    /// Message spacing and read timeout.
    nonisolated let timing: SessionTiming
    /// The selected channel (0 = PANEL, 1–8 = A1–B4), once read or reported by the amp.
    public private(set) var currentChannel: Int?
    private let changesContinuation: AsyncStream<AmpChange>.Continuation
    private let updatesContinuation: AsyncStream<LiveUpdate>.Continuation
    private var livePatch: [UInt8]?
    private var patchSize: Int?
    // A save that waits for the amp's confirmation.
    private var saveWaiter: (id: Int, continuation: CheckedContinuation<Void, any Error>)?
    private var saveCount = 0
    // A select that waits for the amp's channel number and its dump of the new patch, and the channel the amp has
    // reported since the select went out.
    private var dumpWaiter: (id: Int, slot: Int, continuation: CheckedContinuation<Bool, Never>)?
    private var dumpWaitCount = 0
    private var reportedChannel: Int?
    private var dumpQuietTask: Task<Void, Never>?
    // The bytes of the patch's blocks, and those the amp has not reported since its last channel change. The copy is
    // valid once it has been read and none is left.
    private var blockBytes: [Range<Int>] = []
    private var uncovered: Set<Int> = []
    // Per byte of the live patch: how often the amp reported a change of it, the last byte it reported, and when.
    private var ampReportCounts: [Int: Int] = [:]
    private var ampReportBytes: [Int: UInt8] = [:]
    private var ampReportTimes: [Int: ContinuousClock.Instant] = [:]
    // Per byte of the live patch: the number of Tanto's last write to it, so that a read reply never undoes a write
    // sent after the read.
    private var localWrites: [Int: Int] = [:]
    private var writeCount = 0
    private var generation = 0
    private var channelChangeTime: ContinuousClock.Instant?
    private var panics = 0
    private var editorMode = false
    private var pendingPanic: Parameter?
    private let transport: any MIDITransport
    private let clock = ContinuousClock()
    private let logger = Logger(subsystem: "io.github.pwhofman.tanto", category: "midi")
    private var deviceID = SysEx.defaultDeviceID
    private var lastSend: ContinuousClock.Instant?
    private var sending = false
    private var sendWaiters: [Waiter] = []
    private var reading = false
    private var readWaiters: [CheckedContinuation<Void, Never>] = []
    private var pending: Pending?
    private var outstanding: [Outstanding] = []
    private var requestCount = 0
    private var listener: Task<Void, Never>?

    private enum Expected: Equatable {
        case identityReply
        case data(Address, Int)
    }

    private struct Reply {
        let data: [UInt8]
        // Tanto's write count when the request went out.
        let writes: Int
    }

    private struct Pending {
        let id: Int
        let expected: Expected
        let continuation: CheckedContinuation<Reply, any Error>
        let timeout: Task<Void, Never>
    }

    // An RQ1 that went out and has not been answered yet; the amp answers in order.
    private struct Outstanding {
        let id: Int
        let expected: Expected
        let writes: Int
        let time: ContinuousClock.Instant
    }

    private struct NoReply: Error {}

    private struct Waiter {
        let priority: WritePriority
        let continuation: CheckedContinuation<Void, Never>
    }

    /// Creates a session; nothing is sent until `connect()` or `read(_:size:)` is called.
    ///
    /// - Parameters:
    ///   - transport: Connection to the amp.
    ///   - timing: Message spacing and read timeout.
    public init(transport: any MIDITransport, timing: SessionTiming = .katana) {
        self.transport = transport
        self.timing = timing
        (changes, changesContinuation) = AsyncStream.makeStream(of: AmpChange.self)
        (updates, updatesContinuation) = AsyncStream.makeStream(of: LiveUpdate.self)
    }

    deinit {
        listener?.cancel()
        changesContinuation.finish()
        updatesContinuation.finish()
    }

    /// Runs Tone Studio's connect sequence: identity request, editor communication level, editor mode on. Like Tone
    /// Studio, all later messages use the device ID from the identity reply, and a level other than 8 stops the
    /// sequence before editor mode is switched on. A Panic asked for meanwhile goes out right after editor mode is on.
    /// The copy of the live patch starts empty.
    ///
    /// - Returns: What the amp reported.
    /// - Throws: `AmpError` if the amp does not answer, is not a Katana MkII or uses another communication level.
    public func connect() async throws -> ConnectionInfo {
        startListening()
        forgetLivePatch()
        editorMode = false
        let identity = try await request(SysEx.identityRequest, expecting: .identityReply).data
        guard SysEx.isKatanaIdentityReply(identity) else { throw AmpError.notAKatana(identity) }
        deviceID = identity[2]
        let level = try await read(.editorCommunicationLevel, size: 1)[0]
        guard level == 8 else { throw AmpError.unsupportedCommunicationLevel(level) }
        try await sendCommand(SysEx.dt1(.editorCommunicationMode, data: [1], deviceID: deviceID))
        editorMode = true
        if let volumeKnob = pendingPanic {
            pendingPanic = nil
            try await sendPanic(volumeKnob)
        }
        return ConnectionInfo(identityReply: identity, communicationLevel: level)
    }

    /// Switches editor mode off.
    ///
    /// - Throws: An error from the transport.
    public func disconnect() async throws {
        editorMode = false
        try await sendCommand(SysEx.dt1(.editorCommunicationMode, data: [0], deviceID: deviceID))
    }

    /// Reads `size` bytes starting at `address`, in requests of at most `maxReadSize` bytes.
    ///
    /// - Parameters:
    ///   - address: First address.
    ///   - size: Number of bytes, at least 1.
    /// - Returns: The bytes.
    /// - Throws: `AmpError.timeout` if a request gets no reply, also not after one retry.
    public func read(_ address: Address, size: Int) async throws -> [UInt8] {
        precondition(size > 0, "read at least one byte")
        startListening()
        var data: [UInt8] = []
        while data.count < size {
            let start = address.advanced(by: data.count)
            let count = min(Self.maxReadSize, size - data.count)
            data += try await request(
                SysEx.rq1(start, size: count, deviceID: deviceID), expecting: .data(start, count)
            ).data
        }
        return data
    }

    /// Reads the whole live patch, block by block, into the copy that later changes apply to. Each reply goes into the
    /// copy as it arrives, except bytes Tanto wrote after asking for it, so a read never undoes a newer change.
    ///
    /// - Parameter map: The patch layout.
    /// - Throws: `AmpError.timeout` if a read gets no reply.
    public func readLivePatch(_ map: ParameterMap) async throws {
        patchSize = map.patchSize
        if livePatch == nil {
            livePatch = [UInt8](repeating: 0, count: map.patchSize)
            blockBytes = map.table.blocks.map { $0.offset..<($0.offset + $0.size) }
            uncovered = Set(blockBytes.joined())
        }
        for block in map.table.blocks {
            try await readIntoCopy(offset: block.offset, size: block.size)
        }
        if let livePatch {
            updatesContinuation.yield(.bytes(offset: 0, data: livePatch))
        }
    }

    /// A parameter read back from the amp, with the state of the session when the reply arrived.
    struct Refreshed: Sendable {
        /// The value the amp held.
        let value: Int
        /// How often the amp had reported a change of the parameter.
        let reportCount: Int
        /// The value the amp reported last.
        let reportedValue: Int?
        /// The channel generation.
        let generation: Int
        /// The Panic count.
        let panics: Int
    }

    /// Reads one parameter from the amp into the copy, as `readLivePatch(_:)` does for the whole patch.
    ///
    /// - Parameter parameter: A numeric parameter.
    /// - Returns: The value the amp held, with the state of the session when the reply arrived.
    /// - Throws: `AmpError.timeout` if the read gets no reply.
    func refresh(_ parameter: Parameter) async throws -> Refreshed {
        let range = parameter.offset..<(parameter.offset + parameter.encoding.byteCount)
        let data = try await readIntoCopy(offset: range.lowerBound, size: range.count)
        if let livePatch {
            updatesContinuation.yield(.bytes(offset: range.lowerBound, data: Array(livePatch[range])))
        }
        let reports = ampReports(for: parameter)
        return Refreshed(
            value: parameter.value(fromRaw: parameter.encoding.decode(data)), reportCount: reports.count,
            reportedValue: reports.value, generation: generation, panics: panics)
    }

    /// Selects a channel by writing its number, as Tone Studio's channel list does. The amp answers with its channel
    /// number and a dump of the new patch, in about 0.3 s, and ignores messages until it has sent the last of them
    /// (hardware checks 3 and 4), so the select waits for them and then for `dumpQuiet` without a message; only if they
    /// have not come within `dumpTime` does it read the channel number and the live patch back. Everything decided on the
    /// old channel is dropped before the write goes out: the copy of the live patch is invalid until the new patch has
    /// arrived.
    ///
    /// - Parameter slot: 0 = PANEL, 1–4 = A1–A4, 5–8 = B1–B4.
    /// - Throws: `WriteError.noSuchChannel`; `AmpError.timeout` if a read gets no reply; an error from the transport.
    func select(_ slot: Int) async throws {
        guard (0...8).contains(slot) else { throw WriteError.noSuchChannel(slot) }
        generation += 1
        uncovered = Set(blockBytes.joined())
        try await sendCommand(SysEx.dt1(.currentPatchNumber, data: [0, UInt8(slot)], deviceID: deviceID))
        if await !dumpArrives(for: slot, within: Self.dumpTime) {
            let reported = reportedChannel.map { "channel \($0)" } ?? "no channel"
            let missing = uncovered.count
            let channel = try await readCurrentChannel()
            logger.notice(
                "no dump after selecting channel \(slot): the amp reported \(reported, privacy: .public) and left \(missing) bytes out; it is on channel \(channel)"
            )
            updatesContinuation.yield(.channel(channel))
            for range in blockBytes {
                try await readIntoCopy(offset: range.lowerBound, size: range.count)
            }
        }
        if let livePatch {
            updatesContinuation.yield(.bytes(offset: 0, data: livePatch))
        }
    }

    /// Saves the live patch to a channel with Tone Studio's WRITE command, and waits for the amp's confirmation.
    ///
    /// - Parameters:
    ///   - slot: 1–4 = A1–A4, 5–8 = B1–B4.
    ///   - timeout: How long to wait for the confirmation (design spec, section 8: 15 s).
    /// - Throws: `WriteError.noSuchChannel`; `AmpError.noSaveConfirmation`; an error from the transport.
    func savePatch(to slot: Int, timeout: Duration = .seconds(15)) async throws {
        guard (1...8).contains(slot) else { throw WriteError.noSuchChannel(slot) }
        try await sendCommand(SysEx.dt1(.patchWrite, data: [0, UInt8(slot)], deviceID: deviceID))
        saveCount += 1
        let id = saveCount
        // The confirmation is handled on this actor, so it cannot arrive before the waiter is in place.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            saveWaiter = (id, continuation)
            Task { [clock] in
                do {
                    try await clock.sleep(for: timeout)
                } catch {
                    return  // cancelled: never happens
                }
                self.expireSave(id, slot: slot)
            }
        }
    }

    /// Writes bytes straight into a stored channel, as Tone Studio's restore does.
    ///
    /// - Parameters:
    ///   - data: 1 to 128 bytes, each below `0x80`.
    ///   - slot: 1–4 = A1–A4, 5–8 = B1–B4.
    ///   - offset: Linear offset inside the patch.
    /// - Throws: `WriteError.noSuchChannel` or `.outsideChannel`; an error from the transport.
    func writeStored(_ data: [UInt8], slot: Int, offset: Int) async throws {
        guard (1...8).contains(slot) else { throw WriteError.noSuchChannel(slot) }
        guard let patchSize, offset >= 0, (1...Self.maxReadSize).contains(data.count),
            offset + data.count <= patchSize, data.allSatisfy({ $0 < 0x80 })
        else {
            throw WriteError.outsideChannel(offset: offset, count: data.count)
        }
        try await sendCommand(SysEx.dt1(Address.userPatch(slot).advanced(by: offset), data: data, deviceID: deviceID))
    }

    /// Reads the selected channel.
    ///
    /// - Returns: 0 for PANEL, 1–8 for A1–B4.
    /// - Throws: `AmpError.timeout` if the read gets no reply.
    public func readCurrentChannel() async throws -> Int {
        let channel = ValueEncoding.int2x7.decode(try await read(.currentPatchNumber, size: 2))
        currentChannel = channel
        return channel
    }

    /// Writes a displayed value to the live patch and to the copy of it.
    ///
    /// - Parameters:
    ///   - value: The displayed value.
    ///   - parameter: A parameter that a Tone Studio control writes.
    ///   - priority: The lane to wait in.
    ///   - basis: What the write was decided on; `nil` to send it whatever happens meanwhile.
    /// - Returns: `false` if the write was dropped because its basis no longer held.
    /// - Throws: `WriteError` if the parameter or value is not allowed; an error from the transport.
    @discardableResult
    func write(_ value: Int, to parameter: Parameter, priority: WritePriority = .normal, basis: WriteBasis? = nil)
        async throws -> Bool
    {
        guard parameter.written, parameter.encoding != .ascii16 else { throw WriteError.notWritable(parameter.prm) }
        let raw = value + parameter.rawOffset
        let rawLimit = parameter.encoding == .int1x7 ? 128 : 16384
        guard (parameter.minimum...parameter.maximum).contains(value), (0..<rawLimit).contains(raw) else {
            throw WriteError.outOfRange(parameter.prm, value)
        }
        let address = Address.temporaryPatch.advanced(by: parameter.offset)
        let data = parameter.encoding.encode(raw)
        guard
            try await sendCommand(SysEx.dt1(address, data: data, deviceID: deviceID), priority: priority, basis: basis)
        else {
            return false
        }
        applyLocalWrite(address, data)
        return true
    }

    /// Writes the name of the live patch, as Tone Studio's WRITE dialog does.
    ///
    /// - Parameter name: At most 16 characters from space to `}`.
    /// - Throws: `WriteError.invalidName`; an error from the transport.
    func writeLiveName(_ name: String) async throws {
        let bytes = Array(name.utf8)
        guard bytes.count <= PatchName.length, bytes.allSatisfy({ (0x20...0x7D).contains($0) }) else {
            throw WriteError.invalidName(name)
        }
        let padded = bytes + Array(repeating: 0x20, count: PatchName.length - bytes.count)
        try await sendCommand(SysEx.dt1(.temporaryPatch, data: padded, deviceID: deviceID))
        applyLocalWrite(.temporaryPatch, padded)
    }

    /// Presses a front-panel button as Tone Studio does, with a DT1 of `00` to its address. The amp does what its own
    /// button does and reports what changed.
    ///
    /// - Parameters:
    ///   - button: The button.
    ///   - priority: The lane to wait in.
    ///   - basis: What the press was decided on; `nil` to send it whatever happens meanwhile.
    /// - Returns: `false` if the press was dropped because its basis no longer held.
    /// - Throws: An error from the transport.
    @discardableResult
    func press(_ button: PanelButton, priority: WritePriority = .normal, basis: WriteBasis? = nil) async throws -> Bool
    {
        try await sendCommand(
            SysEx.dt1(button.address, data: [0], deviceID: deviceID), priority: priority, basis: basis)
    }

    /// Taps a TAP button: the amp sets the delay time from the interval between taps.
    ///
    /// - Parameter button: The TAP button.
    /// - Returns: `false` if the tap was dropped.
    /// - Throws: An error from the transport.
    @discardableResult
    func tap(_ button: TapButton) async throws -> Bool {
        try await sendCommand(SysEx.dt1(button.address, data: [0], deviceID: deviceID))
    }

    /// Panic: the VOLUME knob to 0 as the next message, ahead of everything queued and of a read that waits for its
    /// reply. No write decided before is sent afterwards. While connecting, VOLUME 0 goes out as soon as editor mode is
    /// on (design spec, section 5.5).
    ///
    /// - Parameter volumeKnob: The VOLUME knob of the parameter table.
    /// - Returns: The number of the amp's reports about VOLUME when VOLUME 0 went out, or `nil` if it waits for editor
    ///   mode.
    /// - Throws: An error from the transport.
    @discardableResult
    func panic(volumeKnob: Parameter) async throws -> Int? {
        panics += 1
        guard editorMode else {
            pendingPanic = volumeKnob
            return nil
        }
        try await sendPanic(volumeKnob)
        return ampReports(for: volumeKnob).count
    }

    /// Drops every write decided so far: none of them is sent. Used when a `SafetyGuard` stops.
    func invalidateWrites() {
        panics += 1
    }

    /// The displayed value of a parameter in the copy of the live patch.
    ///
    /// - Parameter parameter: A numeric parameter.
    /// - Returns: The value, or `nil` before `readLivePatch(_:)` and for the patch name.
    public func liveValue(of parameter: Parameter) -> Int? {
        let end = parameter.offset + parameter.encoding.byteCount
        guard let livePatch, parameter.encoding != .ascii16, end <= livePatch.count else { return nil }
        return parameter.value(fromRaw: parameter.encoding.decode(livePatch[parameter.offset..<end]))
    }

    /// Whether the copy of the live patch is complete: read, and after a channel change on the amp covered again by
    /// the amp's dump of the new patch.
    public var isLivePatchValid: Bool {
        livePatch != nil && uncovered.isEmpty
    }

    /// How often the amp has reported a change of any byte of a parameter, and the value it reported last.
    ///
    /// - Parameter parameter: A numeric parameter.
    /// - Returns: The number of reports, and the last reported value if the amp reported all of its bytes.
    func ampReports(for parameter: Parameter) -> (count: Int, value: Int?) {
        let offsets = parameter.offset..<(parameter.offset + parameter.encoding.byteCount)
        let count = offsets.reduce(0) { $0 + ampReportCounts[$1, default: 0] }
        let bytes = offsets.compactMap { ampReportBytes[$0] }
        guard parameter.encoding != .ascii16, bytes.count == offsets.count else { return (count, nil) }
        return (count, parameter.value(fromRaw: parameter.encoding.decode(bytes)))
    }

    /// What `SafetyGuard` needs to know about a parameter.
    struct GuardView: Sendable {
        /// The value in the copy of the live patch.
        let value: Int?
        /// How often the amp has reported a change of the parameter.
        let reportCount: Int
        /// The value the amp reported last.
        let reportedValue: Int?
        /// When the amp's last report about the parameter arrived.
        let reportTime: ContinuousClock.Instant?
    }

    /// What `SafetyGuard` needs to decide, read in one step.
    struct GuardSnapshot: Sendable {
        /// Raised by every channel change made on the amp and by connecting.
        let generation: Int
        /// Raised by every Panic.
        let panics: Int
        /// Whether the copy of the live patch is complete (`isLivePatchValid`).
        let isValid: Bool
        /// The selected channel.
        let channel: Int?
        /// When the amp reported its last channel change.
        let channelChangeTime: ContinuousClock.Instant?
        /// A view per parameter offset.
        let views: [Int: GuardView]

        /// The basis of a write decided on this snapshot.
        ///
        /// - Parameter parameters: The parameters whose amp reports the write depends on.
        /// - Returns: The basis.
        func basis(_ parameters: [Parameter]) -> WriteBasis {
            WriteBasis(
                generation: generation, panics: panics,
                reportCounts: Dictionary(
                    parameters.map { ($0, views[$0.offset]?.reportCount ?? 0) }, uniquingKeysWith: { first, _ in first }
                ))
        }
    }

    /// The state of the session and of several parameters, read in one step.
    ///
    /// - Parameter parameters: Numeric parameters.
    /// - Returns: The snapshot.
    func guardSnapshot(of parameters: [Parameter]) -> GuardSnapshot {
        var views: [Int: GuardView] = [:]
        for parameter in parameters {
            let reports = ampReports(for: parameter)
            let offsets = parameter.offset..<(parameter.offset + parameter.encoding.byteCount)
            views[parameter.offset] = GuardView(
                value: liveValue(of: parameter), reportCount: reports.count, reportedValue: reports.value,
                reportTime: offsets.compactMap { ampReportTimes[$0] }.max())
        }
        return GuardSnapshot(
            generation: generation, panics: panics, isValid: isLivePatchValid, channel: currentChannel,
            channelChangeTime: channelChangeTime, views: views)
    }

    /// The name in the copy of the live patch.
    ///
    /// - Returns: The name, or `nil` before `readLivePatch(_:)`.
    public func liveName() -> String? {
        livePatch.map { PatchName.decode($0[0..<16]) }
    }

    // Connecting starts from scratch: no copy, no reports, and no write decided before goes out.
    private func forgetLivePatch() {
        livePatch = nil
        uncovered = []
        ampReportCounts = [:]
        ampReportBytes = [:]
        ampReportTimes = [:]
        localWrites = [:]
        generation += 1
        channelChangeTime = nil
    }

    private func sendPanic(_ volumeKnob: Parameter) async throws {
        let address = Address.temporaryPatch.advanced(by: volumeKnob.offset)
        let data = volumeKnob.encoding.encode(volumeKnob.rawOffset)
        try await sendCommand(SysEx.dt1(address, data: data, deviceID: deviceID), priority: .panic)
        applyLocalWrite(address, data)
    }

    // Reads part of the live patch into the copy, as `readLivePatch(_:)` describes.
    @discardableResult
    private func readIntoCopy(offset: Int, size: Int) async throws -> [UInt8] {
        var data: [UInt8] = []
        while data.count < size {
            let start = offset + data.count
            let count = min(Self.maxReadSize, size - data.count)
            let address = Address.temporaryPatch.advanced(by: start)
            let reply = try await request(
                SysEx.rq1(address, size: count, deviceID: deviceID), expecting: .data(address, count))
            applyReadReply(at: start, reply.data, writesBefore: reply.writes)
            data += reply.data
        }
        return data
    }

    private func applyReadReply(at offset: Int, _ data: [UInt8], writesBefore writes: Int) {
        guard var patch = livePatch, offset >= 0 else { return }
        for (index, byte) in data.enumerated() where offset + index < patch.count {
            let position = offset + index
            uncovered.remove(position)
            if localWrites[position, default: 0] <= writes {
                patch[position] = byte
            }
        }
        livePatch = patch
    }

    private func applyLocalWrite(_ address: Address, _ data: [UInt8]) {
        writeCount += 1
        let offset = address.linear - Address.temporaryPatch.linear
        for index in data.indices {
            localWrites[offset + index] = writeCount
        }
        applyToLivePatch(address, data)
    }

    private func applyToLivePatch(_ address: Address, _ data: [UInt8], fromAmp: Bool = false) {
        if address == .currentPatchNumber, data.count == 2 {
            let channel = ValueEncoding.int2x7.decode(data)
            currentChannel = channel
            if fromAmp {
                // The amp loaded another patch: the copy is stale until the amp's dump has covered it.
                generation += 1
                channelChangeTime = clock.now
                uncovered = Set(blockBytes.joined())
                reportedChannel = channel
            }
            updatesContinuation.yield(.channel(channel))
            return
        }
        let offset = address.linear - Address.temporaryPatch.linear
        guard var patch = livePatch, offset >= 0, offset < patch.count else { return }
        // The amp's dump after a channel switch runs a few bytes past the last block.
        let count = min(data.count, patch.count - offset)
        if fromAmp {
            let now = clock.now
            for (index, byte) in data.prefix(count).enumerated() {
                ampReportCounts[offset + index, default: 0] += 1
                ampReportBytes[offset + index] = byte
                ampReportTimes[offset + index] = now
                uncovered.remove(offset + index)
            }
        }
        patch.replaceSubrange(offset..<(offset + count), with: data.prefix(count))
        livePatch = patch
        updatesContinuation.yield(.bytes(offset: offset, data: Array(data.prefix(count))))
        // The amp's dump follows its channel number within a second (hardware check 3).
        if fromAmp, channelChangeTime.map({ clock.now - $0 > Self.dumpTime }) ?? true {
            updatesContinuation.yield(.editedOnAmp)
        }
    }

    private func startListening() {
        guard listener == nil else { return }
        let incoming = transport.incoming
        listener = Task { [weak self] in
            for await message in incoming {
                await self?.handle(message)
            }
        }
    }

    private func handle(_ message: [UInt8]) {
        switch IncomingMessage(message) {
        case .identityReply(let reply):
            if let pending, pending.expected == .identityReply {
                resolve(pending, with: Reply(data: reply, writes: writeCount))
            }
        case .dataSet(let address, let data) where address == .patchWrite:
            if let saveWaiter {
                self.saveWaiter = nil
                saveWaiter.continuation.resume()
            } else {
                let slot = data.count == 2 ? ValueEncoding.int2x7.decode(data) : nil
                updatesContinuation.yield(.patchSaved(slot.flatMap { (1...8).contains($0) ? $0 : nil }))
            }
        case .dataSet(let address, let data):
            outstanding.removeAll { clock.now - $0.time > Self.lateReplyWindow }
            if let index = outstanding.firstIndex(where: { $0.expected == .data(address, data.count) }) {
                // A reply. The amp answers in order, so requests before this one went unanswered.
                let request = outstanding[index]
                outstanding.removeFirst(index + 1)
                if let pending, pending.expected == request.expected {
                    resolve(pending, with: Reply(data: data, writes: request.writes))
                } else {
                    logger.notice("late reply for \(address, privacy: .public); kept as a read, not as a change")
                    applyReadReply(
                        at: address.linear - Address.temporaryPatch.linear, data, writesBefore: request.writes)
                }
            } else {
                changesContinuation.yield(AmpChange(address: address, data: data))
                applyToLivePatch(address, data, fromAmp: true)
                checkDumpWaiter()
            }
        case .malformed(let bytes):
            logger.error("dropped malformed message of \(bytes.count) bytes")
        case .other(let bytes):
            logger.debug("ignored message starting with \(bytes.first ?? 0, format: .hex)")
        }
    }

    private func resolve(_ pending: Pending, with reply: Reply) {
        self.pending = nil
        pending.timeout.cancel()
        pending.continuation.resume(returning: reply)
    }

    private func request(_ message: [UInt8], expecting expected: Expected) async throws -> Reply {
        do {
            return try await requestOnce(message, expecting: expected)
        } catch is NoReply {
            logger.notice("no reply, retrying once")
        }
        do {
            return try await requestOnce(message, expecting: expected)
        } catch is NoReply {
            switch expected {
            case .identityReply: throw AmpError.noIdentityReply
            case .data(let address, _): throw AmpError.timeout(address)
            }
        }
    }

    // One read waits for its reply at a time. It holds the send slot only while its request goes out, so Panic and
    // writes do not wait for the reply.
    private func requestOnce(_ message: [UInt8], expecting expected: Expected) async throws -> Reply {
        await acquireRead()
        defer { releaseRead() }
        await acquireSend(.normal)
        do {
            try await waitForSlot()
        } catch {
            releaseSend()
            throw error
        }
        requestCount += 1
        let id = requestCount
        return try await withCheckedThrowingContinuation { continuation in
            let timeout = Task { [clock, readTimeout = timing.readTimeout] in
                do {
                    try await clock.sleep(for: readTimeout)
                } catch {
                    return  // cancelled: the reply arrived
                }
                self.expire(id)
            }
            pending = Pending(id: id, expected: expected, continuation: continuation, timeout: timeout)
            do {
                try transport.send(message)
                lastSend = clock.now
                if case .data = expected {
                    outstanding.append(Outstanding(id: id, expected: expected, writes: writeCount, time: clock.now))
                }
            } catch {
                pending = nil
                timeout.cancel()
                continuation.resume(throwing: error)
            }
            releaseSend()
        }
    }

    // Waits until the amp has reported `slot`, its dump has covered the copy and it has sent nothing for `dumpQuiet`, or
    // until `timeout` has passed. It starts right after the select went out, with no pause in between, so only the amp's
    // answer to it counts.
    private func dumpArrives(for slot: Int, within timeout: Duration) async -> Bool {
        reportedChannel = nil
        dumpWaitCount += 1
        let id = dumpWaitCount
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            dumpWaiter = (id, slot, continuation)
            Task { [clock] in
                do {
                    try await clock.sleep(for: timeout)
                } catch {
                    return  // cancelled: never happens
                }
                self.endDumpWait(id, dumped: false)
            }
        }
    }

    // Runs after every message from the amp, also one past the copy: each restarts the wait for quiet, which begins
    // once the amp has reported the selected channel and its dump has covered the copy.
    private func checkDumpWaiter() {
        dumpQuietTask?.cancel()
        guard let dumpWaiter, reportedChannel == dumpWaiter.slot, uncovered.isEmpty else { return }
        dumpQuietTask = Task { [clock] in
            do {
                try await clock.sleep(for: Self.dumpQuiet)
            } catch {
                return  // cancelled: the amp sent another message
            }
            self.endDumpWait(dumpWaiter.id, dumped: true)
        }
    }

    private func endDumpWait(_ id: Int, dumped: Bool) {
        guard let dumpWaiter, dumpWaiter.id == id else { return }
        self.dumpWaiter = nil
        dumpQuietTask?.cancel()
        dumpQuietTask = nil
        dumpWaiter.continuation.resume(returning: dumped)
    }

    private func expireSave(_ id: Int, slot: Int) {
        guard let saveWaiter, saveWaiter.id == id else { return }
        self.saveWaiter = nil
        saveWaiter.continuation.resume(throwing: AmpError.noSaveConfirmation(slot))
    }

    private func expire(_ id: Int) {
        guard let pending, pending.id == id else { return }
        self.pending = nil
        pending.continuation.resume(throwing: NoReply())
    }

    @discardableResult
    private func sendCommand(_ message: [UInt8], priority: WritePriority = .normal, basis: WriteBasis? = nil)
        async throws -> Bool
    {
        await acquireSend(priority)
        defer { releaseSend() }
        try await waitForSlot()
        // No message from the amp can be handled between this check and the send: both run on this actor without a
        // pause.
        if let basis, !holds(basis) {
            return false
        }
        try transport.send(message)
        lastSend = clock.now
        return true
    }

    private func holds(_ basis: WriteBasis) -> Bool {
        basis.generation == generation && basis.panics == panics
            && basis.reportCounts.allSatisfy { ampReports(for: $0.key).count == $0.value }
    }

    private func waitForSlot() async throws {
        if let lastSend {
            try await clock.sleep(until: lastSend.advanced(by: timing.spacing))
        }
    }

    private func acquireSend(_ priority: WritePriority) async {
        if !sending {
            sending = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let index = sendWaiters.firstIndex { $0.priority < priority } ?? sendWaiters.endIndex
            sendWaiters.insert(Waiter(priority: priority, continuation: continuation), at: index)
        }
    }

    private func releaseSend() {
        if sendWaiters.isEmpty {
            sending = false
        } else {
            sendWaiters.removeFirst().continuation.resume()
        }
    }

    private func acquireRead() async {
        if !reading {
            reading = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            readWaiters.append(continuation)
        }
    }

    private func releaseRead() {
        if readWaiters.isEmpty {
            reading = false
        } else {
            readWaiters.removeFirst().resume()
        }
    }
}
