import Testing

@testable import KatanaKit

@Test func picksTheMainPortNotTheDAWControlPort() throws {
    let ports = [MIDIEndpoint(name: "KATANA KATANA DAW CTRL", ref: 2), MIDIEndpoint(name: "KATANA", ref: 1)]
    #expect(try CoreMIDITransport.mainPort(in: ports) == MIDIEndpoint(name: "KATANA", ref: 1))
}

@Test func refusesWhenTheMainPortIsMissing() {
    #expect(throws: CoreMIDIError.katanaNotFound) {
        try CoreMIDITransport.mainPort(in: [MIDIEndpoint(name: "KATANA KATANA DAW CTRL", ref: 2)])
    }
}

@Test func refusesToGuessBetweenTwoMainPorts() {
    let ports = [MIDIEndpoint(name: "KATANA", ref: 1), MIDIEndpoint(name: "katana", ref: 3)]
    #expect(throws: CoreMIDIError.ambiguous(["KATANA", "katana"])) {
        try CoreMIDITransport.mainPort(in: ports)
    }
}

@Test func twoMainPortsCountAsPresentSoThatConnectingReportsTheAmbiguity() {
    #expect(
        CoreMIDITransport.hasMainPort(in: [MIDIEndpoint(name: "KATANA", ref: 1), MIDIEndpoint(name: "katana", ref: 3)]))
    #expect(!CoreMIDITransport.hasMainPort(in: [MIDIEndpoint(name: "KATANA KATANA DAW CTRL", ref: 2)]))
}
