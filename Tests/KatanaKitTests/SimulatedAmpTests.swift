import Testing

@testable import KatanaKit

@Test func answersReadsWithInitialValues() async throws {
    let map = try ParameterMap.bundled()
    let amp = SimulatedAmp(map: map)
    let volume = try #require(map.parameter(block: "Patch_0", prm: "PRM_PREAMP_A_LEVEL"))
    let address = Address.temporaryPatch.advanced(by: volume.offset)
    try amp.send(SysEx.rq1(address, size: 1, deviceID: amp.deviceID))
    var replies = amp.incoming.makeAsyncIterator()
    #expect(await replies.next() == SysEx.dt1(address, data: [50], deviceID: amp.deviceID))
}

@Test func storesWrites() throws {
    let amp = SimulatedAmp(map: try .bundled())
    try amp.send(SysEx.dt1(.userPatch(3), data: [0x41, 0x42], deviceID: amp.deviceID))
    #expect(amp.memory(at: .userPatch(3), count: 2) == [0x41, 0x42])
}

@Test func ignoresMessagesForOtherDevices() throws {
    let amp = SimulatedAmp(map: try .bundled())
    #expect(amp.deviceID == 0x00)
    let before = amp.memory(at: .userPatch(3), count: 2)
    try amp.send(SysEx.dt1(.userPatch(3), data: [0x41, 0x42], deviceID: 0x10))
    #expect(amp.memory(at: .userPatch(3), count: 2) == before)
}

@Test func storedPatchesHaveNames() throws {
    let amp = SimulatedAmp(map: try .bundled())
    #expect(PatchName.decode(amp.memory(at: .userPatch(1), count: 16)) == "SIM PATCH 1")
    #expect(PatchName.decode(amp.memory(at: .temporaryPatch, count: 16)) == "SIM LIVE")
}

@Test func changesOnTheAmpAreSentAsDataSets() async throws {
    let amp = SimulatedAmp(map: try .bundled())
    let address = Address.temporaryPatch.advanced(by: 0x28)
    amp.changeOnAmp([42], at: address)
    var messages = amp.incoming.makeAsyncIterator()
    #expect(await messages.next() == SysEx.dt1(address, data: [42], deviceID: amp.deviceID))
    #expect(amp.memory(at: address, count: 1) == [42])
}

// A colour-button press moves an effect that is on to its next colour and reports the selection and the LED; an effect
// that is off stays off. A VARIATION press toggles its LED.
@Test func panelButtonPressesCycleColoursAndToggleVariation() async throws {
    let map = try ParameterMap.bundled()
    let amp = SimulatedAmp(map: map)
    let led = try #require(map.parameter(block: "Status", prm: "PRM_LED_STATE_BOOST"))
    let selection = try #require(map.parameter(block: "Patch_2", prm: "PRM_FXBOX_SEL_BOOST"))
    let variation = try #require(map.parameter(block: "Status", prm: "PRM_LED_STATE_VARI"))
    let ledAddress = Address.temporaryPatch.advanced(by: led.offset)
    let selectionAddress = Address.temporaryPatch.advanced(by: selection.offset)
    let variationAddress = Address.temporaryPatch.advanced(by: variation.offset)
    amp.setMemory([1], at: ledAddress)
    amp.setMemory([0], at: selectionAddress)
    var colours: [UInt8] = []
    for _ in 0..<3 {
        try amp.send(SysEx.dt1(PanelButton.booster.address, data: [0], deviceID: amp.deviceID))
        colours += amp.memory(at: ledAddress, count: 1)
    }
    #expect(colours == [2, 3, 1])
    var reports = amp.incoming.makeAsyncIterator()
    #expect(await reports.next() == SysEx.dt1(selectionAddress, data: [1], deviceID: amp.deviceID))
    #expect(await reports.next() == SysEx.dt1(ledAddress, data: [2], deviceID: amp.deviceID))
    amp.setMemory([0], at: ledAddress)
    try amp.send(SysEx.dt1(PanelButton.booster.address, data: [0], deviceID: amp.deviceID))
    #expect(amp.memory(at: ledAddress, count: 1) == [0])
    try amp.send(SysEx.dt1(PanelButton.variation.address, data: [0], deviceID: amp.deviceID))
    #expect(amp.memory(at: variationAddress, count: 1) == [1])
}

