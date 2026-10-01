import Testing

@testable import KatanaKit

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

@Test func parsesDataSet() {
    let message = SysEx.dt1(Address(packed: 0x6000_0028), data: [42])
    #expect(IncomingMessage(message) == .dataSet(Address(packed: 0x6000_0028), [42]))
}

@Test func wrongChecksumIsMalformed() {
    var message = SysEx.dt1(.temporaryPatch, data: [1, 2, 3])
    message[message.count - 2] ^= 0x01
    #expect(IncomingMessage(message) == .malformed(message))
}

@Test func recognizesTheKatanaIdentityReply() {
    let reply: [UInt8] = [0xF0, 0x7E, 0x10, 0x06, 0x02, 0x41, 0x33, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF7]
    #expect(IncomingMessage(reply) == .identityReply(reply))
    #expect(SysEx.isKatanaIdentityReply(reply))
    var other = reply
    other[6] = 0x34
    #expect(!SysEx.isKatanaIdentityReply(other))
}

@Test func otherMessagesAreOther() {
    #expect(IncomingMessage([0xF0, 0x43, 0x10, 0xF7]) == .other([0xF0, 0x43, 0x10, 0xF7]))
    #expect(IncomingMessage(SysEx.identityRequest) == .other(SysEx.identityRequest))
}
