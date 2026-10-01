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
}

/// Reasons a write is refused before anything is sent.
public enum WriteError: Error, Equatable, Sendable {
    /// No Tone Studio control writes this parameter, so Tanto does not either (design spec, section 3.5).
    case notWritable(String)
    /// The value lies outside the parameter's range.
    case outOfRange(String, Int)
    /// A patch name must be at most 16 characters from space to `}`.
    case invalidName(String)
}

/// Whether an outgoing message waits its turn or goes next.
enum WritePriority {
    /// After everything already queued.
    case normal
    /// Before all queued normal messages; used for decreases and Panic (design spec, section 5.2).
    case high
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
/// Messages go out one at a time and at least `timing.spacing` apart. After `readLivePatch(_:)` the session keeps a
/// copy of the live patch that follows every change the amp reports. Writing is internal to KatanaKit: the app writes
/// through `SafetyGuard`.
public actor AmpSession {
    /// Largest number of bytes one RQ1 asks for (Tone Studio's `SYSEX_MAXLEN`).
    public static let maxReadSize = 128

    /// Changes made on the amp itself, reported while connected.
    public nonisolated let changes: AsyncStream<AmpChange>
    /// Every change of the copy of the live patch, and channel switches.
    public nonisolated let updates: AsyncStream<LiveUpdate>
    /// The selected channel (0 = PANEL, 1–8 = A1–B4), once read or reported by the amp.
    public private(set) var currentChannel: Int?
    private let changesContinuation: AsyncStream<AmpChange>.Continuation
    private let updatesContinuation: AsyncStream<LiveUpdate>.Continuation
    private var livePatch: [UInt8]?
    // Per byte of the live patch: how often the amp reported a change of it, and the last byte it reported.
    private var ampReportCounts: [Int: Int] = [:]
    private var ampReportBytes: [Int: UInt8] = [:]
    private let transport: any MIDITransport
    private let timing: SessionTiming
    private let clock = ContinuousClock()
    private let logger = Logger(subsystem: "io.github.pwhofman.tanto", category: "midi")
    private var deviceID = SysEx.defaultDeviceID
    private var lastSend: ContinuousClock.Instant?
    private var busy = false
    private var waiters: [Waiter] = []
    private var pending: Pending?
    private var requestCount = 0
    private var listener: Task<Void, Never>?

    private enum Expected: Equatable {
        case identityReply
        case data(Address, Int)
    }

    private struct Pending {
        let id: Int
        let expected: Expected
        let continuation: CheckedContinuation<[UInt8], any Error>
        let timeout: Task<Void, Never>
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
    /// sequence before editor mode is switched on.
    ///
    /// - Returns: What the amp reported.
    /// - Throws: `AmpError` if the amp does not answer, is not a Katana MkII or uses another communication level.
    public func connect() async throws -> ConnectionInfo {
        startListening()
        let identity = try await request(SysEx.identityRequest, expecting: .identityReply)
        guard SysEx.isKatanaIdentityReply(identity) else { throw AmpError.notAKatana(identity) }
        deviceID = identity[2]
        let level = try await read(.editorCommunicationLevel, size: 1)[0]
        guard level == 8 else { throw AmpError.unsupportedCommunicationLevel(level) }
        try await sendCommand(SysEx.dt1(.editorCommunicationMode, data: [1], deviceID: deviceID))
        return ConnectionInfo(identityReply: identity, communicationLevel: level)
    }

    /// Switches editor mode off.
    ///
    /// - Throws: An error from the transport.
    public func disconnect() async throws {
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
                SysEx.rq1(start, size: count, deviceID: deviceID), expecting: .data(start, count))
        }
        return data
    }

