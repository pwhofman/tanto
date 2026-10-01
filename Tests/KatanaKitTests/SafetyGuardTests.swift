import Testing

@testable import KatanaKit

/// A simulated amp with the live patch read, and a guard with the default 50 % ceiling and 2 s full-travel ramp.
private struct Rig {
    let amp: SimulatedAmp
    let session: AmpSession
    let map: ParameterMap
    let safety: SafetyGuard

    init(
        timing: SessionTiming = .katana, rampDuration: Duration = .seconds(2),
        prepare: (SimulatedAmp, ParameterMap) -> Void = { _, _ in }
    ) async throws {
        map = try ParameterMap.bundled()
        amp = SimulatedAmp(map: map)
        prepare(amp, map)
        session = AmpSession(transport: amp, timing: timing)
        _ = try await session.connect()
        try await session.readLivePatch(map)
        safety = try SafetyGuard(session: session, map: map, rampDuration: rampDuration)
    }

    func parameter(_ block: String, _ prm: String) throws -> Parameter {
        try #require(map.parameter(block: block, prm: prm))
    }

    /// Displayed values written to one parameter, in order, with their arrival times.
    func writes(to parameter: Parameter, after start: Int = 0) -> [(value: Int, time: ContinuousClock.Instant)] {
        amp.received.dropFirst(start).compactMap { received in
            guard case .dataSet(let address, let data) = IncomingMessage(received.message),
                address == Address.temporaryPatch.advanced(by: parameter.offset)
            else { return nil }
            return (parameter.value(fromRaw: parameter.encoding.decode(data)), received.time)
        }
    }

    /// Patch offsets of all DT1 messages, in order.
    func writtenOffsets(after start: Int = 0) -> [Int] {
        amp.received.dropFirst(start).compactMap { received in
            guard case .dataSet(let address, _) = IncomingMessage(received.message) else { return nil }
            return address.linear - Address.temporaryPatch.linear
        }
    }
}

private func setLive(_ value: Int, _ parameter: Parameter) -> (SimulatedAmp, ParameterMap) -> Void {
    { amp, _ in
        amp.setMemory(
            parameter.encoding.encode(value + parameter.rawOffset), at: .temporaryPatch.advanced(by: parameter.offset))
    }
}

private func knob(_ prm: String) throws -> Parameter {
    try #require(ParameterMap.bundled().parameter(block: "Status", prm: prm))
}

@Test func theCeilingIsHalfTheTravelByDefault() async throws {
    let rig = try await Rig()
    #expect(try await rig.safety.ceiling(of: rig.parameter("Status", "PRM_KNOB_POS_VOLUME")) == 50)
    #expect(try await rig.safety.ceiling(of: rig.parameter("Status", "PRM_KNOB_POS_BOOST")) == 49)
    #expect(try await rig.safety.ceiling(of: rig.parameter("Patch_0", "PRM_EQ_LOW_GAIN")) == 0)
    #expect(try await rig.safety.ceiling(of: rig.parameter("Delay(1)", "PRM_DLY_COMMON_EFFECT_LEVEL")) == 60)
    #expect(try await rig.safety.ceiling(of: rig.parameter("Status", "PRM_KNOB_POS_BASS")) == nil)
    try await rig.safety.setCeilingPercent(55)
    #expect(try await rig.safety.ceiling(of: rig.parameter("Status", "PRM_KNOB_POS_VOLUME")) == 55)
    await #expect(throws: SafetyError.invalidCeiling(52)) { try await rig.safety.setCeilingPercent(52) }
}

@Test func aRiseAboveTheCeilingIsRefused() async throws {
    let volume = try knob("PRM_KNOB_POS_VOLUME")
    let rig = try await Rig(prepare: setLive(30, volume))
    let before = rig.amp.received.count
    await #expect(throws: SafetyError.aboveCeiling("PRM_KNOB_POS_VOLUME", value: 60, ceiling: 50)) {
        try await rig.safety.set(volume, to: 60)
    }
    await rig.safety.settle()
    #expect(rig.amp.received.count == before)
}

@Test func increasesRampOneStepAtATime() async throws {
    let volume = try knob("PRM_KNOB_POS_VOLUME")
    let rig = try await Rig(prepare: setLive(30, volume))
    try await rig.safety.set(volume, to: 40)
    await rig.safety.settle()
    let writes = rig.writes(to: volume)
    #expect(writes.map(\.value) == Array(31...40))
    for (earlier, later) in zip(writes, writes.dropFirst()) {
        #expect(later.time - earlier.time >= .milliseconds(20))  // 2 s / 100 steps
    }
}

