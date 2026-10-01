/// Roland SysEx messages for the Katana MkII, model ID `00 00 00 33`.
public enum SysEx {
    /// Universal identity request, addressed to any device.
    public static let identityRequest: [UInt8] = [0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7]

    /// Tone Studio's default device ID. Tone Studio replaces it with the one in the amp's identity reply; the user's
    /// amp answers as device `00`.
    public static let defaultDeviceID: UInt8 = 0x10

    static let modelID: [UInt8] = [0x00, 0x00, 0x00, 0x33]
    static let rq1Command: UInt8 = 0x11
    static let dt1Command: UInt8 = 0x12

    static func header(_ deviceID: UInt8) -> [UInt8] {
        [0xF0, 0x41, deviceID] + modelID
    }

    /// The Roland checksum: the byte that makes the sum of `bytes` and the checksum a multiple of 128.
    ///
    /// - Parameter bytes: Address bytes followed by size or data bytes.
    /// - Returns: The checksum byte.
    public static func checksum(_ bytes: some Sequence<UInt8>) -> UInt8 {
        let sum = bytes.reduce(0) { $0 + Int($1) }
        return UInt8((128 - sum % 128) % 128)
    }

    /// A data request (RQ1).
    ///
    /// - Parameters:
    ///   - address: First address to read.
    ///   - size: Number of bytes to read.
    ///   - deviceID: The amp's device ID.
    /// - Returns: The complete message.
    public static func rq1(_ address: Address, size: Int, deviceID: UInt8 = defaultDeviceID) -> [UInt8] {
        let body = address.bytes + Address(linear: size).bytes
        return header(deviceID) + [rq1Command] + body + [checksum(body), 0xF7]
    }

    /// A data set (DT1).
    ///
    /// - Parameters:
    ///   - address: First address to write.
    ///   - data: Bytes to write, each below `0x80`.
    ///   - deviceID: The amp's device ID.
    /// - Returns: The complete message.
    public static func dt1(_ address: Address, data: [UInt8], deviceID: UInt8 = defaultDeviceID) -> [UInt8] {
        precondition(!data.isEmpty && data.allSatisfy { $0 < 0x80 }, "DT1 data must be non-empty 7-bit bytes")
        let body = address.bytes + data
        return header(deviceID) + [dt1Command] + body + [checksum(body), 0xF7]
    }

    /// Whether `message` is a Katana MkII identity reply, by Tone Studio's check: bytes 0–1 are `F0 7E`, bytes 3–7
    /// are `06 02 41 33 03`, and byte 10 is a Katana MkII model code from `05` to `0B` (`06` is the Katana-100 MkII).
    ///
    /// - Parameter message: A complete SysEx message.
    /// - Returns: `true` for a Katana MkII.
    public static func isKatanaIdentityReply(_ message: [UInt8]) -> Bool {
        message.count >= 11 && message[0...1] == [0xF0, 0x7E] && message[3...7] == [0x06, 0x02, 0x41, 0x33, 0x03]
            && (0x05...0x0B).contains(message[10])
    }
}

/// A SysEx message received from the amp.
public enum IncomingMessage: Equatable, Sendable {
    /// A reply to the identity request.
    case identityReply([UInt8])
    /// A DT1 from the Katana with a valid checksum: start address and data.
    case dataSet(Address, [UInt8])
    /// A message with the Katana's DT1 header but a wrong length, byte value or checksum.
    case malformed([UInt8])
    /// Anything else.
    case other([UInt8])

    /// Classifies one complete message. DT1 messages are accepted from any device ID.
    ///
    /// - Parameter message: Bytes from `F0` to `F7`, or a channel message.
    public init(_ message: [UInt8]) {
        if message.count >= 6, message[0] == 0xF0, message[1] == 0x7E, message[3] == 0x06, message[4] == 0x02 {
            self = .identityReply(message)
            return
        }
        // F0 41, device ID, model ID, command.
        let headerLength = 8
        guard message.count >= headerLength, message[0...1] == [0xF0, 0x41],
            message[3..<7].elementsEqual(SysEx.modelID), message[7] == SysEx.dt1Command
        else {
            self = .other(message)
            return
        }
        // Four address bytes, at least one data byte, checksum and F7.
        guard message.count >= headerLength + 7, message.last == 0xF7 else {
            self = .malformed(message)
            return
        }
        let body = Array(message[headerLength..<(message.count - 2)])
        guard body.allSatisfy({ $0 < 0x80 }), SysEx.checksum(body) == message[message.count - 2] else {
            self = .malformed(message)
            return
        }
        self = .dataSet(Address(bytes: body.prefix(4)), Array(body.dropFirst(4)))
    }
}
