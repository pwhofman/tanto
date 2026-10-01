import Testing

@testable import KatanaKit

@Test func oneByteValues() {
    #expect(ValueEncoding.int1x7.encode(100) == [100])
    #expect(ValueEncoding.int1x7.decode([100]) == 100)
}

@Test func twoByteValuesAreBigEndian() {
    #expect(ValueEncoding.int2x7.encode(400) == [0x03, 0x10])
    #expect(ValueEncoding.int2x7.decode([0x03, 0x10]) == 400)
}

@Test func patchNamesLoseTrailingSpaces() {
    #expect(PatchName.decode(Array("KATANA Mk2      ".utf8)) == "KATANA Mk2")
}
