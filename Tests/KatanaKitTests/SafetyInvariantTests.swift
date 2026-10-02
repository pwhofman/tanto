import Synchronization
import Testing

@testable import KatanaKit

/// A small seeded generator, so that a failing run can be repeated.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// How far one message may raise a parameter (design spec, section 5.2).
private func riseStep(of parameter: Parameter, spacing: Duration, rampDuration: Duration) -> Int {
    max(1, Int((Double(parameter.maximum - parameter.minimum) * (spacing / rampDuration)).rounded()))
}

// Random requests against the simulated amp; the recorded messages must keep the guard's promises (design spec,
// section 5): only parameters Tone Studio writes, guarded values rise at most one step per message and never faster
// than a full sweep in the ramp's time, never above the ceiling, switch and picker changes only while VOLUME reads 0,
// and VOLUME 0 right after Panic. A short ramp makes the steps several units.
@Test(arguments: zip([1, 2, 3] as [UInt64], [200, 200, 20]))
func randomRequestsKeepTheSafetyRules(seed: UInt64, rampMilliseconds: Int) async throws {
    let map = try ParameterMap.bundled()
    let amp = SimulatedAmp(map: map)
    let session = AmpSession(transport: amp, timing: SessionTiming(spacing: .milliseconds(1), readTimeout: .seconds(1)))
    _ = try await session.connect()
    try await session.readLivePatch(map)
    let rampDuration = Duration.milliseconds(rampMilliseconds)
    let safety = try SafetyGuard(session: session, map: map, rampDuration: rampDuration)
    let volume = try #require(map.parameter(block: "Status", prm: "PRM_KNOB_POS_VOLUME"))
    // Start with a moderate volume, so that soft switches are allowed and ramp back up.
    amp.setMemory([20], at: .temporaryPatch.advanced(by: volume.offset))
    try await session.readLivePatch(map)
    let initial = amp.memory(at: .temporaryPatch, count: map.patchSize)
    let start = amp.received.count
    let candidates = map.table.parameters.filter { $0.written && $0.kind != .text }
    var random = SplitMix64(state: seed)
    var panics: [Int] = []

    for step in 0..<1500 {
        // Now and then let all ramps run to the end, so that complete ramps are checked too.
        if step % 50 == 49 {
            await safety.settle()
        }
        let roll = Int.random(in: 0..<100, using: &random)
        if roll < 2 {
            panics.append(amp.received.count)
            await safety.panic()
        } else {
            // Favour the VOLUME knob and switches, where the rules matter most.
            let parameter =
                roll < 30 ? volume : candidates.randomElement(using: &random) ?? volume
            var value =
                parameter.options?.randomElement(using: &random)?.value
                ?? Int.random(in: parameter.minimum...parameter.maximum, using: &random)
            // Half of the guarded requests ask for a small rise below the ceiling, so that ramps run and are checked.
            if parameter.guarded, Bool.random(using: &random), let current = await session.liveValue(of: parameter),
                let ceiling = await safety.ceiling(of: parameter), current < ceiling
            {
                value = min(current + Int.random(in: 1...8, using: &random), ceiling)
            }
            _ = try? await safety.set(parameter, to: value)
        }
        if roll % 3 == 0 {
            try await Task.sleep(for: .milliseconds(Int.random(in: 0...4, using: &random)))
        }
    }
    await safety.settle()

    var values: [Int: Int] = [:]
    var lastTime: [Int: ContinuousClock.Instant] = [:]
    func value(at parameter: Parameter) -> Int {
        values[parameter.offset]
            ?? parameter.value(
                fromRaw: parameter.encoding.decode(
                    initial[parameter.offset..<(parameter.offset + parameter.encoding.byteCount)]))
    }
    let received = Array(amp.received.dropFirst(start))
    var dataSetIndex = 0
    var switchChanges = 0
    var rampSteps = 0
    var largestRise = 0
    for message in received {
        guard case .dataSet(let address, let data) = IncomingMessage(message.message) else { continue }
        dataSetIndex += 1
        let offset = address.linear - Address.temporaryPatch.linear
        let parameter = try #require(map.parameter(atOffset: offset), "write to unknown address \(address)")
        #expect(parameter.written, "write to \(parameter.prm), which Tone Studio does not write")
        let new = parameter.value(fromRaw: parameter.encoding.decode(data))
        // The amp sets some values itself, e.g. an effect's level from its knob: the rules hold from what it held.
        let old =
            message.previous.map { parameter.value(fromRaw: parameter.encoding.decode($0)) } ?? value(at: parameter)
        if let louder = parameter.louder, parameter.kind == .numeric, louder == .up ? new > old : new < old {
            rampSteps += 1
            largestRise = max(largestRise, abs(new - old))
            let step = riseStep(of: parameter, spacing: session.timing.spacing, rampDuration: rampDuration)
            #expect(abs(new - old) <= step, "\(parameter.prm) jumped from \(old) to \(new)")
            if let ceiling = await safety.ceiling(of: parameter) {
                #expect(new <= ceiling, "\(parameter.prm) rose to \(new), above its ceiling \(ceiling)")
            }
            if let last = lastTime[offset] {
                let interval = rampDuration * abs(new - old) / (parameter.maximum - parameter.minimum)
                #expect(message.time - last >= interval, "\(parameter.prm) got louder too fast")
            }
        }
        if parameter.kind == .toggle || parameter.kind == .picker
            || (parameter.switchesEffectOffBelowZero && (old < 0) != (new < 0))
        {
            switchChanges += 1
            #expect(value(at: volume) == 0, "\(parameter.prm) switched while VOLUME was \(value(at: volume))")
        }
        values[offset] = new
        lastTime[offset] = message.time
    }
    for panicIndex in panics {
        let following = received.dropFirst(panicIndex - start).compactMap { message -> (Address, [UInt8])? in
            if case .dataSet(let address, let data) = IncomingMessage(message.message) { (address, data) } else { nil }
        }
        let volumeAddress = Address.temporaryPatch.advanced(by: volume.offset)
        #expect(following.prefix(2).contains { $0.0 == volumeAddress && $0.1 == [0] }, "Panic not followed by VOLUME 0")
    }
    // The pump must not spin: its rounds stay in proportion to the messages it sends.
    let statistics = await safety.statistics
    let rounds = statistics["pump iterations", default: 0]
    #expect(rounds < 4 * statistics["writes", default: 0] + 200, "\(rounds) pump rounds")
    // The run must have exercised what it checks.
    #expect(dataSetIndex > 200, "\(dataSetIndex) writes")
    #expect(switchChanges > 10, "\(switchChanges) switch changes")
    #expect(rampSteps > 50, "\(rampSteps) ramp steps")
    let volumeStep = riseStep(of: volume, spacing: session.timing.spacing, rampDuration: rampDuration)
    #expect(volumeStep == 1 || largestRise > 1, "no rise of several units")
    #expect(panics.count > 5, "\(panics.count) panics")
}

