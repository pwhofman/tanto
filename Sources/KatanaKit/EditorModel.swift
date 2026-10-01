import Dispatch
import Observation
import os

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
        /// The front-panel buttons of the section, which are pressed rather than written.
        public let buttons: [PanelButton]
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
    /// The latest refusal of `SafetyGuard` per panel button, as a message for the button.
    public private(set) var buttonRefusals: [PanelButton: String] = [:]
    /// The ceiling as a percentage of a guarded parameter's travel.
    public private(set) var ceilingPercent = 50
    /// How often Panic was pressed; a slider ignores the rest of a drag that a Panic interrupted.
    public private(set) var panicCount = 0

    @ObservationIgnored private var session: AmpSession?
    @ObservationIgnored private var safety: SafetyGuard?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var retries = 0
    private let logger = Logger(subsystem: "io.github.pwhofman.tanto", category: "editor")

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
                },
                buttons: PanelButton.allCases.filter { $0.section == id })
        }
    }

    /// Connects: Tone Studio's connect sequence, then the current channel, the channel names and the live patch.
    /// Nothing is written apart from the editor-mode flag, and VOLUME 0 if Panic is pressed meanwhile.
    ///
    /// - Parameter transport: The connection to the amp.
    public func connect(_ transport: any MIDITransport) async {
        await connect(transport, timing: .katana)
    }

    /// `connect(_:)` with another timing, for tests.
    ///
    /// - Parameters:
    ///   - transport: The connection to the amp.
    ///   - timing: Message spacing and read timeout.
    func connect(_ transport: any MIDITransport, timing: SessionTiming) async {
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
            safety = try SafetyGuard(
                session: session, map: map, ceilingPercent: ceilingPercent, rampDuration: .seconds(2))
            connection = .connected
        } catch {
            connection = .failed(Self.message(for: error))
        }
    }

    /// Keeps the model connected while the amp's port is there. It connects when the port appears, tries again a few
    /// times when the amp does not answer yet, and forgets the connection without sending anything when the port
    /// disappears (design spec, section 8). Runs until the calling task is cancelled.
    ///
    /// - Parameter ports: Where the amp appears.
    public func follow(_ ports: any AmpPorts) async {
        await follow(ports, timing: .katana, retryDelay: .seconds(2))
    }

    /// `follow(_:)` with another timing and retry delay, for tests.
    ///
    /// - Parameters:
    ///   - ports: Where the amp appears.
    ///   - timing: Message spacing and read timeout.
    ///   - retryDelay: The wait before another try after a failed connect.
    func follow(_ ports: any AmpPorts, timing: SessionTiming, retryDelay: Duration) async {
        await refresh(ports, timing: timing, retryDelay: retryDelay)
        for await _ in ports.changes {
            retries = 0
            await refresh(ports, timing: timing, retryDelay: retryDelay)
        }
        retryTask?.cancel()
    }

    private func refresh(_ ports: any AmpPorts, timing: SessionTiming, retryDelay: Duration) async {
        guard !Task.isCancelled else { return }
        guard ports.isPresent else {
            if connection != .notConnected {
                await forget()
            }
            return
        }
        switch connection {
        case .connecting, .connected:
            return
        case .notConnected, .failed:
            break
        }
        do {
            guard let transport = try ports.open() else { return }
            await connect(transport, timing: timing)
        } catch {
            connection = .failed(Self.message(for: error))
        }
        guard case .failed = connection, retries < 5 else { return }
        retries += 1
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: retryDelay)
            } catch {
                return  // cancelled: a newer change or the end of `follow` took over
            }
            await self?.refresh(ports, timing: timing, retryDelay: retryDelay)
        }
    }

    // The amp is gone: drop the connection without sending anything.
    private func forget() async {
        await safety?.stop()
        updatesTask?.cancel()
        updatesTask = nil
        retryTask?.cancel()
        session = nil
        safety = nil
        connection = .notConnected
    }

    /// Stops the guard, switches editor mode off if the amp is still there, and forgets the connection.
    public func disconnect() async {
        await safety?.stop()
        updatesTask?.cancel()
        updatesTask = nil
        if let session {
            do {
                try await session.disconnect()
            } catch {
                logger.error("editor mode not switched off: \(error)")
            }
        }
        session = nil
        safety = nil
        connection = .notConnected
    }

    /// Switches editor mode off while the app quits, waiting at most `timeout`. It blocks the main thread because
    /// `applicationWillTerminate` cannot await, and AppKit runs no main-actor task while it waits for a delayed reply
    /// to `applicationShouldTerminate`.
    ///
    /// - Parameter timeout: The longest wait.
    public func disconnectWhileQuitting(timeout: DispatchTimeInterval) {
        guard let session else { return }
        let done = DispatchSemaphore(value: 0)
        let logger = logger
        let safety = safety
        Task.detached {
            await safety?.stop()
            do {
                try await session.disconnect()
            } catch {
                logger.error("editor mode not switched off: \(error)")
            }
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            logger.error("editor mode not switched off in time")
        }
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

    /// The LED that shows a panel button's state.
    ///
    /// - Parameter button: A panel button.
    /// - Returns: The LED's parameter in the Status block.
    public func led(of button: PanelButton) -> Parameter? {
        map.parameter(block: "Status", prm: button.led)
    }

    /// Presses a panel button through `SafetyGuard`; a refusal is kept as the button's message.
    ///
    /// - Parameter button: A panel button.
    public func press(_ button: PanelButton) async {
        guard let safety else {
            buttonRefusals[button] = "Not connected"
            return
        }
        do {
            try await safety.press(button)
            buttonRefusals[button] = nil
        } catch {
            buttonRefusals[button] = Self.message(for: error)
        }
    }

    /// Panic: the VOLUME knob to 0 as the next message (design spec, section 5.5). While connecting, VOLUME 0 goes out
    /// as soon as the amp is in editor mode.
    public func panic() async {
        panicCount += 1
        if let safety {
            await safety.panic()
        } else if let session, let volumeKnob = map.parameter(block: "Status", prm: "PRM_KNOB_POS_VOLUME") {
            do {
                try await session.panic(volumeKnob: volumeKnob)
            } catch {
                logger.error("Panic not sent: \(error)")
            }
        }
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
            case .notReady: "The amp is not ready yet"
            case .overtakenByPanic: "Cancelled by Panic"
            case .invalidCeiling(let percent): "\(percent) % is not a valid ceiling"
            case .notWritable, .outOfRange: "Not allowed"
            case .invalidTable(let reason): "The parameter table is invalid: \(reason)"
            case .invalidTiming: "The connection is paced faster than Tone Studio's 20 ms"
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