@Test func rampsOfBipolarParametersStopAtZeroDecibels() async throws {
    let lowGain = try #require(ParameterMap.bundled().parameter(block: "Patch_0", prm: "PRM_EQ_LOW_GAIN"))
    let rig = try await Rig(prepare: setLive(-3, lowGain))
    await #expect(throws: SafetyError.aboveCeiling("PRM_EQ_LOW_GAIN", value: 2, ceiling: 0)) {
        try await rig.safety.set(lowGain, to: 2)
    }
    try await rig.safety.set(lowGain, to: 0)
    await rig.safety.settle()
    let writes = rig.writes(to: lowGain)
    #expect(writes.map(\.value) == [-2, -1, 0])
    for (earlier, later) in zip(writes, writes.dropFirst()) {
        #expect(later.time - earlier.time >= .milliseconds(50))  // 2 s / 40 steps
    }
}

@Test func decreasesGoAtOnceAndStopARamp() async throws {
    let volume = try knob("PRM_KNOB_POS_VOLUME")
    let rig = try await Rig(prepare: setLive(10, volume))
    try await rig.safety.set(volume, to: 45)
    try await Task.sleep(for: .milliseconds(150))
    try await rig.safety.set(volume, to: 5)
    await rig.safety.settle()
    let values = rig.writes(to: volume).map(\.value)
    let peak = try #require(values.dropLast().last)
    #expect(peak < 45)
    #expect(values.last == 5)
    #expect(zip(values.dropLast(), values.dropLast().dropFirst()).allSatisfy { $1 == $0 + 1 })
}

@Test func valuesAboveTheCeilingCanBeLoweredButNotRaised() async throws {
    let volume = try knob("PRM_KNOB_POS_VOLUME")
    let rig = try await Rig(prepare: setLive(88, volume))
    await #expect(throws: SafetyError.aboveCeiling("PRM_KNOB_POS_VOLUME", value: 90, ceiling: 50)) {
        try await rig.safety.set(volume, to: 90)
    }
    try await rig.safety.set(volume, to: 70)
    await rig.safety.settle()
    #expect(rig.writes(to: volume).map(\.value) == [70])
}

@Test func unguardedValuesJumpAndQuickRequestsCoalesce() async throws {
    let rig = try await Rig()
    let bass = try rig.parameter("Status", "PRM_KNOB_POS_BASS")
    for value in stride(from: 10, through: 90, by: 10) {
        try await rig.safety.set(bass, to: value)
    }
    await rig.safety.settle()
    let values = rig.writes(to: bass).map(\.value)
    #expect(values.last == 90)
    #expect(values.count < 9)
}

@Test func switchesDipTheVolumeChangeAndRampBack() async throws {
    let volume = try knob("PRM_KNOB_POS_VOLUME")
    let rig = try await Rig(prepare: setLive(5, volume))
    let boosterOn = try rig.parameter("Patch_0", "PRM_ODDS_SW")
    let start = rig.amp.received.count
    try await rig.safety.set(boosterOn, to: 1)
    await rig.safety.settle()
    #expect(rig.writtenOffsets(after: start).prefix(2) == [volume.offset, boosterOn.offset])
    #expect(rig.writes(to: volume, after: start).map(\.value) == [0, 1, 2, 3, 4, 5])
    #expect(rig.writes(to: boosterOn, after: start).map(\.value) == [1])
}

@Test func switchesAreRefusedWhileTheVolumeIsAboveTheCeiling() async throws {
    let volume = try knob("PRM_KNOB_POS_VOLUME")
    let rig = try await Rig(prepare: setLive(88, volume))
    let before = rig.amp.received.count
    await #expect(throws: SafetyError.volumeAboveCeiling(volume: 88, ceiling: 50)) {
        try await rig.safety.set(rig.parameter("Patch_0", "PRM_ODDS_SW"), to: 1)
    }
    await rig.safety.settle()
    #expect(rig.amp.received.count == before)
}

@Test func twoQuickSwitchesRestoreTheOriginalVolume() async throws {
    let volume = try knob("PRM_KNOB_POS_VOLUME")
    let rig = try await Rig(prepare: setLive(6, volume))
    try await rig.safety.set(rig.parameter("Patch_0", "PRM_ODDS_SW"), to: 1)
    try await Task.sleep(for: .milliseconds(70))
    try await rig.safety.set(rig.parameter("Patch_0", "PRM_EQ_SW"), to: 0)
    await rig.safety.settle()
    #expect(await rig.session.liveValue(of: volume) == 6)
}

