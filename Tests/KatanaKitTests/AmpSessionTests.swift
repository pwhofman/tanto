import Testing

@testable import KatanaKit

private let quickTimeout = SessionTiming(spacing: .milliseconds(20), readTimeout: .milliseconds(100))

@Test func connectSendsToneStudiosSequenceToTheAmpsDeviceID() async throws {
    let amp = SimulatedAmp(map: try .bundled())
    let info = try await AmpSession(transport: amp).connect()
    #expect(info.identityReply == SimulatedAmp.katanaIdentityReply)
    #expect(info.deviceID == 0x00)
    #expect(info.modelCode == 0x06)
    #expect(info.communicationLevel == 8)
    #expect(
        amp.received.map(\.message) == [
            SysEx.identityRequest,
            SysEx.rq1(.editorCommunicationLevel, size: 1, deviceID: 0x00),
            SysEx.dt1(.editorCommunicationMode, data: [1], deviceID: 0x00),
        ])
}

@Test func connectRefusesOtherCommunicationLevelsBeforeEditorMode() async throws {
    let amp = SimulatedAmp(map: try .bundled())
    amp.setMemory([9], at: .editorCommunicationLevel)
    await #expect(throws: AmpError.unsupportedCommunicationLevel(9)) {
        try await AmpSession(transport: amp).connect()
    }
    #expect(
        amp.received.map(\.message) == [
            SysEx.identityRequest, SysEx.rq1(.editorCommunicationLevel, size: 1, deviceID: 0x00),
        ])
}

@Test func connectRejectsOtherDevices() async throws {
    var reply = SimulatedAmp.katanaIdentityReply
    reply[6] = 0x34
    let amp = SimulatedAmp(map: try .bundled(), identityReply: reply)
    await #expect(throws: AmpError.notAKatana(reply)) {
        try await AmpSession(transport: amp).connect()
    }
    #expect(amp.received.map(\.message) == [SysEx.identityRequest])
}

@Test func connectRejectsAKatanaMkIIOtherThanTheKatana100() async throws {
    var reply = SimulatedAmp.katanaIdentityReply
    reply[10] = 0x07
    let amp = SimulatedAmp(map: try .bundled(), identityReply: reply)
    await #expect(throws: AmpError.notAKatana(reply)) {
        try await AmpSession(transport: amp).connect()
    }
    #expect(amp.received.map(\.message) == [SysEx.identityRequest])
}

@Test func readsAreSplitIntoRequestsOf128Bytes() async throws {
    let amp = SimulatedAmp(map: try .bundled())
    let session = AmpSession(transport: amp)
    _ = try await session.connect()
    let start = Address.temporaryPatch.advanced(by: 128)
    let data = try await session.read(start, size: 300)
    #expect(data == amp.memory(at: start, count: 300))
    #expect(
        amp.received.dropFirst(3).map(\.message) == [
            SysEx.rq1(start, size: 128, deviceID: 0x00),
            SysEx.rq1(start.advanced(by: 128), size: 128, deviceID: 0x00),
            SysEx.rq1(start.advanced(by: 256), size: 44, deviceID: 0x00),
        ])
}

@Test func messagesAreAtLeast20MillisecondsApart() async throws {
    let amp = SimulatedAmp(map: try .bundled())
    let session = AmpSession(transport: amp)
    _ = try await session.connect()
    _ = try await session.read(.temporaryPatch, size: 300)
    let times = amp.received.map(\.time)
    #expect(times.count == 6)
    for (earlier, later) in zip(times, times.dropFirst()) {
        #expect(later - earlier >= .milliseconds(20))
    }
}

@Test func readsGiveUpAfterOneRetry() async throws {
    let amp = SimulatedAmp(map: try .bundled())
    let session = AmpSession(transport: amp, timing: quickTimeout)
    _ = try await session.connect()
    amp.setAnswersReads(false)
    await #expect(throws: AmpError.timeout(.temporaryPatch)) {
        try await session.read(.temporaryPatch, size: 16)
    }
    #expect(
        amp.received.dropFirst(3).map(\.message)
            == Array(repeating: SysEx.rq1(.temporaryPatch, size: 16, deviceID: 0x00), count: 2))
}

@Test func changesMadeOnTheAmpAreReported() async throws {
    let amp = SimulatedAmp(map: try .bundled())
    let session = AmpSession(transport: amp)
    _ = try await session.connect()
    let volume = Address.temporaryPatch.advanced(by: 0x28)
    amp.changeOnAmp([42], at: volume)
    var changes = session.changes.makeAsyncIterator()
    #expect(await changes.next() == AmpChange(address: volume, data: [42]))
}

// The probe's whole sequence: the only DT1 messages are editor mode on and off.
@Test func connectingAndReadingWritesNothingButTheEditorModeFlag() async throws {
    let map = try ParameterMap.bundled()
    let amp = SimulatedAmp(map: map)
    let session = AmpSession(transport: amp)
    _ = try await session.connect()
    _ = try await session.read(.currentPatchNumber, size: 2)
    for slot in 0...8 {
        _ = try await session.read(.userPatch(slot), size: 16)
    }
    for block in map.table.blocks {
        _ = try await session.read(.temporaryPatch.advanced(by: block.offset), size: block.size)
    }
    try await session.disconnect()
    let writes = amp.received.compactMap { received -> [UInt8]? in
        if case .dataSet = IncomingMessage(received.message) { received.message } else { nil }
    }
    #expect(
        writes == [
            SysEx.dt1(.editorCommunicationMode, data: [1], deviceID: 0x00),
            SysEx.dt1(.editorCommunicationMode, data: [0], deviceID: 0x00),
        ])
    #expect(amp.received.last?.message == SysEx.dt1(.editorCommunicationMode, data: [0], deviceID: 0x00))
}
