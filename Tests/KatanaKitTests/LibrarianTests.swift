import Testing

@testable import KatanaKit

/// A connected session over a hookable simulated amp, with a guard and a librarian.
private struct LibrarianRig {
    let map: ParameterMap
    let amp: SimulatedAmp
    let transport: HookTransport
    let session: AmpSession
    let safety: SafetyGuard
    let librarian: Librarian
    let volume: Parameter

    init() async throws {
        map = try ParameterMap.bundled()
        amp = SimulatedAmp(map: map)
        volume = try #require(map.parameter(block: "Status", prm: "PRM_KNOB_POS_VOLUME"))
        amp.setMemory([10], at: .temporaryPatch.advanced(by: volume.offset))
        transport = HookTransport(amp: amp)
        // A quick spacing: a backup reads 248 blocks, at 20 ms that takes 5 s.
        session = AmpSession(
            transport: transport, timing: SessionTiming(spacing: .milliseconds(1), readTimeout: .seconds(1)))
        _ = try await session.connect()
        _ = try await session.readCurrentChannel()
        try await session.readLivePatch(map)
        safety = try SafetyGuard(session: session, map: map, rampDuration: .seconds(2))
        librarian = Librarian(session: session, safety: safety, map: map)
    }
}

@Test func aBackupRestoredAndBackedUpAgainIsByteForByteTheSame() async throws {
    let rig = try await LibrarianRig()
    let first = try await rig.librarian.backup()
    rig.amp.setMemory(Array(repeating: 0x11, count: 300), at: Address.userPatch(3).advanced(by: 100))
    rig.amp.setMemory(Array("CHANGED".utf8), at: .userPatch(7))
    #expect(try await rig.librarian.restore(first).isEmpty)
    let second = try await rig.librarian.backup()
    #expect(second.channels == first.channels)
}

@Test func aRestoreThatStopsHalfwayNamesTheLastChannelWritten() async throws {
    let rig = try await LibrarianRig()
    let backup = try await rig.librarian.backup()
    let channel4 = Address.userPatch(4).linear
    rig.transport.setHook { message in
        if case .dataSet(let address, _) = IncomingMessage(message), address.linear >= channel4,
            address.linear < Address.userPatch(5).linear
        {
            throw CocoaLikeFailure()
        }
    }
    await #expect(throws: LibrarianError.restoreStopped(lastChannelWritten: 3)) {
        _ = try await rig.librarian.restore(backup)
    }
}

private struct CocoaLikeFailure: Error {}

@Test func renamingChangesOnlyTheNameAndTheLiveNameOfTheCurrentChannel() async throws {
    let rig = try await LibrarianRig()
    let before = try await rig.librarian.read(5)
    try await rig.librarian.rename(5, to: "NEW NAME")
    let after = try await rig.librarian.read(5)
    #expect(after.prefix(16) == ArraySlice(Array("NEW NAME        ".utf8)))
    #expect(after.dropFirst(16) == before.dropFirst(16))
    #expect(await rig.session.liveName() == "SIM LIVE")
    #expect(await rig.session.currentChannel == 1)
    try await rig.librarian.rename(1, to: "LIVE NAME")
    #expect(await rig.session.liveName() == "LIVE NAME")
    await #expect(throws: WriteError.invalidName("SEVENTEEN LETTERS")) {
        try await rig.librarian.rename(2, to: "SEVENTEEN LETTERS")
    }
}

@Test func savingStoresWhatTheGuardRampsTowardsAndSelectsTheChannel() async throws {
    let rig = try await LibrarianRig()
    try await rig.safety.set(rig.volume, to: 30)
    let name = try await rig.librarian.save(to: 4)
    #expect(name == "SIM LIVE")
    #expect(rig.amp.memory(at: Address.userPatch(4).advanced(by: rig.volume.offset), count: 1) == [30])
    #expect(await rig.session.currentChannel == 4)
}

@Test func theCeilingCheckReadsTheChannelFromTheAmp() async throws {
    let rig = try await LibrarianRig()
    rig.amp.setMemory([88], at: Address.userPatch(6).advanced(by: rig.volume.offset))
    let above = try await rig.librarian.valuesAboveCeiling(6)
    #expect(above.contains(ParameterValue(parameter: rig.volume, value: 88)))
    #expect(try await rig.librarian.valuesAboveCeiling(5).isEmpty)
}
