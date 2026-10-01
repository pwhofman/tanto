import Testing

@testable import KatanaKit

private func connectedSession() async throws -> (SimulatedAmp, AmpSession, ParameterMap) {
    let map = try ParameterMap.bundled()
    let amp = SimulatedAmp(map: map)
    let session = AmpSession(transport: amp)
    _ = try await session.connect()
    return (amp, session, map)
}

@Test func readingTheLivePatchFillsTheMirror() async throws {
    let (amp, session, map) = try await connectedSession()
    let knob = try #require(map.parameter(block: "Status", prm: "PRM_KNOB_POS_VOLUME"))
    #expect(await session.liveValue(of: knob) == nil)
    amp.setMemory([37], at: .temporaryPatch.advanced(by: knob.offset))
    try await session.readLivePatch(map)
    #expect(await session.liveValue(of: knob) == 37)
    #expect(await session.liveName() == "SIM LIVE")
}

@Test func changesOnTheAmpUpdateTheMirror() async throws {
    let (amp, session, map) = try await connectedSession()
    try await session.readLivePatch(map)
    let gain = try #require(map.parameter(block: "Patch_0", prm: "PRM_PREAMP_A_GAIN"))
    var updates = session.updates.makeAsyncIterator()
    #expect(await updates.next() == .bytes(offset: 0, data: amp.memory(at: .temporaryPatch, count: map.patchSize)))
    amp.changeOnAmp([69], at: .temporaryPatch.advanced(by: gain.offset))
    #expect(await updates.next() == .bytes(offset: gain.offset, data: [69]))
    #expect(await session.liveValue(of: gain) == 69)
}

@Test func aChannelSwitchOnTheAmpReplacesTheMirror() async throws {
    let (amp, session, map) = try await connectedSession()
    try await session.readLivePatch(map)
    let knob = try #require(map.parameter(block: "Status", prm: "PRM_KNOB_POS_VOLUME"))
    amp.setMemory([88], at: Address.userPatch(6).advanced(by: knob.offset))
    var updates = session.updates.makeAsyncIterator()
    _ = await updates.next()  // the initial read
    amp.switchChannelOnAmp(6)
    #expect(await updates.next() == .channel(6))
    // The amp sends the new patch in messages of 241 bytes, as hardware check 1 showed.
    var received = 0
    while received < map.patchSize, case .bytes(_, let data) = await updates.next() {
        received += data.count
    }
    #expect(await session.currentChannel == 6)
    #expect(await session.liveValue(of: knob) == 88)
    #expect(await session.liveName() == "SIM PATCH 6")
}

@Test func theVolumeKnobRegisterSetsTheAmpVolumeInTheSimulator() throws {
    let map = try ParameterMap.bundled()
    let amp = SimulatedAmp(map: map)
    let knob = try #require(map.parameter(block: "Status", prm: "PRM_KNOB_POS_VOLUME"))
    let ampVolume = try #require(map.parameter(block: "Patch_0", prm: "PRM_PREAMP_A_LEVEL"))
    try amp.send(SysEx.dt1(.temporaryPatch.advanced(by: knob.offset), data: [12], deviceID: amp.deviceID))
    #expect(amp.memory(at: .temporaryPatch.advanced(by: ampVolume.offset), count: 1) == [12])
}

@Test func theCurrentChannelIsRead() async throws {
    let (_, session, _) = try await connectedSession()
    #expect(try await session.readCurrentChannel() == 1)
    #expect(await session.currentChannel == 1)
}

@Test func malformedMessagesLeaveTheMirrorAlone() async throws {
    let (amp, session, map) = try await connectedSession()
    try await session.readLivePatch(map)
    let gain = try #require(map.parameter(block: "Patch_0", prm: "PRM_PREAMP_A_GAIN"))
    let before = await session.liveValue(of: gain)
    var updates = session.updates.makeAsyncIterator()
    _ = await updates.next()  // the initial read
    var corrupted = SysEx.dt1(.temporaryPatch.advanced(by: gain.offset), data: [99], deviceID: amp.deviceID)
    corrupted[corrupted.count - 2] ^= 0x01
    amp.sendFromAmp(corrupted)
    amp.changeOnAmp([5], at: .temporaryPatch.advanced(by: 0x10))
    #expect(await updates.next() == .bytes(offset: 0x10, data: [5]))
    #expect(await session.liveValue(of: gain) == before)
}
