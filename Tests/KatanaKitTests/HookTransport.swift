import Synchronization

@testable import KatanaKit

/// Wraps a simulated amp; a hook runs before each message reaches it, and may look at the amp, change it first or throw.
final class HookTransport: MIDITransport {
    let amp: SimulatedAmp
    private let hook = Mutex<(@Sendable ([UInt8]) throws -> Void)?>(nil)

    init(amp: SimulatedAmp) {
        self.amp = amp
    }

    var incoming: AsyncStream<[UInt8]> { amp.incoming }

    func setHook(_ newHook: (@Sendable ([UInt8]) throws -> Void)?) {
        hook.withLock { $0 = newHook }
    }

    func send(_ message: [UInt8]) throws {
        let current = hook.withLock { $0 }
        try current?(message)
        try amp.send(message)
    }
}
