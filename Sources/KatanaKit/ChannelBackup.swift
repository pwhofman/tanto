import Foundation

/// Why a backup file is refused. Nothing is written to the amp.
public enum BackupError: Error, Equatable, Sendable {
    /// The file is not a backup: not JSON, or a field is missing or of the wrong kind.
    case unreadable(String)
    /// Tanto reads only format 1.
    case unknownFormat(Int)
    /// The backup comes from another amp model.
    case otherModel(String)
    /// The channels must be 1–8, each once; these are the slots found.
    case channels([Int])
    /// A block of the parameter table is missing.
    case missingBlock(slot: Int, block: String)
    /// A block that the parameter table does not have.
    case unknownBlock(slot: Int, block: String)
    /// A block has the wrong number of bytes.
    case blockLength(slot: Int, block: String, expected: Int, found: Int)
    /// A block is not hex with two digits per byte, or holds a byte from `0x80` up.
    case invalidBytes(slot: Int, block: String)
    /// The name differs from the one in the channel's name block.
    case nameMismatch(slot: Int)
}

/// A backup of channels 1–8, saved as `<name>.tanto-backup.json` (design spec, section 7). Every block of the parameter
/// table is kept as hex, two digits per byte, so that a restore writes the channels back byte for byte.
public struct ChannelBackup: Codable, Equatable, Sendable {
    /// One stored channel.
    public struct Channel: Codable, Equatable, Sendable {
        /// 1–4 = A1–A4, 5–8 = B1–B4.
        public let slot: Int
        /// The channel's name, as its name block holds it, without trailing spaces.
        public let name: String
        /// The bytes of each block of the parameter table, by block name.
        public let blocks: [String: String]
    }

    /// The format this version of Tanto writes and reads.
    public static let currentFormat = 1
    /// The model a backup is for.
    public static let modelName = "KATANA MkII"
    /// The end of a backup file's name.
    public static let fileExtension = "tanto-backup.json"

    /// The file format.
    public let format: Int
    /// The amp model.
    public let model: String
    /// When the backup was made.
    public let created: Date
    /// Channels 1–8, in order.
    public let channels: [Channel]

    /// Makes a backup from stored patches.
    ///
    /// - Parameters:
    ///   - patches: The bytes of each channel, by slot, at least `map.patchSize` each.
    ///   - map: The parameter table, whose blocks are kept.
    ///   - created: When the patches were read.
    public init(patches: [Int: [UInt8]], map: ParameterMap, created: Date) {
        format = Self.currentFormat
        model = Self.modelName
        self.created = created
        channels = patches.keys.sorted().map { slot in
            let patch = patches[slot] ?? []
            precondition(patch.count >= map.patchSize, "channel \(slot) is shorter than a patch")
            var blocks: [String: String] = [:]
            for block in map.table.blocks {
                blocks[block.name] = patch[block.offset..<(block.offset + block.size)]
                    .map { String(format: "%02X", $0) }.joined()
            }
            return Channel(slot: slot, name: PatchName.decode(patch.prefix(PatchName.length)), blocks: blocks)
        }
    }

    /// The file's contents: JSON with sorted keys, one field per line.
    ///
    /// - Returns: The JSON.
    /// - Throws: `EncodingError`.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Reads a backup file and checks all of it against the parameter table before anything can be written.
    ///
    /// - Parameters:
    ///   - data: The file's contents.
    ///   - map: The parameter table.
    /// - Returns: The backup.
    /// - Throws: `BackupError` with the first problem found.
    public static func load(_ data: Data, map: ParameterMap) throws -> ChannelBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup: ChannelBackup
        do {
            backup = try decoder.decode(ChannelBackup.self, from: data)
        } catch {
            throw BackupError.unreadable(String(describing: error))
        }
        guard backup.format == currentFormat else { throw BackupError.unknownFormat(backup.format) }
        guard backup.model == modelName else { throw BackupError.otherModel(backup.model) }
        let slots = backup.channels.map(\.slot)
        guard slots.sorted() == Array(1...8) else { throw BackupError.channels(slots) }
        let known = Set(map.table.blocks.map(\.name))
        for channel in backup.channels {
            for block in map.table.blocks {
                guard let hex = channel.blocks[block.name] else {
                    throw BackupError.missingBlock(slot: channel.slot, block: block.name)
                }
                guard hex.count == 2 * block.size else {
                    throw BackupError.blockLength(
                        slot: channel.slot, block: block.name, expected: block.size, found: hex.count / 2)
                }
                guard let bytes = bytes(fromHex: hex), bytes.allSatisfy({ $0 < 0x80 }) else {
                    throw BackupError.invalidBytes(slot: channel.slot, block: block.name)
                }
            }
            if let unknown = channel.blocks.keys.sorted().first(where: { !known.contains($0) }) {
                throw BackupError.unknownBlock(slot: channel.slot, block: unknown)
            }
            guard PatchName.decode(backup.patch(of: channel.slot, map: map).prefix(PatchName.length)) == channel.name
            else {
                throw BackupError.nameMismatch(slot: channel.slot)
            }
        }
        return backup
    }

    /// The bytes of a channel, laid out like the live patch; bytes between blocks are 0.
    ///
    /// - Parameters:
    ///   - slot: A slot of the backup.
    ///   - map: The parameter table the backup was checked against.
    /// - Returns: `map.patchSize` bytes.
    public func patch(of slot: Int, map: ParameterMap) -> [UInt8] {
        guard let channel = channels.first(where: { $0.slot == slot }) else {
            preconditionFailure("the backup has no channel \(slot)")
        }
        var patch = [UInt8](repeating: 0, count: map.patchSize)
        for block in map.table.blocks {
            if let bytes = channel.blocks[block.name].flatMap(Self.bytes(fromHex:)), bytes.count == block.size {
                patch.replaceSubrange(block.offset..<(block.offset + block.size), with: bytes)
            }
        }
        return patch
    }

    private static func bytes(fromHex hex: String) -> [UInt8]? {
        let digits = Array(hex.utf8)
        guard digits.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(digits.count / 2)
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let byte = UInt8(String(decoding: digits[index..<(index + 2)], as: UTF8.self), radix: 16) else {
                return nil
            }
            bytes.append(byte)
        }
        return bytes
    }
}