@Test func choosingAColourLightsItWhenTheEffectIsOn() throws {
    let map = try ParameterMap.bundled()
    let amp = SimulatedAmp(map: map)
    let led = try #require(map.parameter(block: "Status", prm: PanelButton.booster.led))
    let selection = try #require(map.parameter(block: "Patch_2", prm: "PRM_FXBOX_SEL_BOOST"))
    let choose = { (colour: UInt8) in
        try amp.send(SysEx.dt1(.temporaryPatch.advanced(by: selection.offset), data: [colour], deviceID: 0))
    }
    // Off: the LED stays dark, as on the amp when the effect is off.
    try choose(2)
    #expect(amp.memory(at: .temporaryPatch.advanced(by: led.offset), count: 1) == [0])
    // On, GREEN: choosing YELLOW lights YELLOW.
    amp.setMemory([1], at: .temporaryPatch.advanced(by: led.offset))
    try choose(2)
    #expect(amp.memory(at: .temporaryPatch.advanced(by: led.offset), count: 1) == [3])
}

// An effect knob does what hardware check 3 logged on the amp: above −1 the effect is on and its LED shows the selected
// colour, and the knob sets some of the effect's parameters itself.
@Test func effectKnobsSwitchTheEffectAndSetWhatTheAmpSets() async throws {
    let map = try ParameterMap.bundled()
    let amp = SimulatedAmp(map: map)
    func parameter(_ block: String, _ prm: String) throws -> Parameter {
        try #require(map.parameter(block: block, prm: prm))
    }
    func value(_ parameter: Parameter) -> Int {
        let bytes = amp.memory(at: .temporaryPatch.advanced(by: parameter.offset), count: parameter.encoding.byteCount)
        return parameter.value(fromRaw: parameter.encoding.decode(bytes))
    }
    func set(_ parameter: Parameter, to value: Int) throws {
        try amp.send(
            SysEx.dt1(
                .temporaryPatch.advanced(by: parameter.offset),
                data: parameter.encoding.encode(value + parameter.rawOffset), deviceID: amp.deviceID))
    }
    let delayKnob = try parameter("Status", "PRM_KNOB_POS_DELAY")
    let delayOn = try parameter("Delay(1)", "PRM_DLY_SW")
    let delayLED = try parameter("Status", "PRM_LED_STATE_DELAY")
    let delayLevel = try parameter("Delay(1)", "PRM_DLY_COMMON_EFFECT_LEVEL")
    let delayFeedback = try parameter("Delay(1)", "PRM_DLY_COMMON_FEEDBACK")
    try set(try parameter("Patch_2", "PRM_FXBOX_SEL_DELAY"), to: 1)
    try set(delayKnob, to: 50)
    #expect(value(delayOn) == 1 && value(delayLED) == 2)
    #expect(value(delayLevel) == 70 && value(delayFeedback) == 29)
    try set(delayKnob, to: -1)
    #expect(value(delayOn) == 0 && value(delayLED) == 0)

    let drive = try parameter("Patch_0", "PRM_ODDS_DRIVE")
    let boosterLevel = try parameter("Patch_0", "PRM_ODDS_EFFECT_LEVEL")
    let reverbLevel = try parameter("Patch_1", "PRM_REVERB_EFFECT_LEVEL")
    try set(try parameter("Status", "PRM_KNOB_POS_BOOST"), to: 50)
    try set(try parameter("Status", "PRM_KNOB_POS_REVERB"), to: 50)
    #expect(value(drive) == 36 && value(boosterLevel) == 57 && value(reverbLevel) == 66)

    // MOD and FX set the rate of a chorus or a tremolo, measured with one each; other types keep their values.
    let modKnob = try parameter("Status", "PRM_KNOB_POS_MOD")
    let modType = try parameter("Fx(1)", "PRM_FX1_FXTYPE")
    let lowRate = try parameter("Fx(1)", "PRM_FX1_2x2CHORUS_LOW_RATE")
    let highRate = try parameter("Fx(1)", "PRM_FX1_2x2CHORUS_HIGH_RATE")
    let tremoloRate = try parameter("Fx(2)", "PRM_FX1_TREMOLO_RATE")
    try set(modType, to: 29)
    try set(modKnob, to: 70)
    #expect(value(lowRate) == 62 && value(highRate) == 52)
    try set(try parameter("Fx(2)", "PRM_FX1_FXTYPE"), to: 21)
    try set(try parameter("Status", "PRM_KNOB_POS_FX"), to: 70)
    #expect(value(tremoloRate) == 64)
    try set(modType, to: 0)
    try set(modKnob, to: 10)
    #expect(value(lowRate) == 62)
}
