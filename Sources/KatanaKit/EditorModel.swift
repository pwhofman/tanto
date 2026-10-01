import Observation

/// The state behind Tanto's window: the connection, the live values, the channels and the refusals of `SafetyGuard`.
///
/// Every change of the sound goes through `SafetyGuard`; the model never writes to the session itself.
@MainActor
@Observable
public final class EditorModel {
    /// The state of the connection to the amp.
    public enum Connection: Equatable, Sendable {
        /// No amp, or not tried yet.
        case notConnected
        /// The connect sequence is running.
        case connecting
        /// Connected; the live patch has been read.
        case connected
        /// The connect sequence failed, with the reason.
        case failed(String)
    }

    /// One section of the editor.
    public struct Section: Identifiable, Sendable {
        /// The section name used in the parameter table, e.g. `booster`.
        public let id: String
        /// The title shown in the window.
        public let title: String
        /// The parameters Tanto may write, front-panel controls first, then in address order.
        public let parameters: [Parameter]
    }

    // Spec section 6.
    private static let sectionTitles = [
        ("amp", "Amp"), ("booster", "Booster"), ("mod", "Mod"), ("fx", "FX"), ("delay", "Delay"), ("delay2", "Delay 2"),
        ("reverb", "Reverb"), ("eq1", "EQ 1"), ("eq2", "EQ 2"), ("pedalfx", "Pedal FX"), ("ns", "Noise Suppressor"),
        ("sendreturn", "Send/Return"), ("solo", "Solo"), ("contour", "Contour"), ("chain", "Chain"),
    ]

    /// The parameter table.
    public let map: ParameterMap
    /// The editor sections.
    public let sections: [Section]
    /// The connection state.
    public private(set) var connection = Connection.notConnected
    /// Displayed values of the live patch, by parameter offset.
    public private(set) var values: [Int: Int] = [:]
    /// The name of the live patch.
    public private(set) var liveName = ""
    /// The names of the nine stored channels: PANEL, A1–A4, B1–B4.
    public private(set) var channelNames: [String] = []
    /// The selected channel (0 = PANEL, 1–8 = A1–B4).
    public private(set) var currentChannel: Int?
    /// The latest refusal of `SafetyGuard` per parameter offset, as a message for the control.
    public private(set) var refusals: [Int: String] = [:]
    /// The latest refusal of a rename.
    public private(set) var nameRefusal: String?
    /// The ceiling as a percentage of a guarded parameter's travel.
    public private(set) var ceilingPercent = 50

    @ObservationIgnored private var session: AmpSession?
    @ObservationIgnored private var safety: SafetyGuard?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?

    /// Creates a model that is not connected.
    ///
    /// - Parameter map: The parameter table.
    public init(map: ParameterMap) {
        self.map = map
        sections = Self.sectionTitles.map { id, title in
            let parameters = map.table.parameters.filter { $0.section == id && $0.written && $0.kind != .text }
            return Section(
                id: id, title: title,
                parameters: parameters.sorted {
                    ($0.block == "Status" ? 0 : 1, $0.offset) < ($1.block == "Status" ? 0 : 1, $1.offset)
                })
        }
    }

    /// Connects: Tone Studio's connect sequence, then the current channel, the channel names and the live patch.
    /// Nothing is written apart from the editor-mode flag.
    ///
    /// - Parameters:
    ///   - transport: The connection to the amp.
    ///   - timing: Message spacing and read timeout.
    public func connect(_ transport: any MIDITransport, timing: SessionTiming = .katana) async {
        await disconnect()
        connection = .connecting
        let session = AmpSession(transport: transport, timing: timing)
        self.session = session
        updatesTask = Task { [weak self] in
            for await update in session.updates {
                self?.apply(update)
            }
        }
        do {
            _ = try await session.connect()
            currentChannel = try await session.readCurrentChannel()
            var names: [String] = []
            for slot in 0...8 {
                names.append(PatchName.decode(try await session.read(.userPatch(slot), size: PatchName.length)))
            }
            channelNames = names
            try await session.readLivePatch(map)
            liveName = await session.liveName() ?? ""
            safety = try SafetyGuard(session: session, map: map, ceilingPercent: ceilingPercent)
            connection = .connected
        } catch {
            connection = .failed(Self.message(for: error))
        }
    }

