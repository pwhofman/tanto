import Foundation

/// A Katana memory address: four 7-bit bytes, as sent in RQ1 and DT1 messages.
///
/// The address is stored as a linear integer with 7 bits per byte (Tone Studio's `nibble()`), so byte offsets can be
/// added directly.
public struct Address: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// The address as one integer with 7 bits per byte.
    public let linear: Int

    /// Creates an address from its linear value.
    ///
    /// - Parameter linear: A value in `0..<2^28`.
    public init(linear: Int) {
        precondition((0..<(1 << 28)).contains(linear), "address out of range: \(linear)")
        self.linear = linear
    }

    /// Creates an address from its four bytes packed into one integer, e.g. `0x6000_0028` for `60 00 00 28`.
    ///
    /// - Parameter packed: Four bytes, each below `0x80`.
    public init(packed: UInt32) {
        precondition(packed & 0x8080_8080 == 0, "address bytes must be 7-bit")
        let value =
            ((packed & 0x7F00_0000) >> 3) | ((packed & 0x007F_0000) >> 2) | ((packed & 0x0000_7F00) >> 1)
            | (packed & 0x0000_007F)
        self.init(linear: Int(value))
    }

    /// Creates an address from four SysEx bytes, most significant first.
    ///
    /// - Parameter bytes: Exactly four bytes, each below `0x80`.
    public init(bytes: some Collection<UInt8>) {
        precondition(bytes.count == 4 && bytes.allSatisfy { $0 < 0x80 }, "an address is four 7-bit bytes")
        self.init(linear: bytes.reduce(0) { ($0 << 7) | Int($1) })
    }

    /// The four SysEx bytes, most significant first.
    public var bytes: [UInt8] {
        [21, 14, 7, 0].map { UInt8((linear >> $0) & 0x7F) }
    }

    /// The address `count` bytes further on.
    ///
    /// - Parameter count: Number of bytes to move.
    /// - Returns: The new address.
    public func advanced(by count: Int) -> Address {
        Address(linear: linear + count)
    }

    public static func < (lhs: Address, rhs: Address) -> Bool {
        lhs.linear < rhs.linear
    }

    public var description: String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

extension Address {
    /// The selected channel, two bytes: 0 = PANEL, 1–4 = A1–A4, 5–8 = B1–B4.
    public static let currentPatchNumber = Address(packed: 0x0001_0000)
    /// The live (temporary) patch.
    public static let temporaryPatch = Address(packed: 0x6000_0000)
    /// Editor communication level, one byte.
    public static let editorCommunicationLevel = Address(packed: 0x7F00_0000)
    /// Editor communication mode: 1 = on, 0 = off.
    public static let editorCommunicationMode = Address(packed: 0x7F00_0001)

    /// The base address of stored patch `slot`.
    ///
    /// - Parameter slot: 0 = PANEL, 1–4 = A1–A4, 5–8 = B1–B4.
    /// - Returns: `10 0n 00 00` for slot n.
    public static func userPatch(_ slot: Int) -> Address {
        precondition((0...8).contains(slot), "slot must be in 0...8")
        return Address(packed: 0x1000_0000 | UInt32(slot) << 16)
    }
}
