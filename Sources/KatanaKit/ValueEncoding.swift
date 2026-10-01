/// How a parameter value is stored in the amp's memory.
public enum ValueEncoding: String, Codable, Sendable {
    /// One byte of 7 bits (Tone Studio's `INTEGER1x7`).
    case int1x7
    /// Two bytes of 7 bits, most significant first (`INTEGER2x7`).
    case int2x7
    /// Sixteen ASCII characters: the patch name.
    case ascii16

    /// Number of bytes a value occupies.
    public var byteCount: Int {
        switch self {
        case .int1x7: 1
        case .int2x7: 2
        case .ascii16: 16
        }
    }

    /// Decodes a raw numeric value.
    ///
    /// - Parameter bytes: Exactly `byteCount` bytes of a numeric encoding.
    /// - Returns: The raw value, before the parameter's `rawOffset` is subtracted.
    public func decode(_ bytes: some Collection<UInt8>) -> Int {
        precondition(self != .ascii16 && bytes.count == byteCount, "decode needs \(byteCount) bytes of a number")
        return bytes.reduce(0) { ($0 << 7) | Int($1 & 0x7F) }
    }

    /// Encodes a raw numeric value.
    ///
    /// - Parameter raw: `0..<128` for `int1x7`, `0..<16384` for `int2x7`.
    /// - Returns: The bytes to store.
    public func encode(_ raw: Int) -> [UInt8] {
        switch self {
        case .int1x7:
            precondition((0..<128).contains(raw), "int1x7 value out of range: \(raw)")
            return [UInt8(raw)]
        case .int2x7:
            precondition((0..<16384).contains(raw), "int2x7 value out of range: \(raw)")
            return [UInt8(raw >> 7), UInt8(raw & 0x7F)]
        case .ascii16:
            preconditionFailure("ascii16 is not a number")
        }
    }
}

/// The 16-character patch name.
public enum PatchName {
    /// Decodes a stored name.
    ///
    /// - Parameter bytes: The 16 name bytes.
    /// - Returns: The name without trailing spaces.
    public static func decode(_ bytes: some Collection<UInt8>) -> String {
        var name = String(decoding: bytes.map { $0 & 0x7F }, as: UTF8.self)
        while name.last == " " {
            name.removeLast()
        }
        return name
    }
}