    /// Switches editor mode off, if the amp is still there, and forgets the connection.
    public func disconnect() async {
        updatesTask?.cancel()
        updatesTask = nil
        if let session {
            try? await session.disconnect()
        }
        session = nil
        safety = nil
        connection = .notConnected
    }

    /// The live value of a parameter.
    ///
    /// - Parameter parameter: A parameter.
    /// - Returns: The displayed value, or `nil` before the live patch is read.
    public func value(of parameter: Parameter) -> Int? {
        values[parameter.offset]
    }

    /// Whether a parameter is shown for the current effect types.
    ///
    /// - Parameter parameter: A parameter.
    /// - Returns: `true` if all its visibility conditions hold.
    public func isVisible(_ parameter: Parameter) -> Bool {
        parameter.isVisible { values[$0] }
    }

    /// The ceiling of a guarded parameter.
    ///
    /// - Parameter parameter: A parameter.
    /// - Returns: The ceiling, or `nil` for unguarded parameters.
    public func ceiling(of parameter: Parameter) -> Int? {
        Ceiling.value(of: parameter, percent: ceilingPercent)
    }

    /// Asks `SafetyGuard` for a new value; a refusal is kept as the control's message.
    ///
    /// - Parameters:
    ///   - parameter: A parameter from `sections`.
    ///   - value: The displayed value.
    public func set(_ parameter: Parameter, to value: Int) async {
        guard let safety else {
            refusals[parameter.offset] = "Not connected"
            return
        }
        do {
            try await safety.set(parameter, to: value)
            refusals[parameter.offset] = nil
        } catch {
            refusals[parameter.offset] = Self.message(for: error)
        }
    }

    /// Panic: the VOLUME knob to 0 as the next message (design spec, section 5.5).
    public func panic() async {
        await safety?.panic()
    }

    /// Renames the live patch.
    ///
    /// - Parameter name: At most 16 characters from space to `}`.
    public func rename(to name: String) async {
        guard let safety else {
            nameRefusal = "Not connected"
            return
        }
        do {
            try await safety.rename(to: name)
            nameRefusal = nil
        } catch {
            nameRefusal = Self.message(for: error)
        }
    }

    /// Whether changing the ceiling needs the user's confirmation: raising it does, lowering it does not.
    ///
    /// - Parameter percent: The new percentage.
    /// - Returns: `true` when raising.
    public func needsConfirmation(toSetCeilingPercent percent: Int) -> Bool {
        percent > ceilingPercent
    }

    /// Changes the ceiling.
    ///
    /// - Parameter percent: 0–100 in steps of 5.
    /// - Throws: `SafetyError.invalidCeiling`.
    public func setCeilingPercent(_ percent: Int) async throws {
        guard Ceiling.isValid(percent: percent) else { throw SafetyError.invalidCeiling(percent) }
        try await safety?.setCeilingPercent(percent)
        ceilingPercent = percent
    }

    /// Waits until every accepted request has been written; for tests.
    public func settle() async {
        await safety?.settle()
    }

    private func apply(_ update: LiveUpdate) {
        switch update {
        case .channel(let channel):
            currentChannel = channel
        case .bytes(let offset, let data):
            for value in map.values(in: data, at: offset) {
                values[value.parameter.offset] = value.value
            }
            if offset == 0, data.count >= PatchName.length {
                liveName = PatchName.decode(data.prefix(PatchName.length))
            }
        }
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case let error as SafetyError:
            switch error {
            case .aboveCeiling(_, _, let ceiling): "Above the ceiling of \(ceiling)"
            case .volumeAboveCeiling(_, let ceiling): "Lower VOLUME to \(ceiling) or less first"
            case .notReady: "Not connected yet"
            case .invalidCeiling(let percent): "\(percent) % is not a valid ceiling"
            case .notWritable, .outOfRange, .missingVolumeKnob: "Not allowed"
            }
        case let error as WriteError:
            switch error {
            case .invalidName: "Use at most 16 characters from space to }"
            case .notWritable, .outOfRange: "Not allowed"
            }
        case let error as AmpError:
            switch error {
            case .notAKatana: "The connected device is not a Katana MkII"
            case .noIdentityReply, .timeout: "The amp does not answer"
            case .unsupportedCommunicationLevel(let level): "Unsupported editor communication level \(level)"
            }
        case let error as CoreMIDIError:
            error.description
        default:
            "\(error)"
        }
    }
}
