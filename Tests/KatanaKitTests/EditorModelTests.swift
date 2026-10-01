import Foundation
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
@Test func pagesFollowToneStudiosTabs() async throws {
    let model = EditorModel(map: try ParameterMap.bundled())
    #expect(
        model.pages.map { $0.map(\.title) } == [
            ["EFFECTS", "CHAIN"], ["BOOSTER", "MOD", "FX", "DELAY", "DELAY2", "REVERB", "SOLO", "CONTOUR"],
            ["PEDAL FX", "EQ", "EQ2", "NS", "SEND/RETURN"],
        ])
    let pages = Dictionary(uniqueKeysWithValues: model.pages.joined().map { ($0.title, $0.parameters) })
    // EFFECTS holds every effect's GREEN, RED and YELLOW assignment; CHAIN the order of the blocks.
    let effects = try #require(pages["EFFECTS"])
    #expect(effects.count == 21 && effects.allSatisfy { $0.control == .menu && $0.page?.hasPrefix("effects-") == true })
    #expect(try #require(pages["CHAIN"]).map(\.prm) == ["PRM_CHAIN_PTN"])
    // A page holds its block's controls; the front panel and the EFFECTS page show the others.
    let booster = try #require(pages["BOOSTER"]).map(\.prm)
    #expect(booster.first == "PRM_ODDS_SW" && booster.count == 9)
    #expect(!booster.contains("PRM_KNOB_POS_BOOST") && !booster.contains("PRM_FXBOX_ASGN_BOOSTER_G"))
    // MOD and FX share Tone Studio's page, as do DELAY and DELAY2, but each tab edits its own block.
    #expect(try #require(pages["FX"]).allSatisfy { $0.block == "Fx(2)" })
    #expect(try #require(pages["DELAY2"]).allSatisfy { $0.block == "Delay(2)" })
    #expect(try #require(pages["DELAY"]).contains { $0.prm == "PRM_DLY_COMMON_DLY_TIME" })
    #expect(pages.values.allSatisfy { $0.allSatisfy { $0.written && $0.kind != .text && $0.position != nil } })
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

@MainActor
@Test func panelButtonsArePressedThroughTheGuard() async throws {
    let (model, _) = try await connectedModel()
    let led = try #require(model.led(of: .variation))
    #expect(try await eventually { model.value(of: led) == 0 })
    await model.press(.variation)
    await model.settle()
    #expect(try await eventually { model.value(of: led) == 1 })
    #expect(model.buttonRefusals[.variation] == nil)
}

@MainActor
private func modelWithLoudChannel() async throws -> (EditorModel, SimulatedAmp, Parameter) {
    let map = try ParameterMap.bundled()
    let amp = SimulatedAmp(map: map)
    let volume = try #require(map.parameter(block: "Status", prm: "PRM_KNOB_POS_VOLUME"))
    amp.setMemory([30], at: .temporaryPatch.advanced(by: volume.offset))
    amp.setMemory([88], at: Address.userPatch(6).advanced(by: volume.offset))
    let model = EditorModel(map: map)
    await model.connect(amp, timing: SessionTiming(spacing: .milliseconds(1), readTimeout: .seconds(1)))
    return (model, amp, volume)
}

@MainActor
@Test func aSwitchWithoutAReasonToAskHappensAtOnce() async throws {
    let (model, _, _) = try await modelWithLoudChannel()
    await model.requestSwitch(to: 5)
    #expect(model.pendingSwitch == nil)
    #expect(try await eventually { model.currentChannel == 5 })
    #expect(!model.hasUnsavedEdits)
}

@MainActor
@Test func aSwitchAsksAboutUnsavedEditsAndThenAboutTheCeiling() async throws {
    let (model, _, volume) = try await modelWithLoudChannel()
    await model.set(volume, to: 20)
    #expect(model.hasUnsavedEdits)
    await model.requestSwitch(to: 6)
    #expect(model.pendingSwitch == EditorModel.PendingSwitch(slot: 6, question: .unsavedEdits))
    await model.answerSwitch(true)
    #expect(
        model.pendingSwitch
            == EditorModel.PendingSwitch(
                slot: 6, question: .valuesAboveCeiling([ParameterValue(parameter: volume, value: 88)])))
    await model.answerSwitch(false)
    #expect(model.pendingSwitch == nil)
    #expect(model.currentChannel == 1)
    await model.requestSwitch(to: 6)
    await model.answerSwitch(true)
    await model.answerSwitch(true)
    #expect(try await eventually { model.currentChannel == 6 && model.value(of: volume) == 88 })
    #expect(!model.hasUnsavedEdits)
}

