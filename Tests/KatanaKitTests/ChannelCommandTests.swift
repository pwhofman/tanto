import Testing

@testable import KatanaKit

// The commands of plan 3 that switch and save channels, against the simulated amp.

private func connectedSession() async throws -> (SimulatedAmp, AmpSession, ParameterMap, Parameter) {
    let map = try ParameterMap.bundled()
    let amp = SimulatedAmp(map: map)
    let volume = try #require(map.parameter(block: "Status", prm: "PRM_KNOB_POS_VOLUME"))
    amp.setMemory([88], at: Address.userPatch(6).advanced(by: volume.offset))
    let session = AmpSession(transport: amp)
    _ = try await session.connect()
    try await session.readLivePatch(map)
    return (amp, session, map, volume)
}

@Test func selectingAChannelWritesItsNumberAsToneStudioDoesAndReadsTheChannelBack() async throws {
    let (amp, session, _, volume) = try await connectedSession()
    let before = await session.guardSnapshot(of: []).generation
    try await session.select(6)
    // Tone Studio's channel list writes PATCH NUM; the amp ignores 7F 00 01 00 for this (hardware check 3).
    #expect(amp.received.contains { $0.message == SysEx.dt1(Address(packed: 0x0001_0000), data: [0, 6], deviceID: 0) })
    #expect(await session.currentChannel == 6)
    #expect(await session.liveValue(of: volume) == 88)
    #expect(await session.isLivePatchValid)
    #expect(await session.guardSnapshot(of: []).generation > before)
}

@Test func aSelectDropsWritesDecidedOnTheOldChannel() async throws {
    let (amp, session, map, _) = try await connectedSession()
    let bass = try #require(map.parameter(block: "Status", prm: "PRM_KNOB_POS_BASS"))
    let basis = await session.guardSnapshot(of: [bass]).basis([bass])
    try await session.select(6)
    let start = amp.received.count
    #expect(try await !session.write(70, to: bass, basis: basis))
    #expect(amp.received.count == start)
}

@Test func savingWaitsForTheAmpsConfirmation() async throws {
    let (amp, session, map, _) = try await connectedSession()
    try await session.savePatch(to: 3)
    #expect(amp.received.last?.message == SysEx.dt1(Address(packed: 0x7F00_0104), data: [0, 3], deviceID: 0))
    #expect(
        amp.memory(at: .userPatch(3), count: map.patchSize) == amp.memory(at: .temporaryPatch, count: map.patchSize))
}

@Test func savingFailsWithoutAConfirmation() async throws {
    let (amp, session, _, _) = try await connectedSession()
    amp.setConfirmsSaves(false)
    await #expect(throws: AmpError.noSaveConfirmation(3)) {
        try await session.savePatch(to: 3, timeout: .milliseconds(100))
    }
}

@Test func aSaveMadeOnTheAmpIsReported() async throws {
    let (amp, session, _, _) = try await connectedSession()
    var updates = session.updates.makeAsyncIterator()
    _ = await updates.next()  // the initial read
    amp.sendFromAmp(SysEx.dt1(Address(packed: 0x7F00_0104), data: [0, 5], deviceID: 0))
    #expect(await updates.next() == .patchSaved(5))
}

@Test func storedWritesStayInsideChannelsOneToEight() async throws {
    let (amp, session, map, _) = try await connectedSession()
    try await session.writeStored(Array("RENAMED".utf8), slot: 4, offset: 0)
    #expect(amp.memory(at: .userPatch(4), count: 7) == Array("RENAMED".utf8))
    await #expect(throws: WriteError.noSuchChannel(0)) { try await session.writeStored([65], slot: 0, offset: 0) }
    await #expect(throws: WriteError.noSuchChannel(9)) { try await session.writeStored([65], slot: 9, offset: 0) }
    await #expect(throws: WriteError.outsideChannel(offset: map.patchSize - 1, count: 2)) {
        try await session.writeStored([65, 66], slot: 4, offset: map.patchSize - 1)
    }
    await #expect(throws: WriteError.outsideChannel(offset: 0, count: 129)) {
        try await session.writeStored(Array(repeating: 65, count: 129), slot: 4, offset: 0)
    }
    await #expect(throws: WriteError.noSuchChannel(0)) { try await session.savePatch(to: 0) }
    await #expect(throws: WriteError.noSuchChannel(9)) { try await session.select(9) }
}
