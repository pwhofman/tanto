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
/// Messages go out one at a time and at least `timing.spacing` apart. This version reads and switches the
/// editor-communication mode; it has no way to write parameters.
public actor AmpSession {
    /// Largest number of bytes one RQ1 asks for (Tone Studio's `SYSEX_MAXLEN`).
    public static let maxReadSize = 128

    /// Changes made on the amp itself, reported while connected.
    public nonisolated let changes: AsyncStream<AmpChange>
    private let changesContinuation: AsyncStream<AmpChange>.Continuation
    private let transport: any MIDITransport
    private let timing: SessionTiming
    private let clock = ContinuousClock()
    private let logger = Logger(subsystem: "io.github.pwhofman.tanto", category: "midi")
    private var deviceID = SysEx.defaultDeviceID
    private var lastSend: ContinuousClock.Instant?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
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

    /// Creates a session; nothing is sent until `connect()` or `read(_:size:)` is called.
    ///
    /// - Parameters:
    ///   - transport: Connection to the amp.
    ///   - timing: Message spacing and read timeout.
    public init(transport: any MIDITransport, timing: SessionTiming = .katana) {
        self.transport = transport
        self.timing = timing
        (changes, changesContinuation) = AsyncStream.makeStream(of: AmpChange.self)
    }

    deinit {
        listener?.cancel()
        changesContinuation.finish()
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

    private func sendCommand(_ message: [UInt8]) async throws {
        await acquire()
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

    // A first-come, first-served lock: one message is in flight at a time.
    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
