import Foundation

/// One block of the patch layout.
public struct ParameterBlock: Codable, Sendable, Hashable {
    /// Tone Studio's block name, e.g. `Patch_0` or `Fx(1)`.
    public let name: String
    /// Linear offset from the patch base.
    public let offset: Int
    /// Size in bytes.
    public let size: Int
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
    /// The direction in which the parameter makes the amp louder; changes that way are ramped (design spec, section
    /// 5.2). Every guarded parameter gets louder upwards; a few unguarded ones, like the limiter's ratio, downwards.
    public let louder: Direction?
    /// Whether a Tone Studio control writes the parameter; Tanto writes nothing else (design spec, section 3.5). The
    /// patch name is `false` here, yet renaming writes it, as Tone Studio's WRITE dialog does.
    public let written: Bool
    /// How the parameter is edited.
    public let kind: Kind
    /// Editor section, e.g. `amp`, `booster` or `delay2`; `nil` if no v1 control shows the parameter.
    public let section: String?
    /// Tone Studio's on-screen label, or the name from the address map.
    public let label: String
    /// The choices of a picker, in menu order.
    public let options: [Option]?
    /// A label for every value from `minimum` to `maximum`, e.g. `["OFF", "ON"]`.
    public let valueLabels: [String]?
    /// How the value is displayed; `nil` for a plain number.
    public let format: DisplayFormat?
    /// The parameter is shown only while all of these hold; `nil` means always.
    public let visibleWhen: [Condition]?
    /// How Tone Studio draws the parameter; `nil` for the patch name.
    public let control: Control?
    /// Where Tone Studio puts the parameter on its block's page; `nil` if only the front panel shows it.
    public let position: Position?
    /// Where Tone Studio puts the parameter on the front panel; `nil` if the panel does not show it.
    public let panel: Position?

    /// How Tone Studio draws a parameter, and so how Tanto shows it.
    public enum Control: String, Codable, Sendable {
        /// A rotary knob or dial.
        case knob
        /// A linear slider, as in the graphic EQs.
        case slider
        /// An on/off switch.
        case `switch`
        /// A pop-up menu.
        case menu
        /// A row of buttons of which one is selected.
        case segmented
    }

    /// A place on Tone Studio's page or front panel: the offset from its top left, in Tone Studio's pixels.
    public struct Position: Codable, Sendable, Hashable {
        /// From the left.
        public let x: Int
        /// From the top.
        public let y: Int
    }

    /// A direction of change.
    public enum Direction: String, Codable, Sendable {
        /// Towards the maximum.
        case up
        /// Towards the minimum.
        case down
    }

    /// How a parameter is edited; switches and pickers get the soft switch (design spec, section 5.3).
    public enum Kind: String, Codable, Sendable {
        /// The 16-character patch name.
        case text
        /// Two values, e.g. on and off.
        case toggle = "switch"
        /// A choice from a list, e.g. an effect type.
        case picker
        /// A number in a range.
        case numeric
    }

    /// One choice of a picker.
    public struct Option: Codable, Sendable, Hashable {
        /// The displayed value it sets.
        public let value: Int
        /// Its label.
        public let label: String
    }

    /// A condition on another parameter, typically an effect type.
    public struct Condition: Codable, Sendable, Hashable {
        /// Offset of the parameter the condition is on.
        public let offset: Int
        /// The displayed values that satisfy the condition.
        public let values: [Int]
    }

    /// Display formats found in Tone Studio's layout.
    public enum DisplayFormat: String, Codable, Sendable {
        /// `+3`, `0`, `-3`.
        case signed
        /// `+3dB`.
        case signedDecibels
        /// The value counts half decibels: `+1.5dB`.
        case signedHalfDecibels
        /// `320ms`.
        case milliseconds
        /// The value plus one.
        case plusOne
        /// The value counts tenths of seconds: `2.5s`.
        case tenthsOfSeconds
        /// `OFF` below zero, the number otherwise.
        case offBelowZero
        /// `50%`.
        case percent
    }

    /// Whether values below zero switch an effect off: the BOOSTER, MOD, FX, DELAY and REVERB knobs. Crossing zero
    /// switches the effect on or off, which goes through the soft switch (design spec, section 5.2).
    public var switchesEffectOffBelowZero: Bool {
        guarded && format == .offBelowZero
    }

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

    /// Loads a table from a file. The app uses this with the copy in its own bundle, where SwiftPM's resource bundle
    /// is not found.
    ///
    /// - Parameter url: A `parameters.json` file.
    /// - Throws: An error from reading or `DecodingError` if the file is invalid.
    public init(contentsOf url: URL) throws {
        self.init(try JSONDecoder().decode(ParameterTable.self, from: Data(contentsOf: url)))
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
