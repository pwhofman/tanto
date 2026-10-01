import Foundation

/// One block of the patch layout.
public struct ParameterBlock: Codable, Sendable, Hashable {
    /// Tone Studio's block name, e.g. `Patch_0` or `Fx(1)`.
    public let name: String
    /// Linear offset from the patch base.
    public let offset: Int
    /// Size in bytes.
    public let size: Int
    /// Whether v1 edits this block; status and controller-assignment blocks are read-only.
    public let editable: Bool
}

/// One parameter of the patch layout.
public struct Parameter: Codable, Sendable, Hashable {
    /// Tone Studio's internal id, e.g. `PRM_PREAMP_A_LEVEL`; empty for unnamed entries.
    public let prm: String
    /// Tone Studio's name, possibly empty.
    public let name: String
    /// Name of the block that contains the parameter.
    public let block: String
    /// Linear offset from the patch base.
    public let offset: Int
    /// How the value is stored.
    public let encoding: ValueEncoding
    /// Smallest displayed value.
    public let minimum: Int
    /// Largest displayed value.
    public let maximum: Int
    /// The stored (raw) value is the displayed value plus this offset.
    public let rawOffset: Int
    /// Tone Studio's default displayed value; `nil` for the patch name.
    public let initial: Int?
    /// Whether the parameter can raise loudness and falls under the safety ceiling (design spec, section 5.2).
    public let guarded: Bool

    /// Converts a raw value to the displayed value.
    ///
    /// - Parameter raw: Value as stored in the amp.
    /// - Returns: `raw - rawOffset`.
    public func value(fromRaw raw: Int) -> Int {
        raw - rawOffset
    }
}

/// The patch layout generated from Tone Studio by `tools/gen_parameter_map.py`.
public struct ParameterTable: Codable, Sendable, Hashable {
    /// Where the data came from.
    public let source: String
    /// Blocks in increasing offset order.
    public let blocks: [ParameterBlock]
    /// Parameters in increasing offset order.
    public let parameters: [Parameter]
}

/// A parameter together with a displayed value.
public struct ParameterValue: Equatable, Sendable {
    /// The parameter.
    public let parameter: Parameter
    /// The displayed value.
    public let value: Int
}

/// Lookups in a `ParameterTable`.
public struct ParameterMap: Sendable {
    /// The underlying table.
    public let table: ParameterTable
    private let byOffset: [Int: Parameter]

    /// Creates a map over `table`.
    ///
    /// - Parameter table: The patch layout.
    public init(_ table: ParameterTable) {
        self.table = table
        byOffset = Dictionary(table.parameters.map { ($0.offset, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Loads the table bundled with KatanaKit.
    ///
    /// - Returns: The map.
    /// - Throws: `CocoaError` if the resource is missing, `DecodingError` if it is invalid.
    public static func bundled() throws -> ParameterMap {
        guard let url = Bundle.module.url(forResource: "parameters", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return ParameterMap(try JSONDecoder().decode(ParameterTable.self, from: Data(contentsOf: url)))
    }

    /// Size of a patch in bytes, up to the end of its last block.
    public var patchSize: Int {
        table.blocks.map { $0.offset + $0.size }.max() ?? 0
    }

    /// The parameter that starts at `offset`.
    ///
    /// - Parameter offset: Linear offset from the patch base.
    /// - Returns: The parameter, or `nil` if none starts there.
    public func parameter(atOffset offset: Int) -> Parameter? {
        byOffset[offset]
    }

    /// The parameter with Tone Studio id `prm` in `block`.
    ///
    /// - Parameters:
    ///   - block: Block name, e.g. `Patch_0`.
    ///   - prm: Tone Studio id, e.g. `PRM_PREAMP_A_LEVEL`.
    /// - Returns: The parameter, or `nil` if there is none.
    public func parameter(block: String, prm: String) -> Parameter? {
        table.parameters.first { $0.block == block && $0.prm == prm }
    }

    /// Decodes the numeric parameters that lie completely inside `data`.
    ///
    /// - Parameters:
    ///   - data: Bytes read from a patch.
    ///   - offset: Linear offset of the first byte from the patch base.
    /// - Returns: Each parameter with its displayed value, in offset order.
    public func values(in data: [UInt8], at offset: Int) -> [ParameterValue] {
        table.parameters.compactMap { parameter in
            let start = parameter.offset - offset
            guard parameter.encoding != .ascii16, start >= 0, start + parameter.encoding.byteCount <= data.count else {
                return nil
            }
            let raw = parameter.encoding.decode(data[start..<(start + parameter.encoding.byteCount)])
            return ParameterValue(parameter: parameter, value: parameter.value(fromRaw: raw))
        }
    }
}
