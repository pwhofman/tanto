import CoreMIDI

/// The MIDI ports through which the amp appears and disappears.
public protocol AmpPorts: Sendable {
    /// Yields whenever the MIDI setup may have changed.
    var changes: AsyncStream<Void> { get }
    /// Whether the amp's main port is there.
    var isPresent: Bool { get }

    /// Opens a connection to the amp.
    ///
    /// - Returns: The transport, or `nil` if the amp's port is not there.
    /// - Throws: An error from the MIDI system.
    func open() throws -> (any MIDITransport)?
}

/// The amp's ports as CoreMIDI reports them. Create it on the main thread: CoreMIDI delivers its notifications on the
/// run loop of the thread that created the client.
public final class CoreMIDIPorts: AmpPorts {
    public let changes: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let client: MIDIClientRef

    /// Starts watching the MIDI setup.
    ///
    /// - Throws: `CoreMIDIError.call` if CoreMIDI fails.
    public init() throws {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        changes = stream
        self.continuation = continuation
        var client = MIDIClientRef()
        let status = MIDIClientCreateWithBlock("Tanto ports" as CFString, &client) { notification in
            if notification.pointee.messageID == .msgSetupChanged {
                continuation.yield()
            }
        }
        guard status == noErr else { throw CoreMIDIError.call("MIDIClientCreateWithBlock", status) }
        self.client = client
    }

    deinit {
        continuation.finish()
        MIDIClientDispose(client)
    }

    // Several main ports count as present, so that `open()` reports the ambiguity instead of "not connected".
    public var isPresent: Bool {
        CoreMIDITransport.hasMainPort(in: CoreMIDITransport.sources())
            && CoreMIDITransport.hasMainPort(in: CoreMIDITransport.destinations())
    }

    public func open() throws -> (any MIDITransport)? {
        guard isPresent else { return nil }
        return try CoreMIDITransport.katana()
    }
}
