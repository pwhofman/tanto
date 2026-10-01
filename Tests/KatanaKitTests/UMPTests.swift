import Testing

@testable import KatanaKit

@Test(arguments: [0, 1, 5, 6, 7, 12, 13, 150])
func sysExSurvivesARoundTrip(length: Int) {
    let message: [UInt8] = [0xF0] + (0..<length).map { UInt8($0 % 128) } + [0xF7]
    var decoder = UMPDecoder()
    #expect(decoder.decode(UMP.sysEx7Packets(for: message).flatMap { $0 }) == [message])
}

@Test func messagesMaySpanSeveralPackets() {
    let message = SysEx.dt1(.temporaryPatch, data: Array(repeating: 7, count: 40))
    let packets = UMP.sysEx7Packets(for: message)
    var decoder = UMPDecoder()
    #expect(decoder.decode(packets[0] + packets[1]) == [])
    #expect(decoder.decode(packets.dropFirst(2).flatMap { $0 }) == [message])
}

@Test func channelMessagesAreDecoded() {
    var decoder = UMPDecoder()
    #expect(decoder.decode([0x20C0_0500]) == [[0xC0, 0x05]])  // Program Change 5 on channel 1
    #expect(decoder.decode([0x2090_3C64]) == [[0x90, 0x3C, 0x64]])  // Note On
}

@Test func otherMessageTypesAreSkippedBetweenSysExPackets() {
    let message = SysEx.dt1(.temporaryPatch, data: [1, 2, 3])
    var words = UMP.sysEx7Packets(for: message).flatMap { $0 }
    words.insert(0x10F8_0000, at: 2)  // System Real Time: timing clock, one word
    var decoder = UMPDecoder()
    #expect(decoder.decode(words) == [message])
}
