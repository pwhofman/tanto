/// Wraps a transport and reports every message in both directions, e.g. to write a transcript.
public final class LoggingTransport: MIDITransport {
    /// Direction of a logged message.
    public enum Direction: Sendable {
        /// From Tanto to the amp.
        case sent
        /// From the amp to Tanto.
        case received
    }

    public let incoming: AsyncStream<[UInt8]>
    private let base: any MIDITransport
    private let log: @Sendable (Direction, [UInt8]) -> Void
    private let forwarder: Task<Void, Never>

    /// Wraps `base`.
    ///
    /// - Parameters:
    ///   - base: The transport that does the work.
    ///   - log: Called for every message; must be safe to call from any thread.
    public init(wrapping base: any MIDITransport, log: @escaping @Sendable (Direction, [UInt8]) -> Void) {
        let (stream, continuation) = AsyncStream.makeStream(of: [UInt8].self)
        incoming = stream
        self.base = base
        self.log = log
        forwarder = Task {
            for await message in base.incoming {
                log(.received, message)
                continuation.yield(message)
            }
            continuation.finish()
        }
    }

    deinit {
        forwarder.cancel()
    }

    public func send(_ message: [UInt8]) throws {
        log(.sent, message)
        try base.send(message)
    }
}
