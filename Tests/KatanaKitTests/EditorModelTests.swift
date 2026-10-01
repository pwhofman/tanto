import Testing

@testable import KatanaKit

/// Polls `condition` on the main actor until it holds, for at most a second.
@MainActor
private func eventually(_ condition: () -> Bool) async throws -> Bool {
    for _ in 0..<100 {
        if condition() { return true }
        try await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@MainActor
private func connectedModel() async throws -> (EditorModel, SimulatedAmp) {
    let map = try ParameterMap.bundled()
    let amp = SimulatedAmp(map: map)
    let volume = try #require(map.parameter(block: "Status", prm: "PRM_KNOB_POS_VOLUME"))
    amp.setMemory([30], at: .temporaryPatch.advanced(by: volume.offset))
    let model = EditorModel(map: map)
    await model.connect(amp)
    return (model, amp)
}

@MainActor
@Test func connectingReadsChannelsAndTheLivePatch() async throws {
    let (model, _) = try await connectedModel()
    #expect(model.connection == .connected)
    #expect(model.currentChannel == 1)
    #expect(model.channelNames.count == 9 && model.channelNames[2] == "SIM PATCH 2")
    #expect(model.liveName == "SIM LIVE")
    let volume = try #require(model.map.parameter(block: "Status", prm: "PRM_KNOB_POS_VOLUME"))
    #expect(try await eventually { model.value(of: volume) == 30 })
}

@MainActor
@Test func requestsGoThroughTheGuardAndShowUp() async throws {
    let (model, _) = try await connectedModel()
    let volume = try #require(model.map.parameter(block: "Status", prm: "PRM_KNOB_POS_VOLUME"))
    await model.set(volume, to: 34)
    await model.settle()
    #expect(try await eventually { model.value(of: volume) == 34 })
    #expect(model.refusals[volume.offset] == nil)
}

@MainActor
@Test func refusalsShowAMessageAndKeepTheAmpsValue() async throws {
    let (model, _) = try await connectedModel()
    let volume = try #require(model.map.parameter(block: "Status", prm: "PRM_KNOB_POS_VOLUME"))
    await model.set(volume, to: 80)
    await model.settle()
    #expect(model.refusals[volume.offset] == "Above the ceiling of 50")
    #expect(model.value(of: volume) == 30)
    await model.set(volume, to: 20)
    #expect(model.refusals[volume.offset] == nil)
}

@MainActor
@Test func panicSetsTheVolumeToZero() async throws {
    let (model, _) = try await connectedModel()
    let volume = try #require(model.map.parameter(block: "Status", prm: "PRM_KNOB_POS_VOLUME"))
    await model.panic()
    await model.settle()
    #expect(try await eventually { model.value(of: volume) == 0 })
}

@MainActor
@Test func changesOnTheAmpShowUp() async throws {
    let (model, amp) = try await connectedModel()
    let bass = try #require(model.map.parameter(block: "Status", prm: "PRM_KNOB_POS_BASS"))
    amp.changeOnAmp([77], at: .temporaryPatch.advanced(by: bass.offset))
    #expect(try await eventually { model.value(of: bass) == 77 })
    amp.switchChannelOnAmp(6)
    #expect(try await eventually { model.currentChannel == 6 && model.liveName == "SIM PATCH 6" })
}

@MainActor
@Test func parametersOfAnotherEffectTypeAppearWhenTheTypeChanges() async throws {
    let (model, _) = try await connectedModel()
    let modType = try #require(model.map.parameter(block: "Fx(1)", prm: "PRM_FX1_FXTYPE"))
    let tWahPeak = try #require(model.map.parameter(block: "Fx(1)", prm: "PRM_FX1_TWAH_PEAK"))
    await model.set(modType, to: 0)
    await model.settle()
    #expect(try await eventually { model.isVisible(tWahPeak) })
    await model.set(modType, to: 1)
    await model.settle()
    #expect(try await eventually { !model.isVisible(tWahPeak) })
}

@MainActor
@Test func sectionsFollowTheSpecWithThePanelFirst() async throws {
    let model = EditorModel(map: try ParameterMap.bundled())
    #expect(
        model.sections.map(\.id) == [
            "amp", "booster", "mod", "fx", "delay", "delay2", "reverb", "eq1", "eq2", "pedalfx", "ns", "sendreturn",
            "solo", "contour", "chain",
        ])
    let booster = try #require(model.sections.first { $0.id == "booster" })
    #expect(booster.title == "Booster")
    #expect(booster.parameters.prefix(2).map(\.prm) == ["PRM_KNOB_POS_BOOST", "PRM_LED_STATE_BOOST"])
    #expect(model.sections.allSatisfy { $0.parameters.allSatisfy { $0.written && $0.kind != .text } })
}

@MainActor
@Test func raisingTheCeilingNeedsConfirmation() async throws {
    let (model, _) = try await connectedModel()
    #expect(model.needsConfirmation(toSetCeilingPercent: 60))
    #expect(!model.needsConfirmation(toSetCeilingPercent: 40))
    try await model.setCeilingPercent(40)
    #expect(model.ceilingPercent == 40)
    let volume = try #require(model.map.parameter(block: "Status", prm: "PRM_KNOB_POS_VOLUME"))
    #expect(model.ceiling(of: volume) == 40)
    await #expect(throws: SafetyError.invalidCeiling(42)) { try await model.setCeilingPercent(42) }
}

@MainActor
@Test func quittingSwitchesEditorModeOffWithoutTheMainActor() async throws {
    let (model, amp) = try await connectedModel()
    model.disconnectWhileQuitting(timeout: .seconds(1))
    #expect(amp.received.last?.message == SysEx.dt1(.editorCommunicationMode, data: [0], deviceID: 0))
}
