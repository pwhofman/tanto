import Testing

@testable import KatanaKit

@Test func packedAndLinearFormsAgree() {
    let address = Address(packed: 0x6000_0028)
    #expect(address.linear == (0x60 << 21) + 0x28)
    #expect(address.bytes == [0x60, 0x00, 0x00, 0x28])
    #expect(address.description == "60 00 00 28")
    #expect(Address(bytes: [0x60, 0x00, 0x00, 0x28]) == address)
}

@Test func advancingCarriesAcrossSevenBitBytes() {
    #expect(Address(packed: 0x6000_007F).advanced(by: 1) == Address(packed: 0x6000_0100))
    #expect(Address.temporaryPatch.advanced(by: 737).description == "60 00 05 61")
}

@Test func wellKnownAddresses() {
    #expect(Address.currentPatchNumber.description == "00 01 00 00")
    #expect(Address.userPatch(0).description == "10 00 00 00")
    #expect(Address.userPatch(8).description == "10 08 00 00")
    #expect(Address.editorCommunicationMode.description == "7F 00 00 01")
}
