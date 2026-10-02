import Dispatch
import Foundation
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

    /// One page of the editor, as BOSS TONE STUDIO has them below its front panel.
    public struct Page: Identifiable, Sendable {
        /// Tone Studio's tab title, e.g. `BOOSTER` or `SEND/RETURN`.
        public let title: String
        /// The parameters Tanto may write that Tone Studio shows on the page, in address order.
        public let parameters: [Parameter]

        /// The title, which no other page has.
        public var id: String { title }
    }

    // Tone Studio's tabs in its groups, each with the section of its parameters (any for EFFECTS) and Tone Studio's
    // pages for them. MOD and FX share a page, as do DELAY and DELAY2. ASSIGN is left out.
    private static let pageSources: [[(title: String, section: String?, pages: [String])]] = [
        [
            ("EFFECTS", nil, ["effects-booster", "effects-mod", "effects-fx", "effects-delay", "effects-reverb"]),
            ("CHAIN", "chain", ["chain-content"]),
        ],
        [
            ("BOOSTER", "booster", ["booster"]), ("MOD", "mod", ["modfx"]), ("FX", "fx", ["modfx"]),
            ("DELAY", "delay", ["delay"]), ("DELAY2", "delay2", ["delay"]), ("REVERB", "reverb", ["reverb"]),
            ("SOLO", "solo", ["solo"]), ("CONTOUR", "contour", ["contour"]),
        ],
        [
            ("PEDAL FX", "pedalfx", ["pedalfx"]), ("EQ", "eq1", ["eq"]), ("EQ2", "eq2", ["eq2"]), ("NS", "ns", ["ns"]),
            ("SEND/RETURN", "sendreturn", ["sr"]),
        ],
    ]

    /// The parameter table.
    public let map: ParameterMap
    /// The editor's pages, in Tone Studio's groups of tabs.
    public let pages: [[Page]]
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
    /// The latest refusal of a TAP button, as a message for the button.
    public private(set) var tapRefusals: [TapButton: String] = [:]
    /// The ceiling as a percentage of a guarded parameter's travel, or `nil` without a ceiling.
    public private(set) var ceilingPercent: Int? = 50
    /// How often Panic was pressed; a slider ignores the rest of a drag that a Panic interrupted.
    public private(set) var panicCount = 0
    /// Whether the live patch has changed since a channel was last loaded or saved, in Tanto or on the amp; switching
    /// asks before it discards the changes (design spec, section 5.4).
    public private(set) var hasUnsavedEdits = false
    /// A switch to another channel that waits for the user's answer.
    public private(set) var pendingSwitch: PendingSwitch?
    /// The channel a switch is on its way to, from the request until the switch is done, refused or cancelled; the
    /// sidebar highlights it meanwhile. A request while the switch loads replaces it, and its switch follows.
    public private(set) var switchTarget: Int?
    /// Whether a save is under way; a save requested meanwhile is dropped.
    public private(set) var isSaving = false
    // Tanto's edits of the live sound for Undo and Redo, newest last. Panic, a channel change and connecting clear them.
    private var undoEdits: [Edit] = []
    private var redoEdits: [Edit] = []

    // An edit for Undo or Redo: the state to go back to, and when it was made, so that a drag's steps join.
    private struct Edit {
        enum Change: Equatable {
            /// A value: a knob, menu or switch, an effect's colour, DELAY TIME after taps.
            case value(Parameter, Int)
            /// The panel's CONTOUR knob, which sets two parameters.
            case contour(Int)
            /// The live sound's name.
            case name(String)
            /// VARIATION, which only its button toggles.
            case variation
        }

        var change: Change
        // `nil` for an undone or redone edit, which a new edit does not join.
        var time: ContinuousClock.Instant?
    }
    /// The result or the error of the latest librarian action, as a message for the window.
    public private(set) var librarianMessage: String?

    /// A switch to another channel that waits for the user's answer (design spec, section 5.4).
    public struct PendingSwitch: Equatable, Sendable {
        /// What the user is asked.
        public enum Question: Equatable, Sendable {
            /// Switching discards the live patch's unsaved edits.
            case unsavedEdits
            /// These front-panel volumes of the channel lie above their ceilings.
            case valuesAboveCeiling([ParameterValue])
        }

        /// The channel to switch to.
        public let slot: Int
        /// The question.
        public let question: Question
    }

    @ObservationIgnored private var session: AmpSession?
    @ObservationIgnored private var safety: SafetyGuard?
    @ObservationIgnored private var librarian: Librarian?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var retries = 0
    @ObservationIgnored private var lastChange: Task<Void, Never>?
    @ObservationIgnored private var upcoming: AmpSession?
    private let logger = Logger(subsystem: "io.github.pwhofman.tanto", category: "editor")

    /// Creates a model that is not connected.
    ///
    /// - Parameter map: The parameter table.
    public init(map: ParameterMap) {
        self.map = map
        pages = Self.pageSources.map { group in
            group.map { title, section, pages in
                Page(
                    title: title,
                    parameters: map.table.parameters.filter { parameter in
                        (section == nil || parameter.section == section) && parameter.page.map(pages.contains) == true
                            && parameter.written && parameter.kind != .text
                    })
            }
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
        // The session exists from now on, so that a Panic pressed before this connect's turn reaches it: the session
        // sends VOLUME 0 as soon as editor mode is on.
        let session = AmpSession(transport: transport, timing: timing)
        upcoming = session
        connection = .connecting
        await serially { [self] in await connectNow(session) }
    }

    /// Runs connection changes one after another: connects and disconnects never overlap, so a connect cannot finish
    /// after a newer one or after a disconnect, and the amp gets the editor-mode flags in order.
    private func serially(_ change: @escaping @MainActor () async -> Void) async {
        let previous = lastChange
        let task = Task { @MainActor in
            await previous?.value
            await change()
        }
        lastChange = task
        await task.value
    }

    private func connectNow(_ session: AmpSession) async {
        await letGo()
        connection = .connecting
        self.session = session
        if upcoming === session {
            upcoming = nil
        }
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
            let safety = try SafetyGuard(
                session: session, map: map, ceilingPercent: ceilingPercent ?? 100, rampDuration: .seconds(2))
            self.safety = safety
            librarian = Librarian(session: session, safety: safety, map: map)
            hasUnsavedEdits = false
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
        // The check and the connect are one change, so that a port change and a retry cannot both connect.
        await serially { [self] in
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
                await connectNow(AmpSession(transport: transport, timing: timing))
            } catch {
                connection = .failed(Self.message(for: error))
            }
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
        librarian = nil
        pendingSwitch = nil
        switchTarget = nil
        undoEdits = []
        redoEdits = []
        connection = .notConnected
    }

    /// Stops the guard, switches editor mode off if the amp is still there, and forgets the connection. A connect that
    /// is running finishes first.
    public func disconnect() async {
        await serially { [self] in await letGo() }
    }

    private func letGo() async {
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
        librarian = nil
        pendingSwitch = nil
        switchTarget = nil
        undoEdits = []
        redoEdits = []
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

    /// Where Tone Studio puts a parameter on its page for the current types.
    ///
    /// - Parameter parameter: A parameter.
    /// - Returns: Its position, or `nil` if only the front panel shows it.
    public func position(of parameter: Parameter) -> Parameter.Position? {
        parameter.position { values[$0] }
    }

    /// The ceiling of a guarded parameter.
    ///
    /// - Parameter parameter: A parameter.
    /// - Returns: The ceiling, or `nil` for unguarded parameters and without a ceiling.
    public func ceiling(of parameter: Parameter) -> Int? {
        ceilingPercent.flatMap { Ceiling.value(of: parameter, percent: $0) }
    }

    /// Asks `SafetyGuard` for a new value; a refusal is kept as the control's message.
    ///
    /// - Parameters:
    ///   - parameter: A parameter from `pages` or the front panel.
    ///   - value: The displayed value.
    public func set(_ parameter: Parameter, to value: Int) async {
        let panics = panicCount
        let before = values[parameter.offset]
        if await write(parameter, to: value), let before, before != value {
            record(.value(parameter, before), since: panics)
        }
    }

    // `set(_:to:)` without noting the edit for Undo; `false` if it was refused.
    private func write(_ parameter: Parameter, to value: Int) async -> Bool {
        guard let safety else {
            refusals[parameter.offset] = "Not connected"
            return false
        }
        do {
            try await safety.set(parameter, to: value)
            refusals[parameter.offset] = nil
            hasUnsavedEdits = true
            return true
        } catch {
            refusals[parameter.offset] = Self.message(for: error)
            return false
        }
    }

    /// CONTOUR as Tone Studio's knob shows it: 0 for OFF, 1–3 for the selected contour; `nil` before the live patch is
    /// read.
    public var contour: Int? {
        guard let (onOff, select) = contourParameters, let on = value(of: onOff), let selected = value(of: select)
        else {
            return nil
        }
        return on == onOff.minimum ? 0 : selected - select.minimum + 1
    }

    /// Sets CONTOUR as Tone Studio's knob does: it switches CONTOUR on or off if that changes, then selects the contour,
    /// both through `SafetyGuard`. After a Panic during the switch, the selection is left as it was.
    ///
    /// - Parameter choice: 0 for OFF, 1–3 for a contour.
    public func setContour(_ choice: Int) async {
        let panics = panicCount
        let before = contour
        await applyContour(choice)
        if let before, before != choice {
            record(.contour(before), since: panics)
        }
    }

    // `setContour(_:)` without noting the edit for Undo.
    private func applyContour(_ choice: Int) async {
        guard let (onOff, select) = contourParameters else { return }
        let panics = panicCount
        let on = (value(of: onOff) ?? onOff.minimum) != onOff.minimum
        if (choice > 0) != on {
            _ = await write(onOff, to: choice > 0 ? onOff.maximum : onOff.minimum)
        }
        guard choice > 0, panicCount == panics else { return }
        _ = await write(select, to: select.minimum + choice - 1)
    }

    // CONTOUR SW and CONTOUR SELECT, which the panel's CONTOUR knob sets together.
    private var contourParameters: (Parameter, Parameter)? {
        guard let onOff = map.parameter(block: "Patch_1", prm: "PRM_CONTOUR_SW"),
            let select = map.parameter(block: "Patch_1", prm: "PRM_CONTOUR_SELECT")
        else { return nil }
        return (onOff, select)
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
        let panics = panicCount
        let selection = colourSelection(of: button)
        let before = selection.flatMap { values[$0.offset] }
        guard await pressNow(button) else { return }
        if button == .variation {
            record(.variation, since: panics)
        } else if let selection, let before {
            record(.value(selection, before), since: panics)
        }
    }

    // `press(_:)` without noting the edit for Undo; `false` if it was refused.
    private func pressNow(_ button: PanelButton) async -> Bool {
        guard let safety else {
            buttonRefusals[button] = "Not connected"
            return false
        }
        do {
            try await safety.press(button)
            buttonRefusals[button] = nil
            hasUnsavedEdits = true
            return true
        } catch {
            buttonRefusals[button] = Self.message(for: error)
            return false
        }
    }

    // The colour selection that a colour button moves, as Tone Studio's EFFECTS page writes it; `nil` for VARIATION.
    private func colourSelection(of button: PanelButton) -> Parameter? {
        let effect: String? =
            switch button {
            case .variation: nil
            case .booster: "BOOST"
            case .mod: "MOD"
            case .fx: "FX"
            case .delay: "DELAY"
            case .reverb: "REVERB"
            }
        return effect.flatMap { map.parameter(block: "Patch_2", prm: "PRM_FXBOX_SEL_\($0)") }
    }

    /// Panic: the VOLUME knob to 0 as the next message (design spec, section 5.5). While connecting, VOLUME 0 goes out
    /// as soon as the amp is in editor mode.
    public func panic() async {
        panicCount += 1
        // An undo must never bring back what Panic took away.
        undoEdits = []
        redoEdits = []
        let volumeKnob = map.parameter(block: "Status", prm: "PRM_KNOB_POS_VOLUME")
        // A session still waiting for its turn to connect sends VOLUME 0 as soon as editor mode is on.
        if let upcoming, let volumeKnob {
            do {
                try await upcoming.panic(volumeKnob: volumeKnob)
            } catch {
                logger.error("Panic not sent: \(error)")
            }
        }
        if let safety {
            await safety.panic()
        } else if let session, let volumeKnob {
            do {
                try await session.panic(volumeKnob: volumeKnob)
            } catch {
                logger.error("Panic not sent: \(error)")
            }
        }
    }

    /// Taps a TAP button through `SafetyGuard`; a refusal is kept as the button's message.
    ///
    /// - Parameter button: The TAP button.
    public func tap(_ button: TapButton) async {
        guard let safety else {
            tapRefusals[button] = "Not connected"
            return
        }
        let panics = panicCount
        let time = map.parameter(block: button.block, prm: "PRM_DLY_COMMON_DLY_TIME")
        let before = time.flatMap { values[$0.offset] }
        do {
            try await safety.tap(button)
            tapRefusals[button] = nil
            hasUnsavedEdits = true
            if let time, let before {
                record(.value(time, before), since: panics)
            }
        } catch {
            tapRefusals[button] = Self.message(for: error)
        }
    }

    /// Renames the live patch.
    ///
    /// - Parameter name: At most 16 characters from space to `}`.
    public func rename(to name: String) async {
        let panics = panicCount
        let before = liveName
        if await renameNow(name), before != name {
            record(.name(before), since: panics)
        }
    }

    // `rename(to:)` without noting the edit for Undo; `false` if it was refused.
    private func renameNow(_ name: String) async -> Bool {
        guard let safety else {
            nameRefusal = "Not connected"
            return false
        }
        do {
            try await safety.rename(to: name)
            nameRefusal = nil
            hasUnsavedEdits = true
            return true
        } catch {
            nameRefusal = Self.message(for: error)
            return false
        }
    }

    /// What Undo would undo, e.g. "BASS"; `nil` if there is nothing to undo.
    public var undoTitle: String? {
        undoEdits.last.map { Self.title(of: $0.change) }
    }

    /// What Redo would redo; `nil` if there is nothing to redo.
    public var redoTitle: String? {
        redoEdits.last.map { Self.title(of: $0.change) }
    }

    /// Undoes Tanto's last edit of the live sound. It goes through `SafetyGuard` as any edit: ceilings, ramps and the
    /// soft switch apply.
    public func undo() async {
        guard let edit = undoEdits.popLast() else { return }
        if let now = state(like: edit.change) {
            redoEdits.append(Edit(change: now, time: nil))
        }
        await restore(edit.change)
    }

    /// Does the last undone edit again, as `undo()` does.
    public func redo() async {
        guard let edit = redoEdits.popLast() else { return }
        if let now = state(like: edit.change) {
            undoEdits.append(Edit(change: now, time: nil))
        }
        await restore(edit.change)
    }

    // Notes an edit for Undo, unless Panic came meanwhile. An edit of the same thing less than a second after the last
    // joins it, so that a drag or a scroll is one step; VARIATION's presses stay apart, as each one toggles.
    private func record(_ before: Edit.Change, since panics: Int) {
        guard panicCount == panics else { return }
        let now = ContinuousClock.now
        redoEdits = []
        if before != .variation, let last = undoEdits.last, let time = last.time, now - time < .seconds(1),
            state(like: last.change).map({ Self.sameThing($0, before) }) == true
        {
            undoEdits[undoEdits.count - 1].time = now
        } else {
            undoEdits.append(Edit(change: before, time: now))
        }
    }

    // The present state of what `change` changes; `nil` if a value is not known.
    private func state(like change: Edit.Change) -> Edit.Change? {
        switch change {
        case .value(let parameter, _): values[parameter.offset].map { .value(parameter, $0) }
        case .contour: contour.map(Edit.Change.contour)
        case .name: .name(liveName)
        case .variation: .variation
        }
    }

    private static func sameThing(_ a: Edit.Change, _ b: Edit.Change) -> Bool {
        switch (a, b) {
        case (.value(let first, _), .value(let second, _)): first == second
        case (.contour, .contour), (.name, .name): true
        default: false
        }
    }

    private func restore(_ change: Edit.Change) async {
        switch change {
        case .value(let parameter, let value): _ = await write(parameter, to: value)
        case .contour(let choice): await applyContour(choice)
        case .name(let name): _ = await renameNow(name)
        case .variation: _ = await pressNow(.variation)
        }
    }

    private static func title(of change: Edit.Change) -> String {
        switch change {
        case .value(let parameter, _):
            // The colour selections have no label of their own.
            parameter.label.isEmpty ? "\(parameter.section?.uppercased() ?? "") COLOR" : parameter.label
        case .contour: "CONTOUR"
        case .name: "Name"
        case .variation: "VARIATION"
        }
    }

    /// Asks to switch to a channel. The switch happens at once, unless the live patch has unsaved edits or the channel's
    /// front-panel volumes lie above their ceilings: then `pendingSwitch` holds the question, the unsaved edits first.
    /// A request while another switch reads or loads becomes its target and follows it, so the latest request wins; a
    /// request while a question is open is dropped.
    ///
    /// - Parameter slot: 0 = PANEL, 1–4 = A1–A4, 5–8 = B1–B4.
    public func requestSwitch(to slot: Int) async {
        guard pendingSwitch == nil else { return }
        let running = switchTarget != nil
        switchTarget = slot
        guard !running else { return }
        await prepareSwitch(to: slot)
    }

    /// Answers the question of `pendingSwitch`; after the question about unsaved edits the ceiling is checked.
    ///
    /// - Parameter proceed: `true` to go on with the switch, `false` to keep the current channel.
    public func answerSwitch(_ proceed: Bool) async {
        guard let pending = pendingSwitch else { return }
        pendingSwitch = nil
        guard proceed else {
            switchTarget = nil
            return
        }
        switch pending.question {
        case .unsavedEdits:
            await checkCeiling(before: pending.slot)
        case .valuesAboveCeiling:
            await switchChannel(to: pending.slot)
        }
        await finishSwitch(to: pending.slot)
    }

    private func prepareSwitch(to slot: Int) async {
        if hasUnsavedEdits {
            pendingSwitch = PendingSwitch(slot: slot, question: .unsavedEdits)
        } else {
            await checkCeiling(before: slot)
        }
        await finishSwitch(to: slot)
    }

    /// Ends a switch to `slot`, or its question: a request for another channel made meanwhile starts now.
    private func finishSwitch(to slot: Int) async {
        guard pendingSwitch == nil else { return }
        if let latest = switchTarget, latest != slot {
            await prepareSwitch(to: latest)
        } else {
            switchTarget = nil
        }
    }

    /// Whether ⌘S can save the live sound to the current channel: one of A1–B4 with unsaved edits, and no switch or save
    /// under way.
    public var canSaveToCurrentChannel: Bool {
        connection == .connected && currentChannel.map { (1...8).contains($0) } == true && hasUnsavedEdits
            && switchTarget == nil && !isSaving
    }

    /// Saves the live sound to the current channel at once, as ⌘S does (design spec, section 7).
    public func saveToCurrentChannel() async {
        guard canSaveToCurrentChannel, let slot = currentChannel else { return }
        await save(to: slot)
    }

    /// Saves the live sound to a channel; the window has asked before overwriting it, except for ⌘S.
    ///
    /// - Parameter slot: 1–4 = A1–A4, 5–8 = B1–B4.
    public func save(to slot: Int) async {
        guard let librarian else { return notConnected() }
        // The amp's confirmation is awaited one save at a time.
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            channelNames[slot] = try await librarian.save(to: slot)
            librarianMessage = nil
        } catch {
            librarianMessage = "Not saved: \(Self.message(for: error))"
            await readNames([slot])
        }
    }

    /// Renames a stored channel; the sound does not change.
    ///
    /// - Parameters:
    ///   - slot: 1–4 = A1–A4, 5–8 = B1–B4.
    ///   - name: At most 16 characters from space to `}`.
    public func rename(_ slot: Int, to name: String) async {
        guard let librarian else { return notConnected() }
        do {
            try await librarian.rename(slot, to: name)
            channelNames[slot] = PatchName.decode(Array(name.utf8))
            librarianMessage = nil
        } catch {
            librarianMessage = "Not renamed: \(Self.message(for: error))"
        }
    }

    /// Reads channels 1–8 into a backup.
    ///
    /// - Returns: The backup, or `nil` with `librarianMessage` saying why.
    public func backup() async -> ChannelBackup? {
        guard let librarian else {
            notConnected()
            return nil
        }
        do {
            return try await librarian.backup()
        } catch {
            librarianMessage = "No backup: \(Self.message(for: error))"
            return nil
        }
    }

    /// Checks a written backup file by reading it like a restore would and comparing it with what was read from the
    /// amp; `librarianMessage` reports the outcome.
    ///
    /// - Parameters:
    ///   - data: The file's contents, read back after writing.
    ///   - backup: The backup that was written.
    /// - Returns: `true` if the file holds exactly that backup.
    public func checkBackupFile(_ data: Data, against backup: ChannelBackup) -> Bool {
        do {
            let read = try ChannelBackup.load(data, map: map)
            let same = read.channels == backup.channels
            librarianMessage =
                same
                ? "Backed up channels 1–8; the file reads back the same."
                : "The backup file differs from what was read from the amp."
            return same
        } catch {
            librarianMessage = "The backup file cannot be read back: \(Self.message(for: error))"
            return false
        }
    }

    /// Reads a backup file for a restore; every check runs before anything can be written.
    ///
    /// - Parameter data: The file's contents.
    /// - Returns: The backup, or `nil` with `librarianMessage` saying why.
    public func loadBackup(_ data: Data) -> ChannelBackup? {
        do {
            return try ChannelBackup.load(data, map: map)
        } catch {
            librarianMessage = "This file cannot be restored: \(Self.message(for: error))"
            return nil
        }
    }

    /// Restores channels 1–8 and reads them back; the window has asked first, with MASTER at minimum.
    ///
    /// - Parameter backup: A backup from `loadBackup(_:)`.
    public func restore(_ backup: ChannelBackup) async {
        guard let librarian else { return notConnected() }
        do {
            let differences = try await librarian.restore(backup)
            librarianMessage =
                differences.isEmpty
                ? "Restored channels 1–8; they read back the same."
                : "Restored channels 1–8, but these read back differently: "
                    + differences.map { "\(EditorModel.channelLabel($0.slot)) \($0.block)" }.joined(separator: ", ")
        } catch {
            librarianMessage = "Restore stopped: \(Self.message(for: error))"
        }
        await readNames(Array(1...8))
    }

    /// Clears `librarianMessage` once the window has shown it.
    public func dismissLibrarianMessage() {
        librarianMessage = nil
    }

    /// The name of a channel as the amp shows it: PANEL, A1–A4, B1–B4.
    ///
    /// - Parameter slot: 0–8.
    /// - Returns: The label.
    public static func channelLabel(_ slot: Int) -> String {
        slot == 0 ? "PANEL" : "\(slot <= 4 ? "A" : "B")\((slot - 1) % 4 + 1)"
    }

    private func checkCeiling(before slot: Int) async {
        guard let librarian else { return notConnected() }
        // Without a ceiling no stored volume lies above it, so the channel need not be read first.
        guard ceilingPercent != nil else { return await switchChannel(to: slot) }
        do {
            let above = try await librarian.valuesAboveCeiling(slot)
            if above.isEmpty {
                await switchChannel(to: slot)
            } else {
                pendingSwitch = PendingSwitch(slot: slot, question: .valuesAboveCeiling(above))
            }
        } catch {
            librarianMessage = "Not switched: \(Self.message(for: error))"
        }
    }

    private func switchChannel(to slot: Int) async {
        guard let librarian else { return notConnected() }
        do {
            try await librarian.select(slot)
            librarianMessage = nil
        } catch {
            librarianMessage = "Not switched: \(Self.message(for: error))"
        }
    }

    private func readNames(_ slots: [Int]) async {
        guard let librarian else { return }
        for slot in slots where channelNames.indices.contains(slot) {
            do {
                channelNames[slot] = try await librarian.name(slot)
            } catch {
                logger.error("name of channel \(slot) not read: \(error)")
            }
        }
    }

    private func notConnected() {
        librarianMessage = "Not connected"
    }

    /// Whether changing the ceiling needs the user's confirmation: raising it or switching it off does, lowering it or
    /// switching it on does not.
    ///
    /// - Parameter percent: The new percentage, or `nil` to switch the ceiling off.
    /// - Returns: `true` when the change lets Tanto raise guarded values further.
    public func needsConfirmation(toSetCeilingPercent percent: Int?) -> Bool {
        (percent ?? 100) > (ceilingPercent ?? 100)
    }

    /// Changes the ceiling. Without one, `SafetyGuard` works as at 100 %: every guarded value can reach its maximum,
    /// and rises are still ramped.
    ///
    /// - Parameter percent: 0–100 in steps of 5, or `nil` for no ceiling.
    /// - Throws: `SafetyError.invalidCeiling`.
    public func setCeilingPercent(_ percent: Int?) async throws {
        if let percent, !Ceiling.isValid(percent: percent) { throw SafetyError.invalidCeiling(percent) }
        try await safety?.setCeilingPercent(percent ?? 100)
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
            hasUnsavedEdits = false
            undoEdits = []
            redoEdits = []
        case .patchSaved(let slot):
            Task { await readNames(slot.map { [$0] } ?? Array(1...8)) }
        case .editedOnAmp:
            hasUnsavedEdits = true
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
            case .notWritable, .outOfRange, .outsideChannel: "Not allowed"
            case .noSuchChannel(let slot): "There is no channel \(slot)"
            }
        case let error as AmpError:
            switch error {
            case .notAKatana: "The connected device is not a Katana MkII"
            case .noIdentityReply, .timeout: "The amp does not answer"
            case .unsupportedCommunicationLevel(let level): "Unsupported editor communication level \(level)"
            case .noSaveConfirmation: "The amp did not confirm the save"
            }
        case let error as CoreMIDIError:
            error.description
        case let error as BackupError:
            switch error {
            case .unreadable: "it is not a Tanto backup"
            case .unknownFormat(let format): "format \(format) is unknown"
            case .otherModel(let model): "it is for \(model)"
            case .channels(let slots): "it must hold channels 1–8 once each, not \(slots)"
            case .missingBlock(let slot, let block): "\(channelLabel(slot)) lacks \(block)"
            case .unknownBlock(let slot, let block): "\(channelLabel(slot)) has an unknown block \(block)"
            case .blockLength(let slot, let block, let expected, let found):
                "\(channelLabel(slot)) \(block) has \(found) bytes instead of \(expected)"
            case .invalidBytes(let slot, let block): "\(channelLabel(slot)) \(block) holds invalid bytes"
            case .nameMismatch(let slot): "the name of \(channelLabel(slot)) does not match its data"
            }
        case let error as LibrarianError:
            switch error {
            case .restoreStopped(let slot):
                slot.map { "channels A1 to \(channelLabel($0)) were written" } ?? "no channel was written completely"
            }
        default:
            "\(error)"
        }
    }
}