@Test func panicSendsVolumeZeroNextAndStopsEverything() async throws {
    let volume = try knob("PRM_KNOB_POS_VOLUME")
    let rig = try await Rig(prepare: setLive(10, volume))
    try await rig.safety.set(volume, to: 45)
    try await Task.sleep(for: .milliseconds(100))
    let atPanic = rig.amp.received.count
    await rig.safety.panic()
    await rig.safety.settle()
    // At most one message was already in flight; Volume 0 follows it.
    let after = rig.writes(to: volume, after: atPanic).map(\.value)
    #expect(after.last == 0)
    #expect(after.count <= 2)
    try await Task.sleep(for: .milliseconds(200))
    #expect(rig.writes(to: volume, after: atPanic).map(\.value).last == 0)
    #expect(await rig.session.liveValue(of: volume) == 0)
}

@Test func panicDuringASwitchPreventsTheRampBack() async throws {
    let volume = try knob("PRM_KNOB_POS_VOLUME")
    let rig = try await Rig(prepare: setLive(30, volume))
    try await rig.safety.set(rig.parameter("Patch_0", "PRM_ODDS_SW"), to: 1)
    try await Task.sleep(for: .milliseconds(80))
    await rig.safety.panic()
    await rig.safety.settle()
    try await Task.sleep(for: .milliseconds(200))
    #expect(await rig.session.liveValue(of: volume) == 0)
}

// Whatever the timing, a ramp step that crosses a knob turn on the amp must not win: the amp ends at the knob's value.
@Test(arguments: [0, 3, 7, 11, 17])
func aKnobTurnedOnTheAmpEndsTheRamp(delay: Int) async throws {
    let volume = try knob("PRM_KNOB_POS_VOLUME")
    let rig = try await Rig(prepare: setLive(10, volume))
    try await rig.safety.set(volume, to: 45)
    try await Task.sleep(for: .milliseconds(100 + delay))
    rig.amp.changeOnAmp([3], at: .temporaryPatch.advanced(by: volume.offset))
    let atTurn = rig.amp.received.count
    try await Task.sleep(for: .milliseconds(60))
    await rig.safety.settle()
    try await Task.sleep(for: .milliseconds(100))
    // At most the step that was already on its way, and the guard putting the knob's value back.
    let after = rig.writes(to: volume, after: atTurn).map(\.value)
    #expect(after.count <= 2)
    #expect(after.allSatisfy { $0 <= 3 } || after.last == 3)
    #expect(rig.amp.memory(at: .temporaryPatch.advanced(by: volume.offset), count: 1) == [3])
    #expect(await rig.session.liveValue(of: volume) == 3)
}

@Test func onlyTablePickerValuesAndWrittenParametersAreAccepted() async throws {
    let rig = try await Rig()
    await #expect(throws: SafetyError.notWritable("PRM_PREAMP_A_LEVEL")) {
        try await rig.safety.set(rig.parameter("Patch_0", "PRM_PREAMP_A_LEVEL"), to: 10)
    }
    let real = try rig.parameter("Status", "PRM_KNOB_POS_BASS")
    let forged = Parameter(
        prm: real.prm, name: real.name, block: real.block, offset: real.offset, encoding: real.encoding, minimum: 0,
        maximum: 127, rawOffset: 0, initial: nil, guarded: false, louder: nil, written: true, kind: .numeric,
        section: "amp", label: real.label, options: nil, valueLabels: nil, format: nil, visibleWhen: nil)
    await #expect(throws: SafetyError.notWritable(real.prm)) { try await rig.safety.set(forged, to: 120) }
    // Booster type 24 is in range but not in Tone Studio's menu.
    await #expect(throws: SafetyError.outOfRange("PRM_ODDS_TYPE", 24)) {
        try await rig.safety.set(rig.parameter("Patch_0", "PRM_ODDS_TYPE"), to: 24)
    }
}

@Test func theChannelCheckListsStoredValuesAboveTheCeiling() async throws {
    let rig = try await Rig()
    let ampVolume = try rig.parameter("Patch_0", "PRM_PREAMP_A_LEVEL")
    var patch = rig.amp.memory(at: .userPatch(6), count: rig.map.patchSize)
    patch[ampVolume.offset] = 88
    let above = await rig.safety.valuesAboveCeiling(in: patch)
    #expect(above.contains(ParameterValue(parameter: ampVolume, value: 88)))
}

@Test func renamingWritesOnlyTheName() async throws {
    let rig = try await Rig()
    let start = rig.amp.received.count
    try await rig.safety.rename(to: "TANTO TEST")
    #expect(rig.writtenOffsets(after: start) == [0])
    #expect(await rig.session.liveName() == "TANTO TEST")
}

