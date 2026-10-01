import Foundation

/// Why a librarian action stopped.
public enum LibrarianError: Error, Equatable, Sendable {
    /// A restore stopped part of the way; the channels up to `lastChannelWritten` were written completely (`nil`:
    /// none). It can be run again.
    case restoreStopped(lastChannelWritten: Int?)
}

/// A block whose bytes read back differently after a restore.
public struct RestoreDifference: Equatable, Sendable {
    /// The channel.
    public let slot: Int
    /// The block's name in the parameter table.
    public let block: String
}

/// Channels as a whole: reading, switching, saving, renaming, backing up and restoring them (design spec, sections 5.4
/// and 7). Every stored channel is read from the amp when it is needed, so no check rests on old data.
public actor Librarian {
    /// The stored values that a switch checks against their ceilings: the front panel's volume knobs and the amp
    /// volume. Other guarded values above their ceilings are common in stored channels, mostly Tone Studio's defaults of
    /// effect types a channel does not use (design spec, section 5.4).
    static let switchCheck: Set<String> = [
        "PRM_KNOB_POS_VOLUME", "PRM_KNOB_POS_GAIN", "PRM_KNOB_POS_BOOST", "PRM_KNOB_POS_MOD", "PRM_KNOB_POS_FX",
        "PRM_KNOB_POS_DELAY", "PRM_KNOB_POS_REVERB", "PRM_PREAMP_A_LEVEL",
    ]

    private let session: AmpSession
    private let safety: SafetyGuard
    private let map: ParameterMap

    /// Creates a librarian.
    ///
    /// - Parameters:
    ///   - session: The connection, with the live patch read.
    ///   - safety: The guard of the session, whose ramps a save waits for and whose ceiling a switch checks.
    ///   - map: The parameter table.
    public init(session: AmpSession, safety: SafetyGuard, map: ParameterMap) {
        self.session = session
        self.safety = safety
        self.map = map
    }

    /// Reads a stored channel from the amp.
    ///
    /// - Parameter slot: 0 = PANEL, 1–4 = A1–A4, 5–8 = B1–B4.
    /// - Returns: `map.patchSize` bytes, laid out like the live patch; bytes between blocks are 0.
    /// - Throws: `AmpError.timeout` if a read gets no reply.
    public func read(_ slot: Int) async throws -> [UInt8] {
        var patch = [UInt8](repeating: 0, count: map.patchSize)
        for block in map.table.blocks {
            let bytes = try await session.read(Address.userPatch(slot).advanced(by: block.offset), size: block.size)
            patch.replaceSubrange(block.offset..<(block.offset + block.size), with: bytes)
        }
        return patch
    }

    /// Reads a channel's name from the amp.
    ///
    /// - Parameter slot: 0 = PANEL, 1–4 = A1–A4, 5–8 = B1–B4.
    /// - Returns: The name without trailing spaces.
    /// - Throws: `AmpError.timeout` if the read gets no reply.
    public func name(_ slot: Int) async throws -> String {
        PatchName.decode(try await session.read(.userPatch(slot), size: PatchName.length))
    }

    /// The front-panel volumes of a stored channel that lie above their ceilings, read from the amp just now.
    ///
    /// - Parameter slot: 0 = PANEL, 1–4 = A1–A4, 5–8 = B1–B4.
    /// - Returns: Those values; empty if switching needs no question.
    /// - Throws: `AmpError.timeout` if a read gets no reply.
    public func valuesAboveCeiling(_ slot: Int) async throws -> [ParameterValue] {
        let patch = try await read(slot)
        return await safety.valuesAboveCeiling(in: patch).filter { Self.switchCheck.contains($0.parameter.prm) }
    }

    /// Switches to a channel. The amp loads its stored sound at once; the caller asks first where section 5.4 of the
    /// design spec says so.
    ///
    /// - Parameter slot: 0 = PANEL, 1–4 = A1–A4, 5–8 = B1–B4.
    /// - Throws: `WriteError.noSuchChannel`; `AmpError.timeout`; an error from the transport.
    public func select(_ slot: Int) async throws {
        try await session.select(slot)
    }

    /// Saves the live sound to a channel: once the guard's ramps are done, with Tone Studio's WRITE and the amp's
    /// confirmation, then selects the channel as Tone Studio does. The sound does not change.
    ///
    /// - Parameter slot: 1–4 = A1–A4, 5–8 = B1–B4.
    /// - Returns: The channel's name, read back from the amp.
    /// - Throws: `WriteError.noSuchChannel`; `AmpError.noSaveConfirmation`; `AmpError.timeout`; an error from the
    ///   transport.
    public func save(to slot: Int) async throws -> String {
        await safety.settle()
        try await session.savePatch(to: slot)
        try await session.select(slot)
        return try await name(slot)
    }

    /// Renames a stored channel by writing its 16 name bytes; the rest of the channel stays. For the current channel the
    /// live name changes too, so that the window and the amp agree.
    ///
    /// - Parameters:
    ///   - slot: 1–4 = A1–A4, 5–8 = B1–B4.
    ///   - name: At most 16 characters from space to `}`.
    /// - Throws: `WriteError.invalidName` or `.noSuchChannel`; an error from the transport.
    public func rename(_ slot: Int, to name: String) async throws {
        let bytes = Array(name.utf8)
        guard bytes.count <= PatchName.length, bytes.allSatisfy({ (0x20...0x7D).contains($0) }) else {
            throw WriteError.invalidName(name)
        }
        let padded = bytes + Array(repeating: 0x20, count: PatchName.length - bytes.count)
        try await session.writeStored(padded, slot: slot, offset: 0)
        if await session.currentChannel == slot {
            try await safety.rename(to: name)
        }
    }

    /// Reads channels 1–8 into a backup.
    ///
    /// - Returns: The backup.
    /// - Throws: `AmpError.timeout` if a read gets no reply.
    public func backup() async throws -> ChannelBackup {
        var patches: [Int: [UInt8]] = [:]
        for slot in 1...8 {
            patches[slot] = try await read(slot)
        }
        return ChannelBackup(patches: patches, map: map, created: Date())
    }

    /// Writes channels 1–8 of a backup back, block by block in messages of at most 128 bytes, then reads them back. No
    /// channel is selected afterwards (design spec, section 5.4).
    ///
    /// - Parameter backup: A backup checked by `ChannelBackup.load(_:map:)`.
    /// - Returns: The blocks that read back differently; empty when the restore is exact.
    /// - Throws: `LibrarianError.restoreStopped` if writing stops part of the way; `AmpError.timeout` if reading back
    ///   gets no reply.
    public func restore(_ backup: ChannelBackup) async throws -> [RestoreDifference] {
        var lastChannelWritten: Int?
        do {
            for slot in 1...8 {
                let patch = backup.patch(of: slot, map: map)
                for block in map.table.blocks {
                    for start in stride(from: 0, to: block.size, by: AmpSession.maxReadSize) {
                        let offset = block.offset + start
                        let count = min(AmpSession.maxReadSize, block.size - start)
                        try await session.writeStored(
                            Array(patch[offset..<(offset + count)]), slot: slot, offset: offset)
                    }
                }
                lastChannelWritten = slot
            }
        } catch {
            throw LibrarianError.restoreStopped(lastChannelWritten: lastChannelWritten)
        }
        var differences: [RestoreDifference] = []
        for slot in 1...8 {
            let stored = try await read(slot)
            let expected = backup.patch(of: slot, map: map)
            for block in map.table.blocks {
                let range = block.offset..<(block.offset + block.size)
                if stored[range] != expected[range] {
                    differences.append(RestoreDifference(slot: slot, block: block.name))
                }
            }
        }
        return differences
    }
}
