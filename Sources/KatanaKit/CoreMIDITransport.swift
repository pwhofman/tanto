import CoreMIDI
import Foundation
import Synchronization

/// A MIDI endpoint as CoreMIDI reports it.
public struct MIDIEndpoint: Sendable, Hashable {
    /// Display name, e.g. `KATANA`.
    public let name: String
    let ref: MIDIEndpointRef
}

/// Errors from CoreMIDI.
public enum CoreMIDIError: Error, Equatable, CustomStringConvertible {
    /// A CoreMIDI call failed.
    case call(String, OSStatus)
    /// No source or no destination is named "KATANA".
    case katanaNotFound
    /// Several endpoints are named "KATANA".
    case ambiguous([String])

    public var description: String {
        switch self {
        case .call(let name, let status): "\(name) failed with OSStatus \(status)"
        case .katanaNotFound:
            "no MIDI source and destination named KATANA; is the amp on and the BOSS driver installed?"
        case .ambiguous(let names): "several MIDI endpoints named KATANA: \(names)"
        }
    }
}

/// The amp's MIDI connection through CoreMIDI, using MIDI 1.0 Universal MIDI Packets.
public final class CoreMIDITransport: MIDITransport {
    public let incoming: AsyncStream<[UInt8]>
    private let continuation: AsyncStream<[UInt8]>.Continuation
    private let client: MIDIClientRef
    private let inputPort: MIDIPortRef
    private let outputPort: MIDIPortRef
    private let destination: MIDIEndpointRef

    /// All MIDI sources (messages flow from them to Tanto).
    public static func sources() -> [MIDIEndpoint] {
        (0..<MIDIGetNumberOfSources()).map { endpoint(MIDIGetSource($0)) }
    }

    /// All MIDI destinations (messages flow from Tanto to them).
    public static func destinations() -> [MIDIEndpoint] {
        (0..<MIDIGetNumberOfDestinations()).map { endpoint(MIDIGetDestination($0)) }
    }

    /// Connects to the amp's main port.
    ///
    /// - Returns: The transport.
    /// - Throws: `CoreMIDIError` if the main port is missing or ambiguous, or CoreMIDI fails.
    public static func katana() throws -> CoreMIDITransport {
        try CoreMIDITransport(source: mainPort(in: sources()), destination: mainPort(in: destinations()))
    }

    /// Picks the amp's main port, the endpoint named exactly "KATANA". The amp also offers "KATANA DAW CTRL" for
    /// controlling recording software; Tone Studio and Tanto talk on the main port.
    ///
    /// - Parameter endpoints: All sources or all destinations.
    /// - Returns: The main port.
    /// - Throws: `CoreMIDIError.katanaNotFound` if there is none, `.ambiguous` if there are several.
    static func mainPort(in endpoints: [MIDIEndpoint]) throws -> MIDIEndpoint {
        let matches = endpoints.filter { $0.name.caseInsensitiveCompare("KATANA") == .orderedSame }
        guard let port = matches.first else { throw CoreMIDIError.katanaNotFound }
        guard matches.count == 1 else { throw CoreMIDIError.ambiguous(matches.map(\.name)) }
        return port
    }

    /// Opens a connection.
    ///
    /// - Parameters:
    ///   - source: Where messages from the amp come from.
    ///   - destination: Where messages to the amp go.
    /// - Throws: `CoreMIDIError.call` if CoreMIDI fails.
    public init(source: MIDIEndpoint, destination: MIDIEndpoint) throws {
        let (stream, continuation) = AsyncStream.makeStream(of: [UInt8].self)
        incoming = stream
        self.continuation = continuation
        self.destination = destination.ref
        var client = MIDIClientRef()
        try Self.check("MIDIClientCreateWithBlock", MIDIClientCreateWithBlock("Tanto" as CFString, &client, nil))
        self.client = client
        var outputPort = MIDIPortRef()
        try Self.check("MIDIOutputPortCreate", MIDIOutputPortCreate(client, "Tanto out" as CFString, &outputPort))
        self.outputPort = outputPort
        let decoder = Mutex(UMPDecoder())
        var inputPort = MIDIPortRef()
        let status = MIDIInputPortCreateWithProtocol(client, "Tanto in" as CFString, ._1_0, &inputPort) { list, _ in
            let wordsOffset = MemoryLayout<MIDIEventPacket>.offset(of: \MIDIEventPacket.words)!
            for packet in list.unsafeSequence() {
                let base = UnsafeRawPointer(packet).advanced(by: wordsOffset)
                let words = (0..<Int(packet.pointee.wordCount)).map {
                    base.load(fromByteOffset: $0 * MemoryLayout<UInt32>.size, as: UInt32.self)
                }
                for message in decoder.withLock({ $0.decode(words) }) {
                    continuation.yield(message)
                }
            }
        }
        try Self.check("MIDIInputPortCreateWithProtocol", status)
        self.inputPort = inputPort
        try Self.check("MIDIPortConnectSource", MIDIPortConnectSource(inputPort, source.ref, nil))
    }

    deinit {
        continuation.finish()
        MIDIPortDispose(inputPort)
        MIDIPortDispose(outputPort)
        MIDIClientDispose(client)
    }

    public func send(_ message: [UInt8]) throws {
        // A Katana message is at most about 150 bytes, far below this buffer's capacity.
        let size = 65_536
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<MIDIEventList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: MIDIEventList.self, capacity: 1)
        var packet = MIDIEventListInit(list, ._1_0)
        for words in UMP.sysEx7Packets(for: message) {
            packet = words.withUnsafeBufferPointer {
                MIDIEventListAdd(list, size, packet, 0, words.count, $0.baseAddress!)
            }
        }
        try Self.check("MIDISendEventList", MIDISendEventList(outputPort, destination, list))
    }

    private static func endpoint(_ ref: MIDIEndpointRef) -> MIDIEndpoint {
        var name: Unmanaged<CFString>?
        let status = MIDIObjectGetStringProperty(ref, kMIDIPropertyDisplayName, &name)
        return MIDIEndpoint(name: status == noErr ? (name?.takeRetainedValue() as String?) ?? "" : "", ref: ref)
    }

    private static func check(_ call: String, _ status: OSStatus) throws {
        guard status == noErr else { throw CoreMIDIError.call(call, status) }
    }
}
