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
    /// The live patch has not been read yet.
    case notReady
    /// The ceiling must be 0–100 % in steps of 5 %.
    case invalidCeiling(Int)
    /// The bundled table lacks the VOLUME knob.
    case missingVolumeKnob
}

/// The only way to change the amp's sound (design spec, section 5).
///
/// All writes go through one pump, one message at a time, in this order: urgent messages (Panic and the VOLUME dips of
/// soft switches), decreases, the changes of soft switches, and finally increases. Guarded increases rise one unit at
/// a time, at least `rampDuration / (maximum - minimum)` apart, and never above the ceiling. A soft-switch change is
/// only sent while the VOLUME knob reads 0. A value that the amp reports differently from what the guard last wrote,
/// for instance because a knob was turned, ends the guard's work on that parameter.
public actor SafetyGuard {
    /// The ceiling as a percentage of a guarded parameter's travel.
    public private(set) var ceilingPercent: Int

    private let session: AmpSession
    private let map: ParameterMap
    private let volumeKnob: Parameter
    private let rampDuration: Duration
    private let clock = ContinuousClock()
    private let logger = Logger(subsystem: "io.github.pwhofman.tanto", category: "safety")
    private var targets: [Int: Int] = [:]
    private var lastWritten: [Int: Int] = [:]
    private var lastWriteTime: [Int: ContinuousClock.Instant] = [:]
    // Per parameter: the number of amp reports when the guard took it on (`AmpSession.ampReports(for:)`).
    private var seenReports: [Int: Int] = [:]
    private var urgent: [Write] = []
    private var switches: [Write] = []
    private var volumeRestore: Int?
    private var pump: Task<Void, Never>?
    private var wake: CheckedContinuation<Void, Never>?
    private var sleepCount = 0
    private var panicCount = 0
    // Counts of pump rounds, writes, sleeps and stopped work, for tests.
    private(set) var statistics: [String: Int] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    private struct Write {
        let parameter: Parameter
        let value: Int
        let priority: WritePriority
        // For the change of a soft switch: the number of VOLUME reports when the switch was asked for.
        var volumeReports: Int?
    }

    /// Creates a guard.
    ///
    /// - Parameters:
    ///   - session: The connection, with the live patch read.
    ///   - map: The bundled parameter table.
    ///   - ceilingPercent: The ceiling, 0–100 in steps of 5 (design spec: 50 by default).
    ///   - rampDuration: How long a full sweep of a guarded parameter takes at least (design spec: 2 s).
    /// - Throws: `SafetyError.invalidCeiling` or `.missingVolumeKnob`.
    public init(session: AmpSession, map: ParameterMap, ceilingPercent: Int = 50, rampDuration: Duration = .seconds(2))
        throws
    {
        guard (0...100).contains(ceilingPercent), ceilingPercent % 5 == 0 else {
            throw SafetyError.invalidCeiling(ceilingPercent)
        }
        guard let volumeKnob = map.parameter(block: "Status", prm: "PRM_KNOB_POS_VOLUME") else {
            throw SafetyError.missingVolumeKnob
        }
        self.session = session
        self.map = map
        self.volumeKnob = volumeKnob
        self.ceilingPercent = ceilingPercent
        self.rampDuration = rampDuration
    }

    /// Changes the ceiling. Values already above a lower ceiling stay; they can only be lowered.
    ///
    /// - Parameter percent: 0–100 in steps of 5.
    /// - Throws: `SafetyError.invalidCeiling`.
    public func setCeilingPercent(_ percent: Int) throws {
        guard (0...100).contains(percent), percent % 5 == 0 else { throw SafetyError.invalidCeiling(percent) }
        ceilingPercent = percent
    }

    /// The highest value Tanto may raise a guarded parameter to: `minimum + ⌊percent · (maximum − minimum) / 100⌋`.
    ///
    /// - Parameter parameter: Any parameter.
    /// - Returns: The ceiling, or `nil` for unguarded parameters.
    public func ceiling(of parameter: Parameter) -> Int? {
        guard parameter.guarded else { return nil }
        return parameter.minimum + ceilingPercent * (parameter.maximum - parameter.minimum) / 100
    }

    /// Asks for a new value. Numeric values move as section 5.2 of the design spec allows; switches and pickers use
    /// the soft switch of section 5.3. The call returns once the request is accepted; the writes follow.
    ///
    /// - Parameters:
    ///   - parameter: A parameter from the bundled table that Tone Studio writes.
    ///   - value: The displayed value.
    /// - Throws: `SafetyError` if the request is refused.
    public func set(_ parameter: Parameter, to value: Int) async throws {
        guard let known = map.parameter(atOffset: parameter.offset), known == parameter, known.written else {
            throw SafetyError.notWritable(parameter.prm)
        }
        guard (known.minimum...known.maximum).contains(value),
            known.options?.contains(where: { $0.value == value }) ?? true
        else {
            throw SafetyError.outOfRange(known.prm, value)
        }
        guard let current = await session.liveValue(of: known) else { throw SafetyError.notReady }
        switch known.kind {
        case .text:
            throw SafetyError.notWritable(known.prm)
        case .toggle, .picker:
            try await softSwitch(known, to: value, from: current)
        case .numeric:
            if value > current, let ceiling = ceiling(of: known), value > ceiling {
                throw SafetyError.aboveCeiling(known.prm, value: value, ceiling: ceiling)
            }
            if known == volumeKnob {
                volumeRestore = nil
            }
            lastWritten[known.offset] = current
            seenReports[known.offset] = await session.ampReports(for: known).count
            targets[known.offset] = value
            startPump()
        }
    }

    /// Panic: clears everything queued and sets the VOLUME knob to 0 as the next message (design spec, section 5.5).
    /// Nothing ramps back up afterwards.
    public func panic() {
        logger.notice("panic")
        panicCount += 1
        targets = [:]
        switches = []
        volumeRestore = nil
        urgent = [Write(parameter: volumeKnob, value: 0, priority: .high)]
        startPump()
    }

    /// Renames the live patch; the sound does not change.
    ///
    /// - Parameter name: At most 16 characters from space to `}`.
    /// - Throws: `WriteError.invalidName`; an error from the transport.
    public func rename(to name: String) async throws {
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

    /// Waits until every accepted request has been written.
    public func settle() async {
        guard pump != nil else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func softSwitch(_ parameter: Parameter, to value: Int, from current: Int) async throws {
        guard value != current else { return }
        guard let volume = await session.liveValue(of: volumeKnob) else { throw SafetyError.notReady }
        let restore = volumeRestore ?? targets[volumeKnob.offset] ?? volume
        let ceiling = ceiling(of: volumeKnob) ?? volumeKnob.maximum
        guard volume <= ceiling, restore <= ceiling else {
            throw SafetyError.volumeAboveCeiling(volume: max(volume, restore), ceiling: ceiling)
        }
        volumeRestore = restore
        let volumeReports = await session.ampReports(for: volumeKnob).count
        lastWritten[volumeKnob.offset] = volume
        seenReports[volumeKnob.offset] = volumeReports
        targets[volumeKnob.offset] = restore
        urgent.append(Write(parameter: volumeKnob, value: 0, priority: .high))
        switches.append(Write(parameter: parameter, value: value, priority: .normal, volumeReports: volumeReports))
        startPump()
    }

    private func startPump() {
        if let wake {
            self.wake = nil
            wake.resume()
        }
        guard pump == nil else { return }
        pump = Task { await self.run() }
    }

    private func run() async {
        while true {
            statistics["pump iterations", default: 0] += 1
            if let write = await nextWrite() {
                statistics["writes", default: 0] += 1
                do {
                    try await session.write(write.value, to: write.parameter, priority: write.priority)
                    lastWritten[write.parameter.offset] = write.value
                    lastWriteTime[write.parameter.offset] = clock.now
                } catch {
                    logger.error("write to \(write.parameter.prm, privacy: .public) failed: \(error)")
                    targets[write.parameter.offset] = nil
                }
            } else if let deadline = nextDeadline() {
                statistics["sleeps", default: 0] += 1
                await sleep(until: deadline)
            } else if targets.isEmpty, urgent.isEmpty, switches.isEmpty {
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

    private func nextWrite() async -> Write? {
        if !urgent.isEmpty {
            return urgent.removeFirst()
        }
        // One look at the session per message: the values and amp reports of everything the guard works on.
        let panics = panicCount
        let offsets = Set(targets.keys).union([volumeKnob.offset]).sorted()
        let views = await session.guardViews(of: offsets.compactMap { map.parameter(atOffset: $0) })
        // A Panic during that look wins over every decision based on it.
        guard panics == panicCount else {
            return urgent.isEmpty ? nil : urgent.removeFirst()
        }
        var decreases: [Write] = []
        var increases: [Write] = []
        for (offset, target) in targets.sorted(by: { $0.key < $1.key }) {
            guard let parameter = map.parameter(atOffset: offset), let view = views[offset],
                let current = ours(parameter, view)
            else {
                continue
            }
            if target < current {
                decreases.append(Write(parameter: parameter, value: target, priority: .high))
            } else if target == current {
                finish(offset)
            } else if !parameter.guarded {
                increases.append(Write(parameter: parameter, value: target, priority: .normal))
            } else if let ceiling = ceiling(of: parameter), current + 1 > ceiling {
                logger.notice("\(parameter.prm, privacy: .public) reached its ceiling; ramp stopped")
                finish(offset)
            } else if isDue(parameter) {
                increases.append(Write(parameter: parameter, value: current + 1, priority: .normal))
            }
        }
        // Writes that undo a crossed knob turn were queued during the scan; they go first.
        if !urgent.isEmpty {
            return urgent.removeFirst()
        }
        // The change of a soft switch follows its dip directly, which keeps the silence short. It goes out only while
        // the VOLUME knob still reads 0 from the dip, and only if the amp reported nothing about VOLUME since the
        // switch was asked for (a knob turn, a channel switch).
        while !switches.isEmpty {
            let write = switches.removeFirst()
            if let volume = views[volumeKnob.offset], volume.value == 0, lastWritten[volumeKnob.offset] == 0,
                volume.reportCount == write.volumeReports
            {
                return write
            }
            logger.notice("switch of \(write.parameter.prm, privacy: .public) dropped: VOLUME is not at 0")
        }
        return decreases.first ?? increases.first
    }

    // The live value, or nil once the amp has taken the parameter over: it reported a change (a knob turn, a channel
    // switch), or its value differs from what the guard last wrote. The guard then stops its work on the parameter.
    // A report can cross the guard's last write, which then wins on the amp; if that write was higher than the
    // reported value, the guard writes the reported value back.
    private func ours(_ parameter: Parameter, _ view: AmpSession.GuardView) -> Int? {
        if view.reportCount != seenReports[parameter.offset] {
            statistics["stopped: amp report", default: 0] += 1
            logger.notice("\(parameter.prm, privacy: .public) changed on the amp; the guard stops its work on it")
            finish(parameter.offset)
            seenReports[parameter.offset] = view.reportCount
            if let reported = view.reportedValue, let written = lastWritten[parameter.offset], written > reported {
                urgent.append(Write(parameter: parameter, value: reported, priority: .high))
            }
            return nil
        }
        guard let current = view.value, current == lastWritten[parameter.offset] else {
            statistics["stopped: value differs", default: 0] += 1
            logger.notice("\(parameter.prm, privacy: .public) differs from the guard's last write; the guard stops")
            finish(parameter.offset)
            return nil
        }
        return current
    }

    private func finish(_ offset: Int) {
        targets[offset] = nil
        if offset == volumeKnob.offset {
            volumeRestore = nil
        }
    }

    // When the next rising step of a guarded parameter may go out; `nil` if it never was written, so it may go now.
    private func dueTime(of parameter: Parameter) -> ContinuousClock.Instant? {
        lastWriteTime[parameter.offset]?.advanced(by: rampDuration / (parameter.maximum - parameter.minimum))
    }

    private func isDue(_ parameter: Parameter) -> Bool {
        guard let due = dueTime(of: parameter) else { return true }
        return due <= clock.now
    }

    private func nextDeadline() -> ContinuousClock.Instant? {
        let now = clock.now
        return targets.keys.compactMap { map.parameter(atOffset: $0) }.filter(\.guarded).map { dueTime(of: $0) ?? now }
            .min()
    }

    // Sleeps until the deadline or until a new request wakes the pump (`startPump`).
    private func sleep(until deadline: ContinuousClock.Instant) async {
        sleepCount += 1
        let id = sleepCount
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            wake = continuation
            Task { [clock] in
                try? await clock.sleep(until: deadline)
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
