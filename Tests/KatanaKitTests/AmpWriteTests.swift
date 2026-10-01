import Testing

@testable import KatanaKit

private func connectedSession() async throws -> (SimulatedAmp, AmpSession, ParameterMap) {
    let map = try ParameterMap.bundled()
    let amp = SimulatedAmp(map: map)
    let session = AmpSession(transport: amp)
    _ = try await session.connect()
    try await session.readLivePatch(map)
    return (amp, session, map)
}

private func parameter(_ map: ParameterMap, _ block: String, _ prm: String) throws -> Parameter {
    try #require(map.parameter(block: block, prm: prm))
}

private func dataSets(_ amp: SimulatedAmp) -> [(Address, [UInt8])] {
    amp.received.compactMap { received in
        if case .dataSet(let address, let data) = IncomingMessage(received.message) { (address, data) } else { nil }
    }
}

@Test func writesAValueAndUpdatesTheLiveCopy() async throws {
    let (amp, session, map) = try await connectedSession()
    let knob = try parameter(map, "Status", "PRM_KNOB_POS_VOLUME")
    try await session.write(30, to: knob)
    #expect(amp.received.last?.message == SysEx.dt1(Address(packed: 0x6000_0652), data: [30], deviceID: 0x00))
    #expect(amp.memory(at: .temporaryPatch.advanced(by: knob.offset), count: 1) == [30])
    #expect(await session.liveValue(of: knob) == 30)
}

@Test func refusesParametersToneStudioDoesNotWrite() async throws {
    let (amp, session, map) = try await connectedSession()
    for (block, prm) in [("Patch_0", "PRM_PREAMP_A_LEVEL"), ("Patch_1", "PRM_FOOT_VOLUME_VOL_LEVEL")] {
        let target = try parameter(map, block, prm)
        await #expect(throws: WriteError.notWritable(prm)) {
            try await session.write(0, to: target)
        }
    }
    #expect(dataSets(amp).map(\.0) == [.editorCommunicationMode])
}

@Test func refusesValuesOutsideTheRange() async throws {
    let (amp, session, map) = try await connectedSession()
    let knob = try parameter(map, "Status", "PRM_KNOB_POS_VOLUME")
    let lowGain = try parameter(map, "Patch_0", "PRM_EQ_LOW_GAIN")
    await #expect(throws: WriteError.outOfRange("PRM_KNOB_POS_VOLUME", 101)) {
        try await session.write(101, to: knob)
    }
    await #expect(throws: WriteError.outOfRange("PRM_EQ_LOW_GAIN", -21)) {
        try await session.write(-21, to: lowGain)
    }
    #expect(dataSets(amp).count == 1)
}

@Test func encodesRawOffsetsAndTwoByteValues() async throws {
    let (amp, session, map) = try await connectedSession()
    try await session.write(-3, to: parameter(map, "Patch_0", "PRM_EQ_LOW_GAIN"))
    try await session.write(400, to: parameter(map, "Delay(1)", "PRM_DLY_COMMON_DLY_TIME"))
    #expect(dataSets(amp).suffix(2).map(\.1) == [[17], [0x03, 0x10]])
}

@Test func writesTheLivePatchName() async throws {
    let (amp, session, _) = try await connectedSession()
    try await session.writeLiveName("TANTO TEST")
    #expect(amp.received.last?.message == SysEx.dt1(.temporaryPatch, data: Array("TANTO TEST      ".utf8), deviceID: 0))
    #expect(await session.liveName() == "TANTO TEST")
    await #expect(throws: WriteError.invalidName("ÉTUDE")) {
        try await session.writeLiveName("ÉTUDE")
    }
    await #expect(throws: WriteError.invalidName("SEVENTEEN LETTERS")) {
        try await session.writeLiveName("SEVENTEEN LETTERS")
    }
}

@Test func priorityWritesGoNextAndKeepTheSpacing() async throws {
    let (amp, session, map) = try await connectedSession()
    let gain = try parameter(map, "Status", "PRM_KNOB_POS_GAIN")
    let volume = try parameter(map, "Status", "PRM_KNOB_POS_VOLUME")
    let before = amp.received.count
    let normal = (1...4).map { value in Task { try await session.write(value, to: gain) } }
    try await Task.sleep(for: .milliseconds(5))
    try await session.write(0, to: volume, priority: .high)
    for task in normal {
        try await task.value
    }
    let writes = amp.received.dropFirst(before)
    let order = writes.compactMap { received -> Int? in
        guard case .dataSet(let address, _) = IncomingMessage(received.message) else { return nil }
        return address.linear - Address.temporaryPatch.linear
    }
    // One normal write may already be in flight; the priority write comes right after it at the latest.
    #expect(order.prefix(2).contains(volume.offset))
    let times = writes.map(\.time)
    for (earlier, later) in zip(times, times.dropFirst()) {
        #expect(later - earlier >= .milliseconds(20))
    }
}
