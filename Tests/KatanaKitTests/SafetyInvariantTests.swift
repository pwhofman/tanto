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

// Random requests against the simulated amp; the recorded messages must keep the guard's promises (design spec,
// section 5): only parameters Tone Studio writes, guarded values rise one step at a time, never faster than the ramp
// and never above the ceiling, switch and picker changes only while VOLUME reads 0, and VOLUME 0 right after Panic.
@Test(arguments: [1, 2, 3] as [UInt64])
func randomRequestsKeepTheSafetyRules(seed: UInt64) async throws {
    let map = try ParameterMap.bundled()
    let amp = SimulatedAmp(map: map)
    let session = AmpSession(transport: amp, timing: SessionTiming(spacing: .milliseconds(1), readTimeout: .seconds(1)))
    _ = try await session.connect()
    try await session.readLivePatch(map)
    let rampDuration = Duration.milliseconds(200)
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
    for message in received {
        guard case .dataSet(let address, let data) = IncomingMessage(message.message) else { continue }
        dataSetIndex += 1
        let offset = address.linear - Address.temporaryPatch.linear
        let parameter = try #require(map.parameter(atOffset: offset), "write to unknown address \(address)")
        #expect(parameter.written, "write to \(parameter.prm), which Tone Studio does not write")
        let new = parameter.value(fromRaw: parameter.encoding.decode(data))
        let old = value(at: parameter)
        if parameter.guarded, new > old {
            let ceiling = await safety.ceiling(of: parameter) ?? parameter.maximum
            rampSteps += 1
            #expect(new == old + 1, "\(parameter.prm) jumped from \(old) to \(new)")
            #expect(new <= ceiling, "\(parameter.prm) rose to \(new), above its ceiling \(ceiling)")
            if let last = lastTime[offset] {
                let interval = rampDuration / (parameter.maximum - parameter.minimum)
                #expect(message.time - last >= interval, "\(parameter.prm) rose too fast")
            }
        }
        if parameter.kind == .toggle || parameter.kind == .picker {
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
    #expect(panics.count > 5, "\(panics.count) panics")
}
