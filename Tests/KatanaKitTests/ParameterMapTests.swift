import Foundation
import Testing

@testable import KatanaKit

@Test func bundledTableMatchesToneStudio() throws {
    let map = try ParameterMap.bundled()
    #expect(map.table.blocks.count == 31)
    #expect(map.table.parameters.count == 1465)
    #expect(map.table.parameters.filter(\.written).count == 616)
    #expect(map.patchSize == 1986)
}

@Test func guardedParametersMatchTheSpec() throws {
    let map = try ParameterMap.bundled()
    let guarded = map.table.parameters.filter(\.guarded)
    #expect(guarded.count == 217)
    // Read-only: Tone Studio never writes these, so Tanto only reads them (spec 3.5).
    #expect(
        Set(guarded.filter { !$0.written }.map(\.prm)) == [
            "PRM_PREAMP_A_GAIN", "PRM_PREAMP_A_LEVEL", "PRM_PREAMP_A_SOLO_LEVEL", "PRM_FOOT_VOLUME_VOL_LEVEL",
        ])
}

@Test func panicUsesTheVolumeKnob() throws {
    let map = try ParameterMap.bundled()
    let knob = try #require(map.parameter(block: "Status", prm: "PRM_KNOB_POS_VOLUME"))
    let ampVolume = try #require(map.parameter(block: "Patch_0", prm: "PRM_PREAMP_A_LEVEL"))
    #expect(Address.temporaryPatch.advanced(by: knob.offset).description == "60 00 06 52")
    #expect(knob.written && knob.guarded && knob.section == "amp")
    #expect(Address.temporaryPatch.advanced(by: ampVolume.offset).description == "60 00 00 28")
    #expect(ampVolume.guarded && !ampVolume.written)
}

@Test func kindsFollowTheParameterNotTheControl() throws {
    let map = try ParameterMap.bundled()
    let ampType = try #require(map.parameter(block: "Status", prm: "PRM_KNOB_POS_TYPE"))
    #expect(ampType.kind == .picker)
    #expect(ampType.options?.map(\.label) == ["ACOUSTIC", "CLEAN", "CRUNCH", "LEAD", "BROWN"])
    #expect(map.parameter(block: "Patch_0", prm: "PRM_ODDS_SOLO_SW")?.kind == .toggle)
    #expect(
        map.parameter(block: "Patch_0", prm: "PRM_ODDS_TYPE")?.options?.first
            == Parameter.Option(value: 1, label: "CLEAN BOOST"))
    #expect(map.parameter(block: "Patch_0", prm: "PRM_PATCH_NAME0") == nil)
    #expect(map.parameter(block: "PatchName", prm: "PRM_PATCH_NAME0")?.kind == .text)
}

@Test func displayDetailsAreDecoded() throws {
    let map = try ParameterMap.bundled()
    #expect(map.parameter(block: "Patch_0", prm: "PRM_EQ_GEQ_BAND1")?.format == .signedHalfDecibels)
    #expect(map.parameter(block: "Status", prm: "PRM_KNOB_POS_BOOST")?.format == .offBelowZero)
    #expect(map.parameter(block: "Patch_0", prm: "PRM_ODDS_SOLO_SW")?.valueLabels == ["OFF", "ON"])
    let peak = try #require(map.parameter(block: "Fx(1)", prm: "PRM_FX1_TWAH_PEAK"))
    #expect(peak.visibleWhen == [Parameter.Condition(offset: 129, values: [0])])
    #expect(peak.label == "PEAK" && peak.section == "mod")
}

@Test func parametersLieInsideTheirBlocksWithoutOverlap() throws {
    let map = try ParameterMap.bundled()
    let blocks = Dictionary(uniqueKeysWithValues: map.table.blocks.map { ($0.name, $0) })
    for parameter in map.table.parameters {
        let block = try #require(blocks[parameter.block])
        #expect(parameter.offset >= block.offset)
        #expect(parameter.offset + parameter.encoding.byteCount <= block.offset + block.size)
    }
    let sorted = map.table.parameters.sorted { $0.offset < $1.offset }
    for (first, second) in zip(sorted, sorted.dropFirst()) {
        #expect(first.offset + first.encoding.byteCount <= second.offset, "\(first.prm) overlaps \(second.prm)")
    }
}

