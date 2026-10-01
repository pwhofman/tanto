/// MIDI 1.0 messages in Universal MIDI Packets (UMP), the format of CoreMIDI's current API.
///
/// A SysEx message travels as 64-bit SysEx7 packets (UMP message type 3), each carrying up to six data bytes without
/// the `F0` and `F7` framing. Channel messages such as Program Change travel as 32-bit packets (message type 2).
public enum UMP {
    /// Splits a SysEx message into SysEx7 packets.
    ///
    /// - Parameters:
    ///   - message: A complete message from `F0` to `F7`.
    ///   - group: UMP group, 0–15.
    /// - Returns: Packets of two 32-bit words each.
    public static func sysEx7Packets(for message: [UInt8], group: UInt8 = 0) -> [[UInt32]] {
        precondition(message.first == 0xF0 && message.last == 0xF7, "a SysEx message runs from F0 to F7")
        let payload = Array(message.dropFirst().dropLast())
        let chunks = stride(from: 0, to: max(payload.count, 1), by: 6).map {
            Array(payload[$0..<min($0 + 6, payload.count)])
        }
        return chunks.enumerated().map { index, chunk in
            let status: UInt32 =
                if chunks.count == 1 { 0 }  // complete in one packet
                else if index == 0 { 1 }  // start
                else if index == chunks.count - 1 { 3 }  // end
                else { 2 }  // continue
            let b = chunk + Array(repeating: 0, count: 6 - chunk.count)
            let word0 =
                (0x3 << 28) | (UInt32(group & 0xF) << 24) | (status << 20) | (UInt32(chunk.count) << 16)
                | (UInt32(b[0]) << 8) | UInt32(b[1])
            let word1 = (UInt32(b[2]) << 24) | (UInt32(b[3]) << 16) | (UInt32(b[4]) << 8) | UInt32(b[5])
            return [word0, word1]
        }
    }
}

/// Turns a stream of UMP words back into MIDI 1.0 messages: SysEx from `F0` to `F7`, and channel messages of two or
/// three bytes. Other UMP message types are skipped.
public struct UMPDecoder: Sendable {
    private var sysEx: [UInt8]?

    /// Creates a decoder with no message in progress.
    public init() {}

    /// Decodes the words of one received packet.
    ///
    /// - Parameter words: UMP words in arrival order.
    /// - Returns: The messages completed by these words.
    public mutating func decode(_ words: [UInt32]) -> [[UInt8]] {
        // Message size in words for each UMP message type (the top four bits of the first word).
        let sizes = [1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4]
        var messages: [[UInt8]] = []
        var index = 0
        while index < words.count {
            let word0 = words[index]
            let type = Int(word0 >> 28)
            if type == 0x2 {
                let status = UInt8((word0 >> 16) & 0xFF)
                let data = [UInt8((word0 >> 8) & 0x7F), UInt8(word0 & 0x7F)]
                // Program Change (Cn) and Channel Pressure (Dn) carry one data byte, the others two.
                messages.append([status] + data.prefix(status & 0xE0 == 0xC0 ? 1 : 2))
            } else if type == 0x3, index + 1 < words.count {
                if let message = sysEx7(word0, words[index + 1]) {
                    messages.append(message)
                }
            }
            index += sizes[type]
        }
        return messages
    }

    private mutating func sysEx7(_ word0: UInt32, _ word1: UInt32) -> [UInt8]? {
        let all: [UInt8] = [
            UInt8((word0 >> 8) & 0xFF), UInt8(word0 & 0xFF), UInt8(word1 >> 24), UInt8((word1 >> 16) & 0xFF),
            UInt8((word1 >> 8) & 0xFF), UInt8(word1 & 0xFF),
        ]
        let bytes = Array(all.prefix(min(Int((word0 >> 16) & 0xF), 6)))
        switch (word0 >> 20) & 0xF {
        case 0:
            sysEx = nil
            return [0xF0] + bytes + [0xF7]
        case 1:
            sysEx = bytes
        case 2:
            sysEx?.append(contentsOf: bytes)
        case 3:
            defer { sysEx = nil }
            if let start = sysEx {
                return [0xF0] + start + bytes + [0xF7]
            }
        default:
            break
        }
        return nil
    }
}
