import Foundation
import Synchronization

/// An in-memory Katana MkII for tests and for development while the amp is off.
///
/// It answers identity requests and RQ1 reads from its memory, stores DT1 writes, and records every message it
/// receives with its arrival time.
public final class SimulatedAmp: MIDITransport {
    /// A message the simulated amp received.
    public struct Received: Sendable {
        /// The message.
        public let message: [UInt8]
        /// When it arrived.
        public let time: ContinuousClock.Instant
    }

    /// The default reply to an identity request; passes Tone Studio's Katana MkII check.
    public static let katanaIdentityReply: [UInt8] = [
        0xF0, 0x7E, 0x10, 0x06, 0x02, 0x41, 0x33, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF7,
    ]

    public let incoming: AsyncStream<[UInt8]>
    private let continuation: AsyncStream<[UInt8]>.Continuation
    private let state: Mutex<State>

    private struct State {
        var memory: [Int: UInt8]
        var received: [Received] = []
        var answersReads = true
        let identityReply: [UInt8]
    }

    /// Creates a simulated amp whose nine stored patches and live patch hold the table's initial values.
    ///
    /// Stored patches are named `SIM PATCH 0` to `SIM PATCH 8`, the live patch `SIM LIVE`. The current channel is A1,
    /// the editor communication level 8 and the revision 1.
    ///
    /// - Parameters:
    ///   - map: Layout used to fill the patches.
    ///   - identityReply: Reply to identity requests.
    public init(map: ParameterMap, identityReply: [UInt8] = SimulatedAmp.katanaIdentityReply) {
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
        memory[Address.editorCommunicationRevision.linear] = 1
        state = Mutex(State(memory: memory, identityReply: identityReply))
    }

    /// Handles a message from Tanto as the amp would.
    ///
    /// - Parameter message: A complete SysEx message.
    public func send(_ message: [UInt8]) throws {
        let now = ContinuousClock.now
        let reply: [UInt8]? = state.withLock { state in
            state.received.append(Received(message: message, time: now))
            if message == SysEx.identityRequest {
                return state.identityReply
            }
            if let (address, size) = Self.parseRQ1(message) {
                guard state.answersReads else { return nil }
                let data = (0..<size).map { state.memory[address.linear + $0] ?? 0 }
                return SysEx.dt1(address, data: data)
            }
            if case .dataSet(let address, let data) = IncomingMessage(message) {
                for (index, byte) in data.enumerated() {
                    state.memory[address.linear + index] = byte
                }
            }
            return nil
        }
        if let reply {
            continuation.yield(reply)
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
        continuation.yield(SysEx.dt1(address, data: bytes))
    }

    /// Stops or resumes answering RQ1 reads, to test timeouts.
    ///
    /// - Parameter answers: Whether reads get a reply.
    public func setAnswersReads(_ answers: Bool) {
        state.withLock { $0.answersReads = answers }
    }

    static func parseRQ1(_ message: [UInt8]) -> (Address, Int)? {
        let prefix = SysEx.header + [SysEx.rq1Command]
        guard message.count == prefix.count + 10, message.starts(with: prefix), message.last == 0xF7 else {
            return nil
        }
        let body = Array(message[prefix.count..<(prefix.count + 8)])
        guard body.allSatisfy({ $0 < 0x80 }), SysEx.checksum(body) == message[prefix.count + 8] else { return nil }
        return (Address(bytes: body.prefix(4)), Address(bytes: body.suffix(4)).linear)
    }
}
