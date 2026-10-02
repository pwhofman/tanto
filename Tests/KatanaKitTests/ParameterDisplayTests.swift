import Testing

@testable import KatanaKit

private func parameter(_ block: String, _ prm: String) throws -> Parameter {
    try #require(ParameterMap.bundled().parameter(block: block, prm: prm))
}

@Test func displayTextFollowsToneStudiosFormats() throws {
    let band = try parameter("Patch_0", "PRM_EQ_GEQ_BAND1")
    #expect(band.displayText(for: 3) == "+1.5dB")
    #expect(band.displayText(for: 2) == "+1.0dB")
    #expect(band.displayText(for: 0) == "0.0dB")
    #expect(band.displayText(for: -24) == "-12.0dB")
    #expect(try parameter("Patch_0", "PRM_EQ_LOW_GAIN").displayText(for: 3) == "+3dB")
    #expect(try parameter("Status", "PRM_KNOB_POS_BOOST").displayText(for: -1) == "OFF")
    #expect(try parameter("Status", "PRM_KNOB_POS_BOOST").displayText(for: 30) == "30")
    #expect(try parameter("Delay(1)", "PRM_DLY_COMMON_DLY_TIME").displayText(for: 320) == "320ms")
    #expect(try parameter("Status", "PRM_KNOB_POS_VOLUME").displayText(for: 42) == "42")
}

@Test func optionAndValueLabelsComeFirst() throws {
    #expect(try parameter("Patch_0", "PRM_ODDS_TYPE").displayText(for: 1) == "CLEAN BOOST")
    #expect(try parameter("Patch_0", "PRM_ODDS_SOLO_SW").displayText(for: 1) == "ON")
    #expect(try parameter("Status", "PRM_KNOB_POS_TYPE").displayText(for: 4) == "BROWN")
}

@Test func visibilityFollowsTheEffectType() throws {
    let peak = try parameter("Fx(1)", "PRM_FX1_TWAH_PEAK")
    let modType = try parameter("Fx(1)", "PRM_FX1_FXTYPE")
    #expect(peak.isVisible { $0 == modType.offset ? 0 : nil })
    #expect(!peak.isVisible { $0 == modType.offset ? 1 : nil })
    #expect(!peak.isVisible { _ in nil })
    #expect(try parameter("Status", "PRM_KNOB_POS_VOLUME").isVisible { _ in nil })
}

// Every value of every knob and slider reads back from its own text, as Tone Studio's number pad takes a typed value.
@Test func everyKnobValueReadsBackFromItsText() throws {
    let map = try ParameterMap.bundled()
    var failures: [String] = []
    for parameter in map.table.parameters
    where parameter.written && parameter.kind == .numeric && parameter.control != .menu {
        for value in parameter.minimum...parameter.maximum
        where parameter.value(forText: parameter.displayText(for: value)) != value {
            failures.append("\(parameter.prm) \(value) \(parameter.displayText(for: value))")
        }
    }
    #expect(failures.isEmpty, "\(failures.prefix(10))")
}

@Test func typedValuesNeedNoUnitAndAreClampedToTheRange() throws {
    let map = try ParameterMap.bundled()
    func parameter(_ block: String, _ prm: String) throws -> Parameter {
        try #require(map.parameter(block: block, prm: prm))
    }
    let time = try parameter("Delay(1)", "PRM_DLY_COMMON_DLY_TIME")
    #expect(time.value(forText: "320") == 320 && time.value(forText: " 320 ms ") == 320)
    #expect(time.value(forText: "99999") == time.maximum)
    #expect(time.value(forText: "fast") == nil && time.value(forText: "") == nil)
    let knob = try parameter("Status", "PRM_KNOB_POS_BOOST")
    #expect(knob.value(forText: "off") == -1 && knob.value(forText: "30") == 30)
    let lowCut = try parameter("Patch_0", "PRM_EQ_LOW_CUT")
    #expect(lowCut.displayText(for: lowCut.value(forText: "flat") ?? -1) == "FLAT")
    #expect(lowCut.displayText(for: lowCut.value(forText: "100") ?? -1) == "100 Hz")
    let highCut = try parameter("Patch_0", "PRM_EQ_HIGH_CUT")
    #expect(highCut.displayText(for: highCut.value(forText: "1.25k") ?? -1) == "1.25 kHz")
    #expect(highCut.displayText(for: highCut.value(forText: "1300") ?? -1) == "1.25 kHz")
}