/// Collects messages from a `@Sendable` hook.
private final class Messages: Sendable {
    private let items = Mutex<[String]>([])

    func append(_ item: String) {
        items.withLock { $0.append(item) }
    }

    var all: [String] { items.withLock { $0 } }
}

// Random requests while knobs are turned and channels are switched on the amp. Every write is checked when it goes out,
// against what the session knew at that moment: guarded values rise at most one step per message, not faster than the
// ramp and not above the ceiling unless they fall; switch and picker changes go out only while VOLUME is 0; and while the copy
// of the live patch is incomplete only VOLUME 0 goes out. In the end no guarded value is above both its ceiling and the
// highest value the amp itself set (design spec, sections 5.2, 5.3 and 5.8).
@Test(arguments: zip([4, 5, 6] as [UInt64], [200, 200, 20]))
func randomRequestsWithChangesOnTheAmpKeepTheSafetyRules(seed: UInt64, rampMilliseconds: Int) async throws {
    let map = try ParameterMap.bundled()
    let amp = SimulatedAmp(map: map)
    let volume = try #require(map.parameter(block: "Status", prm: "PRM_KNOB_POS_VOLUME"))
    var random = SplitMix64(state: seed)
    amp.setMemory([20], at: .temporaryPatch.advanced(by: volume.offset))
    for slot in 0...8 {
        let stored = UInt8([5, 20, 40, 88].randomElement(using: &random) ?? 20)
        amp.setMemory([stored], at: Address.userPatch(slot).advanced(by: volume.offset))
    }
    let transport = HookTransport(amp: amp)
    let session = AmpSession(
        transport: transport, timing: SessionTiming(spacing: .milliseconds(1), readTimeout: .seconds(1)))
    _ = try await session.connect()
    try await session.readLivePatch(map)
    let rampDuration = Duration.milliseconds(rampMilliseconds)
    let safety = try SafetyGuard(session: session, map: map, rampDuration: rampDuration)

    let violations = Messages()
    let kinds = Messages()
    let lastWrite = Mutex<[Int: ContinuousClock.Instant]>([:])
    transport.setHook { message in
        // A panel button press changes the sound like a switch.
        if case .dataSet(let address, _) = IncomingMessage(message),
            PanelButton.allCases.contains(where: { $0.address == address })
        {
            kinds.append("press")
            let knownVolume = session.assumeIsolated { $0.liveValue(of: volume) }
            if knownVolume != 0 { violations.append("pressed \(address) while VOLUME was \(knownVolume ?? -1)") }
            return
        }
        guard case .dataSet(let address, let data) = IncomingMessage(message),
            let parameter = map.parameter(atOffset: address.linear - Address.temporaryPatch.linear),
            parameter.encoding != .ascii16
        else { return }
        let new = parameter.value(fromRaw: parameter.encoding.decode(data))
        // The hook runs inside the session's send, on its actor.
        let (known, knownVolume, valid) = session.assumeIsolated { session in
            (session.liveValue(of: parameter), session.liveValue(of: volume), session.isLivePatchValid)
        }
        let now = ContinuousClock.now
        let previous = lastWrite.withLock { times in
            defer { times[parameter.offset] = now }
            return times[parameter.offset]
        }
        if !valid, !(parameter == volume && new == 0) {
            violations.append("\(parameter.prm) = \(new) while the copy was incomplete")
        }
        if let louder = parameter.louder, parameter.kind == .numeric, let known,
            louder == .up ? new > known : new < known
        {
            kinds.append("rise")
            if abs(new - known) > riseStep(of: parameter, spacing: session.timing.spacing, rampDuration: rampDuration) {
                violations.append("\(parameter.prm) jumped from \(known) to \(new)")
            }
            if let ceiling = Ceiling.value(of: parameter, percent: 50), new > ceiling {
                violations.append("\(parameter.prm) rose to \(new), above its ceiling \(ceiling)")
            }
            if let previous, now - previous < rampDuration * abs(new - known) / (parameter.maximum - parameter.minimum)
            {
                violations.append("\(parameter.prm) got louder too fast")
            }
        }
        let switchesEffect = parameter.switchesEffectOffBelowZero && known.map { ($0 < 0) != (new < 0) } == true
        if parameter.kind == .toggle || parameter.kind == .picker || switchesEffect {
            kinds.append("switch")
            if knownVolume != 0 { violations.append("\(parameter.prm) switched while VOLUME was \(knownVolume ?? -1)") }
        }
    }

    // The highest value the amp itself has set for each guarded parameter.
    var ampHighest: [Int: Int] = [:]
    func noteAmpValues(_ bytes: [UInt8]) {
        for value in map.values(in: bytes, at: 0) where value.parameter.guarded {
            ampHighest[value.parameter.offset] = max(ampHighest[value.parameter.offset] ?? value.value, value.value)
        }
    }
    noteAmpValues(amp.memory(at: .temporaryPatch, count: map.patchSize))
    func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<2000 where !(await condition()) {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await condition(), "the session did not take in a change on the amp")
    }

    let candidates = map.table.parameters.filter { $0.written && $0.kind != .text }
    let knobs = map.table.parameters.filter { $0.block == "Status" && $0.written && $0.kind == .numeric }
    var knobTurns = 0
    var channelSwitches = 0
    var panics = 0
    for step in 0..<1000 {
        if step % 50 == 49 {
            await safety.settle()
        }
        let roll = Int.random(in: 0..<100, using: &random)
        if roll < 2 {
            panics += 1
            await safety.panic()
            #expect(
                amp.memory(at: .temporaryPatch.advanced(by: volume.offset), count: 1) == [0], "Panic left VOLUME up")
        } else if roll < 10 {
            // A knob turned on the amp.
            let knob = knobs.randomElement(using: &random) ?? volume
            let value = Int.random(in: knob.minimum...knob.maximum, using: &random)
            let before = await session.ampReports(for: knob).count
            amp.changeOnAmp(
                knob.encoding.encode(value + knob.rawOffset), at: .temporaryPatch.advanced(by: knob.offset))
            knobTurns += 1
            if knob.guarded {
                ampHighest[knob.offset] = max(ampHighest[knob.offset] ?? value, value)
            }
            try await waitUntil { await session.ampReports(for: knob).count > before }
        } else if roll < 15, let button = PanelButton.allCases.randomElement(using: &random) {
            _ = try? await safety.press(button)
        } else if roll < 17 {
            // A channel button pressed on the amp.
            let slot = Int.random(in: 0...8, using: &random)
            noteAmpValues(amp.memory(at: .userPatch(slot), count: map.patchSize))
            amp.switchChannelOnAmp(slot)
            channelSwitches += 1
            try await waitUntil {
                let channel = await session.currentChannel
                let valid = await session.isLivePatchValid
                return channel == slot && valid
            }
        } else {
            let parameter = roll < 35 ? volume : candidates.randomElement(using: &random) ?? volume
            var value =
                parameter.options?.randomElement(using: &random)?.value
                ?? Int.random(in: parameter.minimum...parameter.maximum, using: &random)
            if parameter.guarded, Bool.random(using: &random), let current = await session.liveValue(of: parameter),
                let ceiling = await safety.ceiling(of: parameter), current < ceiling
            {
                value = min(current + Int.random(in: 1...8, using: &random), ceiling)
            }
            _ = try? await safety.set(parameter, to: value)
        }
        if roll % 3 == 0 {
            try await Task.sleep(for: .milliseconds(Int.random(in: 0...4, using: &random)))
        }
    }
    await safety.settle()

    let live = amp.memory(at: .temporaryPatch, count: map.patchSize)
    for value in map.values(in: live, at: 0) where value.parameter.guarded && value.parameter.written {
        let ceiling = Ceiling.value(of: value.parameter, percent: 50) ?? value.parameter.maximum
        let allowed = max(ceiling, ampHighest[value.parameter.offset] ?? ceiling)
        #expect(value.value <= allowed, "\(value.parameter.prm) ended at \(value.value), above \(allowed)")
    }
    #expect(violations.all.isEmpty, "\(violations.all.prefix(10))")
    // The run must have exercised what it checks.
    let statistics = await safety.statistics
    #expect(knobTurns > 30 && channelSwitches > 5 && panics > 5)
    #expect(kinds.all.filter { $0 == "rise" }.count > 50, "\(kinds.all.filter { $0 == "rise" }.count) rises")
    #expect(kinds.all.filter { $0 == "switch" }.count > 10, "\(kinds.all.filter { $0 == "switch" }.count) switches")
    #expect(kinds.all.filter { $0 == "press" }.count > 3, "\(kinds.all.filter { $0 == "press" }.count) presses")
    #expect(statistics["stopped: amp report", default: 0] > 0, "\(statistics)")
}