    /// Reads the whole live patch, block by block, and keeps it as the copy that later changes apply to.
    ///
    /// - Parameter map: The patch layout.
    /// - Throws: `AmpError.timeout` if a read gets no reply.
    public func readLivePatch(_ map: ParameterMap) async throws {
        var patch = [UInt8](repeating: 0, count: map.patchSize)
        for block in map.table.blocks {
            let data = try await read(.temporaryPatch.advanced(by: block.offset), size: block.size)
            patch.replaceSubrange(block.offset..<(block.offset + block.size), with: data)
        }
        livePatch = patch
        updatesContinuation.yield(.bytes(offset: 0, data: patch))
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
    ///   - priority: `.high` to go before queued messages.
    /// - Throws: `WriteError` if the parameter or value is not allowed; an error from the transport.
    func write(_ value: Int, to parameter: Parameter, priority: WritePriority = .normal) async throws {
        guard parameter.written, parameter.encoding != .ascii16 else { throw WriteError.notWritable(parameter.prm) }
        let raw = value + parameter.rawOffset
        let rawLimit = parameter.encoding == .int1x7 ? 128 : 16384
        guard (parameter.minimum...parameter.maximum).contains(value), (0..<rawLimit).contains(raw) else {
            throw WriteError.outOfRange(parameter.prm, value)
        }
        let address = Address.temporaryPatch.advanced(by: parameter.offset)
        let data = parameter.encoding.encode(raw)
        try await sendCommand(SysEx.dt1(address, data: data, deviceID: deviceID), priority: priority)
        applyToLivePatch(address, data)
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
        applyToLivePatch(.temporaryPatch, padded)
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

    /// How often the amp has reported a change of a parameter, and the value it reported last. A change of the count
    /// tells `SafetyGuard` that a knob or a channel switch took over, even if a write of its own crossed the report.
    ///
    /// - Parameter parameter: A numeric parameter.
    /// - Returns: The number of reports, and the last reported value if the amp reported all of its bytes.
    func ampReports(for parameter: Parameter) -> (count: Int, value: Int?) {
        let offsets = parameter.offset..<(parameter.offset + parameter.encoding.byteCount)
        let count = ampReportCounts[parameter.offset, default: 0]
        let bytes = offsets.compactMap { ampReportBytes[$0] }
        guard parameter.encoding != .ascii16, bytes.count == offsets.count else { return (count, nil) }
        return (count, parameter.value(fromRaw: parameter.encoding.decode(bytes)))
    }

    /// What `SafetyGuard` needs to know about a parameter, read in one step.
    struct GuardView: Sendable {
        /// The value in the copy of the live patch.
        let value: Int?
        /// How often the amp has reported a change of the parameter.
        let reportCount: Int
        /// The value the amp reported last.
        let reportedValue: Int?
    }

    /// The live values and amp reports of several parameters, read in one step.
    ///
    /// - Parameter parameters: Numeric parameters.
    /// - Returns: A view per parameter offset.
    func guardViews(of parameters: [Parameter]) -> [Int: GuardView] {
        var views: [Int: GuardView] = [:]
        for parameter in parameters {
            let reports = ampReports(for: parameter)
            views[parameter.offset] = GuardView(
                value: liveValue(of: parameter), reportCount: reports.count, reportedValue: reports.value)
        }
        return views
    }

    /// The name in the copy of the live patch.
    ///
    /// - Returns: The name, or `nil` before `readLivePatch(_:)`.
    public func liveName() -> String? {
        livePatch.map { PatchName.decode($0[0..<16]) }
    }

    private func applyToLivePatch(_ address: Address, _ data: [UInt8], fromAmp: Bool = false) {
        if address == .currentPatchNumber, data.count == 2 {
            let channel = ValueEncoding.int2x7.decode(data)
            currentChannel = channel
            updatesContinuation.yield(.channel(channel))
            return
        }
        let offset = address.linear - Address.temporaryPatch.linear
        guard var patch = livePatch, offset >= 0, offset < patch.count else { return }
        // The amp's dump after a channel switch runs a few bytes past the last block.
        let count = min(data.count, patch.count - offset)
        if fromAmp {
            for (index, byte) in data.prefix(count).enumerated() {
                ampReportCounts[offset + index, default: 0] += 1
                ampReportBytes[offset + index] = byte
            }
        }
        patch.replaceSubrange(offset..<(offset + count), with: data.prefix(count))
        livePatch = patch
        updatesContinuation.yield(.bytes(offset: offset, data: Array(data.prefix(count))))
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
                resolve(pending, with: reply)
            }
        case .dataSet(let address, let data):
            if let pending, pending.expected == .data(address, data.count) {
                resolve(pending, with: data)
            } else {
                changesContinuation.yield(AmpChange(address: address, data: data))
                applyToLivePatch(address, data, fromAmp: true)
            }
        case .malformed(let bytes):
            logger.error("dropped malformed message of \(bytes.count) bytes")
        case .other(let bytes):
            logger.debug("ignored message starting with \(bytes.first ?? 0, format: .hex)")
        }
    }

    private func resolve(_ pending: Pending, with data: [UInt8]) {
        self.pending = nil
        pending.timeout.cancel()
        pending.continuation.resume(returning: data)
    }

    private func request(_ message: [UInt8], expecting expected: Expected) async throws -> [UInt8] {
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

    private func requestOnce(_ message: [UInt8], expecting expected: Expected) async throws -> [UInt8] {
        await acquire()
        defer { release() }
        try await waitForSlot()
        requestCount += 1
        let id = requestCount
        return try await withCheckedThrowingContinuation { continuation in
            let timeout = Task { [clock, readTimeout = timing.readTimeout] in
                try? await clock.sleep(for: readTimeout)
                self.expire(id)
            }
            pending = Pending(id: id, expected: expected, continuation: continuation, timeout: timeout)
            do {
                try transport.send(message)
                lastSend = clock.now
            } catch {
                pending = nil
                timeout.cancel()
                continuation.resume(throwing: error)
            }
        }
    }

    private func expire(_ id: Int) {
        guard let pending, pending.id == id else { return }
        self.pending = nil
        pending.continuation.resume(throwing: NoReply())
    }

    private func sendCommand(_ message: [UInt8], priority: WritePriority = .normal) async throws {
        await acquire(priority)
        defer { release() }
        try await waitForSlot()
        try transport.send(message)
        lastSend = clock.now
    }

    private func waitForSlot() async throws {
        if let lastSend {
            try await clock.sleep(until: lastSend.advanced(by: timing.spacing))
        }
    }

    // One message is in flight at a time. Waiters are served first come, first served, except that high-priority
    // waiters go before all normal ones.
    private func acquire(_ priority: WritePriority = .normal) async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let waiter = Waiter(priority: priority, continuation: continuation)
            if priority == .high, let firstNormal = waiters.firstIndex(where: { $0.priority == .normal }) {
                waiters.insert(waiter, at: firstNormal)
            } else {
                waiters.append(waiter)
            }
        }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }
}
