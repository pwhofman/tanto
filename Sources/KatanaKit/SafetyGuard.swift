import os

/// Why `SafetyGuard` refuses a request. Nothing is sent.
public enum SafetyError: Error, Equatable, Sendable {
    /// No Tone Studio control writes this parameter, or it does not come from the bundled table.
    case notWritable(String)
    /// The value lies outside the parameter's range or, for a picker, is not one of its options.
    case outOfRange(String, Int)
    /// The value would raise a guarded parameter above its ceiling (design spec, section 5.2).
    case aboveCeiling(String, value: Int, ceiling: Int)
    /// Switches and pickers need the VOLUME knob at or below its ceiling (design spec, section 5.3).
    case volumeAboveCeiling(volume: Int, ceiling: Int)
    /// The live patch has not been read yet, the amp is sending a new channel's patch, or the guard has stopped.
    case notReady
    /// A Panic came while the request was being decided; the request is dropped.
    case overtakenByPanic
    /// The ceiling must be 0–100 % in steps of 5 %.
    case invalidCeiling(Int)
    /// The parameter table does not fit the guard, e.g. it has no guarded VOLUME knob.
    case invalidTable(String)
    /// The session sends faster than Tone Studio's 20 ms spacing.
    case invalidTiming
}

/// The only way to change the amp's sound (design spec, section 5).
///
/// All writes go through one pump, one message at a time, in this order: the VOLUME dips of soft switches and the
/// guard's own corrections, the changes of soft switches, changes that make the amp quieter, and finally those that
/// make it louder. A change in the direction that makes a parameter louder (`Parameter.louder`) rises no faster than a
/// full sweep in `rampDuration`, unless the gradual rise is off; a guarded parameter never rises above its ceiling. A
/// soft-switch change is only sent while the VOLUME knob is at 0. Panic goes to the session directly and passes
/// everything.
///
/// Every write carries what it was decided on, and the session drops it if the amp reported a change of the parameter
/// meanwhile, switched channels, or a Panic came. A change reported by the amp ends the guard's work on the parameter;
/// a channel change ends all of it. The guard judges a request against the lowest value the amp may hold, which can be
/// lower than the copy of the live patch when a report from the amp crossed a write of Tanto's. It then reads the value
/// back once the parameter is quiet, and if the amp holds Tanto's value above the amp's own (the knob's, or the new
/// channel's stored value), it writes the amp's own value, which is lower.
public actor SafetyGuard {
    /// How long after a write of Tanto's a report from the amp may still describe a change made before the write
    /// arrived, so that the write won on the amp.
    static let crossingWindow = Duration.milliseconds(100)
    /// How long a parameter must be quiet before the guard reads it back after a possible crossing.
    static let quietPeriod = Duration.milliseconds(150)
    /// The shortest time in which the gradual rise lets a parameter get louder across its whole range (design spec,
    /// section 5.2).
    public static let fullSweep = Duration.milliseconds(500)

    /// The ceiling as a percentage of a guarded parameter's travel.
    public private(set) var ceilingPercent: Int
    /// Whether rises are gradual; without, they go out at once, as decreases do.
    public private(set) var gradualRise: Bool

    private let session: AmpSession
    private let map: ParameterMap
    private let volumeKnob: Parameter
    private let rampDuration: Duration
    private let clock = ContinuousClock()
    private let logger = Logger(subsystem: "io.github.pwhofman.tanto", category: "safety")
    private var stopped = false
    private var panics = 0
    private var panicsInFlight = 0
    private var generation: Int?
    private var targets: [Int: Int] = [:]
    // Per parameter: the number of amp reports when the guard took it on.
    private var seenReports: [Int: Int] = [:]
    private var urgent: [Write] = []
    private var switches: [Write] = []
    private var volumeRestore: Int?
    private var written: [Int: Written] = [:]
    private var inFlight: [Int: Int] = [:]
    private var lastWriteTime: [Int: ContinuousClock.Instant] = [:]
    private var suspects: [Int: Suspect] = [:]
    private var suspectCount = 0
    private var pump: Task<Void, Never>?
    private var wake: CheckedContinuation<Void, Never>?
    private var sleepCount = 0
    // Counts of pump rounds, writes, sleeps and stopped work, for tests.
    private(set) var statistics: [String: Int] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    private struct Write {
        let parameter: Parameter
        let value: Int
        let priority: WritePriority
        let basis: WriteBasis
        // For an effect knob switched on: the value to ramp to once the knob is at 0.
        var then: Int?
        // A front-panel button to press instead of writing `value`; `parameter` is then the button's LED.
        var press: PanelButton?
    }

    // The last value Tanto wrote to a parameter that the amp may still hold.
    private struct Written {
        let value: Int
        let time: ContinuousClock.Instant
        let reportCount: Int
    }

    // A write of Tanto's that a change on the amp may have crossed; the guard reads the parameter back.
    private struct Suspect {
        let id: Int
        let written: Int
        let reference: Reference
        var quietSince: ContinuousClock.Instant
        var verifying = false
    }

    private enum Reference {
        // The amp's own value is the knob's last report.
        case knob
        // The amp's own value is the stored value of this channel.
        case channel(Int)
    }

    /// Creates a guard with the gradual rise of the design spec: a full sweep of a guarded parameter takes at least
    /// `fullSweep`.
    ///
    /// - Parameters:
    ///   - session: The connection, with the live patch read.
    ///   - map: The bundled parameter table.
    ///   - ceilingPercent: The ceiling, 0–100 in steps of 5; 100 lets every guarded parameter reach its maximum, as the
    ///     app's setting does while its ceiling is off (design spec, section 5.2).
    /// - Throws: `SafetyError.invalidCeiling`, `.invalidTable`, or `.invalidTiming` if the session's spacing is below
    ///   20 ms.
    public init(session: AmpSession, map: ParameterMap, ceilingPercent: Int = 50) throws {
        guard session.timing.spacing >= SessionTiming.katana.spacing else { throw SafetyError.invalidTiming }
        try self.init(session: session, map: map, ceilingPercent: ceilingPercent, rampDuration: Self.fullSweep)
    }

    /// Creates a guard with any ramp duration and without checking the session's spacing; for tests and for
    /// `EditorModel`, whose timing only tests can change.
    ///
    /// - Parameters:
    ///   - session: The connection, with the live patch read.
    ///   - map: The bundled parameter table.
    ///   - ceilingPercent: The ceiling, 0–100 in steps of 5.
    ///   - rampDuration: How long a full sweep of a guarded parameter takes at least.
    ///   - gradualRise: Whether rises are gradual.
    /// - Throws: `SafetyError.invalidCeiling` or `.invalidTable`.
    init(
        session: AmpSession, map: ParameterMap, ceilingPercent: Int = 50, rampDuration: Duration,
        gradualRise: Bool = true
    ) throws {
        guard Ceiling.isValid(percent: ceilingPercent) else { throw SafetyError.invalidCeiling(ceilingPercent) }
        guard let volumeKnob = map.parameter(block: "Status", prm: "PRM_KNOB_POS_VOLUME"), volumeKnob.guarded,
            volumeKnob.kind == .numeric
        else {
            throw SafetyError.invalidTable("no guarded VOLUME knob")
        }
        if let button = PanelButton.allCases.first(where: { map.parameter(block: "Status", prm: $0.led) == nil }) {
            throw SafetyError.invalidTable("no \(button.led)")
        }
        if let flat = map.table.parameters.first(where: { $0.louder != nil && $0.maximum <= $0.minimum }) {
            throw SafetyError.invalidTable("\(flat.prm) has no range")
        }
        if let guarded = map.table.parameters.first(where: { $0.guarded && $0.louder != .up }) {
            throw SafetyError.invalidTable("\(guarded.prm) is guarded but does not get louder upwards")
        }
        self.session = session
        self.map = map
        self.volumeKnob = volumeKnob
        self.ceilingPercent = ceilingPercent
        self.rampDuration = rampDuration
        self.gradualRise = gradualRise
    }

    /// Changes the ceiling. Values already above a lower ceiling stay; they can only be lowered.
    ///
    /// - Parameter percent: 0–100 in steps of 5.
    /// - Throws: `SafetyError.invalidCeiling`.
    public func setCeilingPercent(_ percent: Int) throws {
        guard Ceiling.isValid(percent: percent) else { throw SafetyError.invalidCeiling(percent) }
        ceilingPercent = percent
    }

    /// Turns the gradual rise on or off; a rise under way goes on under the new rule.
    ///
    /// - Parameter on: Whether rises are gradual.
    public func setGradualRise(_ on: Bool) {
        gradualRise = on
        startPump()
    }

    /// The highest value Tanto may raise a guarded parameter to (`Ceiling.value(of:percent:)`).
    ///
    /// - Parameter parameter: Any parameter.
    /// - Returns: The ceiling, or `nil` for unguarded parameters.
    public func ceiling(of parameter: Parameter) -> Int? {
        Ceiling.value(of: parameter, percent: ceilingPercent)
    }

    /// Asks for a new value. Numeric values move as section 5.2 of the design spec allows; switches and pickers use
    /// the soft switch of section 5.3. The call returns once the request is accepted; the writes follow.
    ///
    /// - Parameters:
    ///   - parameter: A parameter from the bundled table that Tone Studio writes.
    ///   - value: The displayed value.
    /// - Throws: `SafetyError` if the request is refused.
    public func set(_ parameter: Parameter, to value: Int) async throws {
        guard let known = map.parameter(atOffset: parameter.offset), known == parameter, known.written,
            known.kind != .text
        else {
            throw SafetyError.notWritable(parameter.prm)
        }
        guard (known.minimum...known.maximum).contains(value),
            known.options?.contains(where: { $0.value == value }) ?? true
        else {
            throw SafetyError.outOfRange(known.prm, value)
        }
        let snapshot = try await requestSnapshot(of: [known])
        guard let view = snapshot.views[known.offset], let quietest = quietestPossible(known, view),
            let loudest = loudestPossible(known, view)
        else {
            throw SafetyError.notReady
        }
        if known.kind != .numeric {
            try softSwitch(known, to: value, snapshot)
        } else {
            if loudness(value, known) > loudness(quietest, known), let ceiling = ceiling(of: known), value > ceiling {
                throw SafetyError.aboveCeiling(known.prm, value: value, ceiling: ceiling)
            }
            if known.switchesEffectOffBelowZero, value >= 0 ? quietest < 0 : loudest >= 0 {
                // The effect goes on or off: a soft switch, and once on, a ramp the rest of the way.
                try softSwitch(known, to: min(value, 0), snapshot, then: value > 0 ? value : nil)
            } else {
                if known == volumeKnob {
                    volumeRestore = nil
                }
                seenReports[known.offset] = view.reportCount
                targets[known.offset] = value
            }
        }
        startPump()
    }

    /// Presses a front-panel button with the soft switch of section 5.3 of the design spec: VOLUME dips to 0, the press
    /// goes out, and VOLUME comes back. The amp then reports what changed, e.g. the next colour.
    ///
    /// - Parameter button: The button.
    /// - Throws: `SafetyError` if the press is refused.
    public func press(_ button: PanelButton) async throws {
        guard let led = map.parameter(block: "Status", prm: button.led) else {
            throw SafetyError.invalidTable("no \(button.led)")
        }
        let snapshot = try await requestSnapshot(of: [led])
        guard let current = snapshot.views[led.offset]?.value else { throw SafetyError.notReady }
        try softSwitch(led, to: current, snapshot, press: button)
        startPump()
    }

    /// Panic: drops all of the guard's work and sends the VOLUME knob to 0 ahead of every other message, including
    /// those the session already holds (design spec, section 5.5). Requests still being decided are refused, and nothing
    /// ramps back up.
    public func panic() async {
        logger.notice("panic")
        panics += 1
        dropWork()
        // Panic counts as the latest VOLUME write from now on, so no step can follow its 0 sooner than a ramp allows.
        lastWriteTime[volumeKnob.offset] = clock.now
        panicsInFlight += 1
        defer { panicsInFlight -= 1 }
        do {
            if let reportCount = try await session.panic(volumeKnob: volumeKnob) {
                let now = clock.now
                written[volumeKnob.offset] = Written(value: 0, time: now, reportCount: reportCount)
                lastWriteTime[volumeKnob.offset] = now
                startPump()
            }
        } catch {
            logger.error("Panic not sent: \(error)")
        }
    }

    /// Ends the guard for good: drops all work, refuses every later request, and keeps the session from sending what
    /// the guard has already decided.
    public func stop() async {
        stopped = true
        panics += 1
        dropWork()
        suspects = [:]
        await session.invalidateWrites()
        startPump()
    }

    /// Taps a TAP button. A tap changes only DELAY's or DELAY2's time, never the level, so it needs no soft switch.
    ///
    /// - Parameter button: The TAP button.
    /// - Throws: `SafetyError.notReady` once stopped; an error from the transport.
    public func tap(_ button: TapButton) async throws {
        guard !stopped else { throw SafetyError.notReady }
        try await session.tap(button)
    }

    /// Renames the live patch; the sound does not change.
    ///
    /// - Parameter name: At most 16 characters from space to `}`.
    /// - Throws: `SafetyError.notReady` once stopped; `WriteError.invalidName`; an error from the transport.
    public func rename(to name: String) async throws {
        guard !stopped else { throw SafetyError.notReady }
        try await session.writeLiveName(name)
    }

    /// The guarded values of a stored patch that lie above their ceilings (design spec, section 5.4).
    ///
    /// - Parameter patch: The stored patch, from its first byte.
    /// - Returns: Those values, read-only amp parameters included.
    public func valuesAboveCeiling(in patch: [UInt8]) -> [ParameterValue] {
        map.values(in: patch, at: 0).filter { value in
            guard let ceiling = ceiling(of: value.parameter) else { return false }
            return value.value > ceiling
        }
    }

    /// Waits until every accepted request has been written and every possible crossing has been checked.
    public func settle() async {
        guard pump != nil else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    // One look at the session for a request. Nothing after it suspends, so the decision rests on this snapshot and the
    // guard's own state alone.
    private func requestSnapshot(of parameters: [Parameter]) async throws -> AmpSession.GuardSnapshot {
        guard !stopped else { throw SafetyError.notReady }
        let panicsBefore = panics
        let snapshot = await session.guardSnapshot(of: parameters + [volumeKnob])
        guard panics == panicsBefore else { throw SafetyError.overtakenByPanic }
        guard !stopped else { throw SafetyError.notReady }
        sync(with: snapshot)
        guard snapshot.isValid else { throw SafetyError.notReady }
        return snapshot
    }

    private func softSwitch(
        _ parameter: Parameter, to value: Int, _ snapshot: AmpSession.GuardSnapshot, then: Int? = nil,
        press: PanelButton? = nil
    ) throws {
        guard let current = snapshot.views[parameter.offset]?.value, let volumeView = snapshot.views[volumeKnob.offset],
            let lowestVolume = quietestPossible(volumeKnob, volumeView),
            let highestVolume = loudestPossible(volumeKnob, volumeView)
        else {
            throw SafetyError.notReady
        }
        guard value != current || then != nil || press != nil else { return }
        let restore = volumeRestore ?? targets[volumeKnob.offset] ?? lowestVolume
        let ceiling = ceiling(of: volumeKnob) ?? volumeKnob.maximum
        guard highestVolume <= ceiling, restore <= ceiling else {
            throw SafetyError.volumeAboveCeiling(volume: max(highestVolume, restore), ceiling: ceiling)
        }
        volumeRestore = restore
        seenReports[volumeKnob.offset] = volumeView.reportCount
        targets[volumeKnob.offset] = restore
        targets[parameter.offset] = nil
        urgent.append(
            Write(parameter: volumeKnob, value: 0, priority: .high, basis: snapshot.basis([volumeKnob])))
        switches.append(
            Write(
                parameter: parameter, value: value, priority: .normal, basis: snapshot.basis([volumeKnob, parameter]),
                then: then, press: press))
    }

    private func startPump() {
        if let wake {
            self.wake = nil
            wake.resume()
        }
        guard pump == nil, !stopped else { return }
        pump = Task { await self.run() }
    }

    private func run() async {
        while !stopped {
            statistics["pump iterations", default: 0] += 1
            if let write = await nextWrite() {
                await send(write)
            } else if let deadline = nextDeadline() {
                statistics["sleeps", default: 0] += 1
                await sleep(until: deadline)
            } else if isIdle {
                break
            }
        }
        pump = nil
        let waiters = idleWaiters
        idleWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private var isIdle: Bool {
        targets.isEmpty && urgent.isEmpty && switches.isEmpty && suspects.isEmpty && !hasRecentWrite
    }

    // A write within the crossing window may still be crossed by a report on its way; the pump waits for it.
    private var hasRecentWrite: Bool {
        let now = clock.now
        return written.values.contains { now - $0.time < Self.crossingWindow }
    }

    private func send(_ write: Write) async {
        statistics["writes", default: 0] += 1
        if let button = write.press {
            do {
                if try await !session.press(button, priority: write.priority, basis: write.basis) {
                    statistics["dropped", default: 0] += 1
                    logger.notice("press of \(button.label, privacy: .public) dropped: the amp changed first")
                }
            } catch {
                logger.error("press of \(button.label, privacy: .public) failed: \(error)")
            }
            return
        }
        let offset = write.parameter.offset
        inFlight[offset] = write.value
        defer { inFlight[offset] = nil }
        do {
            if try await session.write(write.value, to: write.parameter, priority: write.priority, basis: write.basis) {
                let now = clock.now
                written[offset] = Written(
                    value: write.value, time: now, reportCount: write.basis.reportCounts[write.parameter] ?? 0)
                lastWriteTime[offset] = now
                if let then = write.then {
                    seenReports[offset] = write.basis.reportCounts[write.parameter] ?? 0
                    targets[offset] = then
                }
            } else {
                statistics["dropped", default: 0] += 1
                logger.notice("write to \(write.parameter.prm, privacy: .public) dropped: the amp changed first")
            }
        } catch {
            logger.error("write to \(write.parameter.prm, privacy: .public) failed: \(error)")
            finish(offset)
            if write.parameter == volumeKnob {
                // Without its dip no switch may go out.
                switches = []
            }
        }
    }

    private func nextWrite() async -> Write? {
        if !urgent.isEmpty {
            return urgent.removeFirst()
        }
        // One look at the session per message.
        let panicsBefore = panics
        let snapshot = await session.guardSnapshot(of: watchedParameters())
        guard panics == panicsBefore, !stopped else { return nil }
        sync(with: snapshot)
        checkSuspects(snapshot)
        guard snapshot.isValid else { return nil }
        // The change of a soft switch follows its dip directly, which keeps the silence short.
        while !switches.isEmpty {
            let write = switches.removeFirst()
            if let volume = snapshot.views[volumeKnob.offset], loudestPossible(volumeKnob, volume) == 0 {
                return write
            }
            logger.notice("switch of \(write.parameter.prm, privacy: .public) dropped: VOLUME is not at 0")
        }
        var quieter: [Write] = []
        var steps: [Write] = []
        for (offset, target) in targets.sorted(by: { $0.key < $1.key }) {
            guard let parameter = map.parameter(atOffset: offset), let view = snapshot.views[offset] else { continue }
            if view.reportCount != seenReports[offset] {
                statistics["stopped: amp report", default: 0] += 1
                logger.notice("\(parameter.prm, privacy: .public) changed on the amp; the guard stops its work on it")
                finish(offset)
                continue
            }
            guard let quietest = quietestPossible(parameter, view), let loudest = loudestPossible(parameter, view)
            else {
                continue
            }
            let basis = snapshot.basis([parameter])
            let goal = loudness(target, parameter)
            let low = loudness(quietest, parameter)
            if goal < low || (goal == low && loudness(loudest, parameter) > low) {
                // Quieter than every value the amp may hold.
                quieter.append(Write(parameter: parameter, value: target, priority: .high, basis: basis))
            } else if goal == low {
                finish(offset)
            } else if parameter.louder == nil {
                steps.append(Write(parameter: parameter, value: target, priority: .normal, basis: basis))
            } else if let ceiling = ceiling(of: parameter), quietest >= ceiling {
                logger.notice("\(parameter.prm, privacy: .public) reached its ceiling; ramp stopped")
                finish(offset)
            } else if isDue(parameter) {
                // Louder than the quietest value the amp may hold by as much as the rise allows, and no further than
                // the target and the ceiling.
                let rise = gradualRise ? riseStep(of: parameter) : parameter.maximum - parameter.minimum
                var step = parameter.louder == .down ? max(quietest - rise, target) : min(quietest + rise, target)
                if let ceiling = ceiling(of: parameter) {
                    step = min(step, ceiling)
                }
                steps.append(Write(parameter: parameter, value: step, priority: .normal, basis: basis))
            }
        }
        return quieter.first ?? steps.first
    }

    // Brings the guard's state up to date with the session: a new channel generation ends all work, and a report
    // after a write of Tanto's either supersedes the write or, if it may have crossed it, makes it a suspect.
    private func sync(with snapshot: AmpSession.GuardSnapshot) {
        if snapshot.generation != generation {
            if generation != nil {
                logger.notice("the amp changed channels; the guard drops its work")
                if let changeTime = snapshot.channelChangeTime, let channel = snapshot.channel {
                    for (offset, entry) in written where changeTime - entry.time < Self.crossingWindow {
                        addSuspect(offset, written: entry.value, reference: .channel(channel), since: changeTime)
                    }
                }
                dropWork()
                written = [:]
                seenReports = [:]
            }
            generation = snapshot.generation
        }
        for (offset, entry) in written {
            guard let view = snapshot.views[offset], view.reportCount != entry.reportCount else { continue }
            if let reportTime = view.reportTime, reportTime - entry.time < Self.crossingWindow {
                if suspects[offset] == nil {
                    addSuspect(offset, written: entry.value, reference: .knob, since: reportTime)
                }
            } else {
                // The amp changed the value after Tanto's write had arrived: the write no longer holds.
                written[offset] = nil
                suspects[offset] = nil
            }
        }
    }

    private func addSuspect(_ offset: Int, written value: Int, reference: Reference, since: ContinuousClock.Instant) {
        suspectCount += 1
        suspects[offset] = Suspect(id: suspectCount, written: value, reference: reference, quietSince: since)
        statistics["suspects", default: 0] += 1
    }

    // Reads a suspect back once it is quiet: no report for `quietPeriod`, and the new channel's patch complete.
    private func checkSuspects(_ snapshot: AmpSession.GuardSnapshot) {
        let now = clock.now
        for (offset, suspect) in suspects where !suspect.verifying {
            guard let parameter = map.parameter(atOffset: offset) else { continue }
            if let reportTime = snapshot.views[offset]?.reportTime, reportTime > suspect.quietSince {
                suspects[offset]?.quietSince = reportTime
                continue
            }
            guard snapshot.isValid, now - suspect.quietSince >= Self.quietPeriod else { continue }
            suspects[offset]?.verifying = true
            verify(parameter, suspect)
        }
    }

    private func verify(_ parameter: Parameter, _ suspect: Suspect) {
        Task {
            do {
                let refreshed = try await session.refresh(parameter)
                var reference: Int?
                switch suspect.reference {
                case .knob:
                    reference = refreshed.reportedValue
                case .channel(let slot):
                    let stored = try await session.read(
                        Address.userPatch(slot).advanced(by: parameter.offset), size: parameter.encoding.byteCount)
                    reference = parameter.value(fromRaw: parameter.encoding.decode(stored))
                }
                self.verified(parameter, suspect, refreshed, reference: reference)
            } catch {
                logger.error("\(parameter.prm, privacy: .public) not read back: \(error)")
                self.dropSuspect(parameter.offset, id: suspect.id)
            }
            self.startPump()
        }
    }

    private func verified(
        _ parameter: Parameter, _ suspect: Suspect, _ refreshed: AmpSession.Refreshed, reference: Int?
    ) {
        guard let current = suspects[parameter.offset], current.id == suspect.id else { return }
        suspects[parameter.offset] = nil
        // The read is the truth now.
        written[parameter.offset] = nil
        guard !stopped, parameter.louder != nil, parameter.kind == .numeric, refreshed.value == suspect.written,
            let reference, loudness(reference, parameter) < loudness(refreshed.value, parameter)
        else {
            return
        }
        logger.notice(
            "\(parameter.prm, privacy: .public) holds Tanto's \(refreshed.value) above the amp's own \(reference); setting it back"
        )
        statistics["corrections", default: 0] += 1
        urgent.append(
            Write(
                parameter: parameter, value: reference, priority: .high,
                basis: WriteBasis(
                    generation: refreshed.generation, panics: refreshed.panics,
                    reportCounts: [parameter: refreshed.reportCount])))
    }

    private func dropSuspect(_ offset: Int, id: Int) {
        guard suspects[offset]?.id == id else { return }
        suspects[offset] = nil
    }

    private func dropWork() {
        targets = [:]
        switches = []
        urgent = []
        volumeRestore = nil
    }

    private func finish(_ offset: Int) {
        targets[offset] = nil
        if offset == volumeKnob.offset {
            volumeRestore = nil
        }
    }

    // The parameters the pump looks at: its targets and switches, VOLUME, recent writes and suspects.
    private func watchedParameters() -> [Parameter] {
        let offsets = Set(targets.keys).union(written.keys).union(suspects.keys).union(switches.map(\.parameter.offset))
            .union([volumeKnob.offset])
        return offsets.sorted().compactMap { map.parameter(atOffset: $0) }
    }

    // The values the amp may hold for a parameter: its copy, a write of Tanto's that may still hold there, a write on
    // its way, a suspect's write, and 0 for VOLUME while a Panic is on its way.
    private func possibleValues(_ parameter: Parameter, _ view: AmpSession.GuardView) -> [Int] {
        var values = [view.value, written[parameter.offset]?.value, inFlight[parameter.offset]].compactMap { $0 }
        if let suspect = suspects[parameter.offset] {
            values.append(suspect.written)
        }
        if parameter == volumeKnob, panicsInFlight > 0 {
            values.append(0)
        }
        return values
    }

    // Values in loudness order: a parameter that gets louder downwards counts by its negated value.
    private func loudness(_ value: Int, _ parameter: Parameter) -> Int {
        parameter.louder == .down ? -value : value
    }

    private func quietestPossible(_ parameter: Parameter, _ view: AmpSession.GuardView) -> Int? {
        possibleValues(parameter, view).min { loudness($0, parameter) < loudness($1, parameter) }
    }

    private func loudestPossible(_ parameter: Parameter, _ view: AmpSession.GuardView) -> Int? {
        possibleValues(parameter, view).max { loudness($0, parameter) < loudness($1, parameter) }
    }

    // How far one message may raise a parameter: as far as a full sweep in `rampDuration` gets in the session's spacing,
    // at least one unit.
    private func riseStep(of parameter: Parameter) -> Int {
        let range = parameter.maximum - parameter.minimum
        return max(1, Int((Double(range) * (session.timing.spacing / rampDuration)).rounded()))
    }

    // When the next step of a rise may go out, so that the parameter gets louder no faster than a full sweep in
    // `rampDuration`; `nil` if it may go now: the parameter was never written, or the gradual rise is off.
    private func dueTime(of parameter: Parameter) -> ContinuousClock.Instant? {
        guard gradualRise else { return nil }
        let range = parameter.maximum - parameter.minimum
        return lastWriteTime[parameter.offset]?.advanced(by: rampDuration * riseStep(of: parameter) / range)
    }

    private func isDue(_ parameter: Parameter) -> Bool {
        guard let due = dueTime(of: parameter) else { return true }
        return due <= clock.now
    }

    private func nextDeadline() -> ContinuousClock.Instant? {
        let now = clock.now
        var deadlines = targets.keys.compactMap { map.parameter(atOffset: $0) }.filter { $0.louder != nil }.map {
            dueTime(of: $0) ?? now
        }
        deadlines += written.values.map { $0.time.advanced(by: Self.crossingWindow) }.filter { $0 > now }
        deadlines += suspects.values.filter { !$0.verifying }.map {
            max($0.quietSince.advanced(by: Self.quietPeriod), now)
        }
        return deadlines.min()
    }

    // Sleeps until the deadline or until a request wakes the pump (`startPump`).
    private func sleep(until deadline: ContinuousClock.Instant) async {
        sleepCount += 1
        let id = sleepCount
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            wake = continuation
            Task { [clock] in
                do {
                    try await clock.sleep(until: deadline)
                } catch {
                    self.logger.debug("pump sleep cancelled")
                }
                self.endSleep(id)
            }
        }
    }

    private func endSleep(_ id: Int) {
        // A request may already have ended this sleep, and a later sleep may be pending; leave that one alone.
        guard id == sleepCount, let wake else { return }
        self.wake = nil
        wake.resume()
    }
}