@Test func valuesSubtractTheRawOffset() throws {
    let map = try ParameterMap.bundled()
    let lowGain = try #require(map.parameter(block: "Patch_0", prm: "PRM_EQ_LOW_GAIN"))
    #expect(lowGain.rawOffset == 20)
    #expect(map.values(in: [23], at: lowGain.offset) == [ParameterValue(parameter: lowGain, value: 3)])
}

@Test func aTableLoadsFromAFile() throws {
    let table = try ParameterMap.bundled().table
    let url = FileManager.default.temporaryDirectory.appending(path: "parameters-\(UUID().uuidString).json")
    try JSONEncoder().encode(table).write(to: url)
    let loaded = try ParameterMap(contentsOf: url)
    try FileManager.default.removeItem(at: url)
    #expect(loaded.table == table)
}

@Test func controlsKnowHowAndWhereToneStudioShowsThem() throws {
    let map = try ParameterMap.bundled()
    let drive = try #require(map.parameter(block: "Patch_0", prm: "PRM_ODDS_DRIVE"))
    #expect(drive.control == .knob && drive.position == Parameter.Position(x: 34, y: 101) && drive.panel == nil)
    #expect(drive.page == "booster")
    let gain = try #require(map.parameter(block: "Status", prm: "PRM_KNOB_POS_GAIN"))
    #expect(gain.panel == Parameter.Position(x: 124, y: 88) && gain.page == nil)
    #expect(try #require(map.parameter(block: "Patch_2", prm: "PRM_FXBOX_ASGN_BOOSTER_G")).page == "effects-booster")
    // EFFECT LEVEL moves with DELAY TYPE, as on Tone Studio's pages: DIGITAL, PAN, MODULATE.
    let level = try #require(map.parameter(block: "Delay(1)", prm: "PRM_DLY_COMMON_EFFECT_LEVEL"))
    let type = try #require(map.parameter(block: "Delay(1)", prm: "PRM_DLY_TYPE"))
    for (delayType, x) in [(0, 322), (1, 418), (9, 514)] {
        #expect(level.position { $0 == type.offset ? delayType : nil } == Parameter.Position(x: x, y: 101))
    }
    #expect(try #require(map.parameter(block: "Fx(1)", prm: "PRM_FX1_GEQ_BAND1")).control == .slider)
}

@Test func theWindowsFixedControlsAreInTheTable() throws {
    let map = try ParameterMap.bundled()
    // The ids that Tanto's front panel shows (Sources/Tanto/FrontPanel.swift); each needs exactly one panel control,
    // or the window stops.
    let panel = [
        "PRM_KNOB_POS_TYPE", "PRM_KNOB_POS_GAIN", "PRM_KNOB_POS_VOLUME", "PRM_KNOB_POS_BASS", "PRM_KNOB_POS_MIDDLE",
        "PRM_KNOB_POS_TREBLE", "PRM_KNOB_POS_BOOST", "PRM_KNOB_POS_MOD", "PRM_KNOB_POS_FX", "PRM_KNOB_POS_DELAY",
        "PRM_KNOB_POS_REVERB", "PRM_CABINET_RESONANCE", "PRM_KNOB_POS_PRESENCE", "PRM_SOLO_SW", "PRM_SOLO_LEVEL",
        "PRM_CONTOUR_SW", "PRM_CONTOUR_SELECT",
    ]
    for id in panel {
        #expect(map.table.parameters.count { $0.prm == id && $0.panel != nil } == 1, "\(id)")
    }
    // The CHAIN page draws a diagram for each of the values 0–6.
    let chain = try #require(map.parameter(block: "Patch_2", prm: "PRM_CHAIN_PTN"))
    #expect(chain.options?.map(\.value) == Array(0...6))
}