@MainActor
@Test func savesRenamesAndSavesMadeOnTheAmpUpdateTheNames() async throws {
    let (model, amp, _) = try await modelWithLoudChannel()
    await model.save(to: 3)
    #expect(model.channelNames[3] == "SIM LIVE")
    #expect(try await eventually { model.currentChannel == 3 })
    await model.rename(4, to: "RENAMED")
    #expect(model.channelNames[4] == "RENAMED")
    amp.setMemory(Array("SAVED ON THE AMP".utf8), at: .userPatch(7))
    amp.sendFromAmp(SysEx.dt1(.patchWrite, data: [0, 7], deviceID: 0))
    #expect(try await eventually { model.channelNames[7] == "SAVED ON THE AMP" })
    #expect(model.librarianMessage == nil)
}

@MainActor
@Test func aBackupFileIsCheckedAndRestored() async throws {
    let (model, amp, _) = try await modelWithLoudChannel()
    let backup = try #require(await model.backup())
    let data = try backup.encoded()
    #expect(model.checkBackupFile(data, against: backup))
    amp.setMemory(Array("CHANGED".utf8), at: .userPatch(2))
    let loaded = try #require(model.loadBackup(data))
    await model.restore(loaded)
    #expect(model.channelNames[2] == "SIM PATCH 2")
    #expect(amp.memory(at: .userPatch(2), count: 7) == Array("SIM PAT".utf8))
    #expect(model.loadBackup(Data("{}".utf8)) == nil)
    #expect(model.librarianMessage != nil)
}

/// The values that DT1s wrote to a one-byte `parameter` of the live patch, in order.
private func writes(to parameter: Parameter, in amp: SimulatedAmp) -> [Int] {
    let address = Address.temporaryPatch.advanced(by: parameter.offset)
    return amp.received.compactMap { received in
        (parameter.minimum...parameter.maximum).first { value in
            received.message == SysEx.dt1(address, data: [UInt8(value + parameter.rawOffset)], deviceID: 0)
        }
    }
}

@MainActor
@Test func contourSwitchesOnThenSelectsAsToneStudioDoes() async throws {
    let (model, amp) = try await connectedModel()
    let onOff = try #require(model.map.parameter(block: "Patch_1", prm: "PRM_CONTOUR_SW"))
    let select = try #require(model.map.parameter(block: "Patch_1", prm: "PRM_CONTOUR_SELECT"))
    #expect(model.contour == 0)
    // OFF to 2: the switch, then the selection.
    await model.setContour(2)
    await model.settle()
    #expect(try await eventually { model.contour == 2 })
    #expect(writes(to: onOff, in: amp) == [1] && writes(to: select, in: amp) == [1])
    // 2 to 3: only the selection.
    await model.setContour(3)
    await model.settle()
    #expect(try await eventually { model.contour == 3 })
    #expect(writes(to: onOff, in: amp) == [1] && writes(to: select, in: amp) == [1, 2])
    // 3 to OFF: only the switch.
    await model.setContour(0)
    await model.settle()
    #expect(try await eventually { model.contour == 0 })
    #expect(writes(to: onOff, in: amp) == [1, 0] && writes(to: select, in: amp) == [1, 2])
}

@MainActor
@Test func aPanicRightAfterChoosingAContourSendsNeitherWrite() async throws {
    let (model, amp) = try await connectedModel()
    let onOff = try #require(model.map.parameter(block: "Patch_1", prm: "PRM_CONTOUR_SW"))
    let select = try #require(model.map.parameter(block: "Patch_1", prm: "PRM_CONTOUR_SELECT"))
    async let choosing: Void = model.setContour(2)
    // While the switch waits for its soft switch.
    try await Task.sleep(for: .milliseconds(5))
    await model.panic()
    await choosing
    await model.settle()
    #expect(writes(to: onOff, in: amp).isEmpty && writes(to: select, in: amp).isEmpty)
    #expect(model.contour == 0)
}
