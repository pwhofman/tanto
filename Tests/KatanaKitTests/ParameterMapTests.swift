import Testing

@testable import KatanaKit

@Test func bundledTableMatchesToneStudio() throws {
    let map = try ParameterMap.bundled()
    #expect(map.table.blocks.count == 31)
    #expect(map.table.parameters.count == 1465)
    #expect(map.patchSize == 1986)
}

@Test func guardedParametersMatchTheSpec() throws {
    let map = try ParameterMap.bundled()
    let editable = Set(map.table.blocks.filter(\.editable).map(\.name))
    let guarded = map.table.parameters.filter(\.guarded)
    #expect(guarded.count == 210)
    #expect(guarded.allSatisfy { editable.contains($0.block) })
}

@Test func panicParametersSitWhereTheSpecSays() throws {
    let map = try ParameterMap.bundled()
    let volume = try #require(map.parameter(block: "Patch_0", prm: "PRM_PREAMP_A_LEVEL"))
    let footVolume = try #require(map.parameter(block: "Patch_1", prm: "PRM_FOOT_VOLUME_VOL_LEVEL"))
    #expect(Address.temporaryPatch.advanced(by: volume.offset).description == "60 00 00 28")
    #expect(Address.temporaryPatch.advanced(by: footVolume.offset).description == "60 00 05 61")
    #expect(volume.guarded && footVolume.guarded)
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
