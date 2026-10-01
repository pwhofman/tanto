import Testing

@testable import KatanaKit

// The reply of the user's Katana-100 MkII, recorded in hardware check 1: device ID 00, model code 06.
private let realIdentityReply: [UInt8] = [
    0xF0, 0x7E, 0x00, 0x06, 0x02, 0x41, 0x33, 0x03, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00, 0xF7,
]

@Test func editorModeMessagesMatchKnownBytes() {
    #expect(
        SysEx.dt1(.editorCommunicationMode, data: [1]) == [
            0xF0, 0x41, 0x10, 0x00, 0x00, 0x00, 0x33, 0x12, 0x7F, 0x00, 0x00, 0x01, 0x01, 0x7F, 0xF7,
        ])
    #expect(
        SysEx.dt1(.editorCommunicationMode, data: [0]) == [
            0xF0, 0x41, 0x10, 0x00, 0x00, 0x00, 0x33, 0x12, 0x7F, 0x00, 0x00, 0x01, 0x00, 0x00, 0xF7,
        ])
}

@Test func rq1ForTheLivePatchName() {
    #expect(
        SysEx.rq1(.temporaryPatch, size: 16) == [
            0xF0, 0x41, 0x10, 0x00, 0x00, 0x00, 0x33, 0x11, 0x60, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x10, 0xF7,
        ])
}

@Test func messagesCarryTheGivenDeviceID() {
    #expect(SysEx.rq1(.temporaryPatch, size: 16, deviceID: 0x00)[2] == 0x00)
    #expect(SysEx.dt1(.editorCommunicationMode, data: [1], deviceID: 0x00)[2] == 0x00)
}

@Test func parsesDataSetFromAnyDeviceID() {
    let address = Address(packed: 0x6000_0028)
    #expect(IncomingMessage(SysEx.dt1(address, data: [42])) == .dataSet(address, [42]))
    #expect(IncomingMessage(SysEx.dt1(address, data: [42], deviceID: 0x00)) == .dataSet(address, [42]))
}

@Test func wrongChecksumIsMalformed() {
    var message = SysEx.dt1(.temporaryPatch, data: [1, 2, 3])
    message[message.count - 2] ^= 0x01
    #expect(IncomingMessage(message) == .malformed(message))
}

@Test func recognizesTheKatanaIdentityReply() {
    #expect(IncomingMessage(realIdentityReply) == .identityReply(realIdentityReply))
    #expect(SysEx.isKatanaIdentityReply(realIdentityReply))
    var otherFamily = realIdentityReply
    otherFamily[6] = 0x34
    #expect(!SysEx.isKatanaIdentityReply(otherFamily))
    var otherModel = realIdentityReply
    otherModel[10] = 0x01  // not a Katana MkII model code (05–0B)
    #expect(!SysEx.isKatanaIdentityReply(otherModel))
}

@Test func otherMessagesAreOther() {
    #expect(IncomingMessage([0xF0, 0x43, 0x10, 0xF7]) == .other([0xF0, 0x43, 0x10, 0xF7]))
    #expect(IncomingMessage(SysEx.identityRequest) == .other(SysEx.identityRequest))
}