// The worst case, made deterministic: the knob turn reaches the amp just before the guard's ramp step, and its report
// reaches Tanto just after. The amp holds the guard's higher step until the guard puts the knob's value back.
@Test func aRampStepThatCrossesAKnobTurnIsUndone() async throws {
    let volume = try knob("PRM_KNOB_POS_VOLUME")
    let rig = try await Rig(prepare: setLive(10, volume))
    rig.amp.turnKnobWhenNextWritten([3], at: .temporaryPatch.advanced(by: volume.offset))
    try await rig.safety.set(volume, to: 45)
    await rig.safety.settle()
    try await Task.sleep(for: .milliseconds(100))
    #expect(rig.amp.memory(at: .temporaryPatch.advanced(by: volume.offset), count: 1) == [3])
    #expect(await rig.session.liveValue(of: volume) == 3)
    #expect(rig.writes(to: volume).map(\.value) == [11, 3])
}

private func setLive(_ values: [(Int, Parameter)]) -> (SimulatedAmp, ParameterMap) -> Void {
    { amp, map in
        for (value, parameter) in values {
            setLive(value, parameter)(amp, map)
        }
    }
}

// An effect knob moved off −1 switches its effect on: a soft switch to 0, then the knob ramps (design spec, 5.2).
@Test func anEffectKnobTurnedOnFromOffUsesTheSoftSwitch() async throws {
    let volume = try knob("PRM_KNOB_POS_VOLUME")
    let boost = try knob("PRM_KNOB_POS_BOOST")
    let rig = try await Rig(prepare: setLive([(5, volume), (-1, boost)]))
    let start = rig.amp.received.count
    try await rig.safety.set(boost, to: 3)
    await rig.safety.settle()
    #expect(rig.writtenOffsets(after: start).prefix(2) == [volume.offset, boost.offset])
    #expect(rig.writes(to: volume, after: start).map(\.value) == [0, 1, 2, 3, 4, 5])
    #expect(rig.writes(to: boost, after: start).map(\.value) == [0, 1, 2, 3])
}

@Test func anEffectKnobTurnedToOffUsesTheSoftSwitch() async throws {
    let volume = try knob("PRM_KNOB_POS_VOLUME")
    let boost = try knob("PRM_KNOB_POS_BOOST")
    let rig = try await Rig(prepare: setLive([(5, volume), (20, boost)]))
    let start = rig.amp.received.count
    try await rig.safety.set(boost, to: -1)
    await rig.safety.settle()
    #expect(rig.writtenOffsets(after: start).prefix(2) == [volume.offset, boost.offset])
    #expect(rig.writes(to: volume, after: start).map(\.value) == [0, 1, 2, 3, 4, 5])
    #expect(rig.writes(to: boost, after: start).map(\.value) == [-1])
}

@Test func anEffectKnobIsNotSwitchedWhileVolumeIsAboveTheCeiling() async throws {
    let volume = try knob("PRM_KNOB_POS_VOLUME")
    let boost = try knob("PRM_KNOB_POS_BOOST")
    let rig = try await Rig(prepare: setLive([(88, volume), (-1, boost)]))
    let before = rig.amp.received.count
    await #expect(throws: SafetyError.volumeAboveCeiling(volume: 88, ceiling: 50)) {
        try await rig.safety.set(boost, to: 3)
    }
    await rig.safety.settle()
    #expect(rig.amp.received.count == before)
}

// A higher limiter threshold and a lower ratio let more through: those changes are ramped, the others go at once.
@Test func theLimitersThresholdRisesAndRatioFallsAreRamped() async throws {
    let map = try ParameterMap.bundled()
    let threshold = try #require(map.parameter(block: "Fx(1)", prm: "PRM_FX1_LIMITER_THRESHOLD"))
    let ratio = try #require(map.parameter(block: "Fx(1)", prm: "PRM_FX1_LIMITER_RATIO"))
    let rig = try await Rig(prepare: setLive([(30, threshold), (11, ratio)]))
    try await rig.safety.set(threshold, to: 35)
    try await rig.safety.set(ratio, to: 8)
    await rig.safety.settle()
    try await rig.safety.set(threshold, to: 10)
    try await rig.safety.set(ratio, to: 15)
    await rig.safety.settle()
    let thresholds = rig.writes(to: threshold)
    let ratios = rig.writes(to: ratio)
    #expect(thresholds.map(\.value) == [31, 32, 33, 34, 35, 10])
    #expect(ratios.map(\.value) == [10, 9, 8, 15])
    for (earlier, later) in zip(thresholds.prefix(5), thresholds.prefix(5).dropFirst()) {
        #expect(later.time - earlier.time >= .milliseconds(20))  // 2 s / 100 steps
    }
    for (earlier, later) in zip(ratios.prefix(3), ratios.prefix(3).dropFirst()) {
        #expect(later.time - earlier.time >= .seconds(2) / 17)
    }
}
