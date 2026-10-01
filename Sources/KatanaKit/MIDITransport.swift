/// Moves MIDI messages between Tanto and an amp.
public protocol MIDITransport: Sendable {
    /// Complete messages from the amp: SysEx from `F0` to `F7`, and channel messages of two or three bytes. Only one
    /// consumer may iterate the stream.
    var incoming: AsyncStream<[UInt8]> { get }

    /// Sends one complete SysEx message.
    ///
    /// - Parameter message: Bytes from `F0` to `F7`.
    /// - Throws: An error from the underlying MIDI system.
    func send(_ message: [UInt8]) throws
}
