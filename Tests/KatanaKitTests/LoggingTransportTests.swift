import Synchronization
import Testing

@testable import KatanaKit

@Test func logsBothDirections() async throws {
    let amp = SimulatedAmp(map: try .bundled())
    let log = Mutex<[(LoggingTransport.Direction, [UInt8])]>([])
    let transport = LoggingTransport(wrapping: amp) { direction, message in
        log.withLock { $0.append((direction, message)) }
    }
    try transport.send(SysEx.identityRequest)
    var replies = transport.incoming.makeAsyncIterator()
    #expect(await replies.next() == SimulatedAmp.katanaIdentityReply)
    let entries = log.withLock { $0 }
    #expect(entries.map { $0.0 } == [.sent, .received])
    #expect(entries.map { $0.1 } == [SysEx.identityRequest, SimulatedAmp.katanaIdentityReply])
}
