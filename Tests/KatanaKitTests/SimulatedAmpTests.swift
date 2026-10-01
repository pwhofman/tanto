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
