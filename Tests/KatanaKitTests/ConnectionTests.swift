import Synchronization
import Testing

@testable import KatanaKit

/// MIDI ports that a test plugs in and pulls out, with a fresh simulated amp behind them each time.
private final class FakePorts: AmpPorts {
    let changes: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let state = Mutex<(present: Bool, answers: Bool, amp: SimulatedAmp?)>((false, true, nil))
    private let map: ParameterMap

    init(map: ParameterMap) {
        self.map = map
        (changes, continuation) = AsyncStream.makeStream(of: Void.self)
    }

    var isPresent: Bool { state.withLock { $0.present } }

    func open() throws -> (any MIDITransport)? {
        state.withLock { state in
            guard state.present else { return nil }
            let amp = SimulatedAmp(map: map)
            amp.setAnswersReads(state.answers)
            state.amp = amp
            return amp
        }
    }

    func plug(answering: Bool = true) {
        state.withLock { $0 = (true, answering, nil) }
        continuation.yield()
    }

    func unplug() {
        state.withLock { $0.present = false }
        continuation.yield()
    }

    func startAnswering() {
        state.withLock { state in
            state.answers = true
            state.amp?.setAnswersReads(true)
        }
    }
}

@MainActor
private func eventually(_ condition: () -> Bool) async throws -> Bool {
    for _ in 0..<300 {
        if condition() { return true }
        try await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

private let quick = SessionTiming(spacing: .milliseconds(1), readTimeout: .milliseconds(50))

@MainActor
@Test func theModelFollowsTheAmpComingAndGoing() async throws {
    let ports = FakePorts(map: try ParameterMap.bundled())
    let model = EditorModel(map: try ParameterMap.bundled())
    let following = Task { await model.follow(ports, timing: quick, retryDelay: .milliseconds(20)) }
    defer { following.cancel() }
    #expect(model.connection == .notConnected)
    ports.plug()
    #expect(try await eventually { model.connection == .connected })
    ports.unplug()
    #expect(try await eventually { model.connection == .notConnected })
    ports.plug()
    #expect(try await eventually { model.connection == .connected && model.liveName == "SIM LIVE" })
}

@MainActor
@Test func anAmpThatDoesNotAnswerYetIsTriedAgain() async throws {
    let ports = FakePorts(map: try ParameterMap.bundled())
    let model = EditorModel(map: try ParameterMap.bundled())
    let following = Task { await model.follow(ports, timing: quick, retryDelay: .milliseconds(20)) }
    defer { following.cancel() }
    ports.plug(answering: false)
    #expect(try await eventually { if case .failed = model.connection { true } else { false } })
    ports.startAnswering()
    #expect(try await eventually { model.connection == .connected })
}

/// The last editor-mode flag that `amp` received: 1 on, 0 off, `nil` if none.
private func editorMode(of amp: SimulatedAmp) -> UInt8? {
    let on = SysEx.dt1(.editorCommunicationMode, data: [1], deviceID: 0)
    let off = SysEx.dt1(.editorCommunicationMode, data: [0], deviceID: 0)
    return amp.received.last { $0.message == on || $0.message == off }.map { $0.message == on ? 1 : 0 }
}

@MainActor
@Test func connectsDoNotOverlap() async throws {
    let map = try ParameterMap.bundled()
    let first = SimulatedAmp(map: map)
    let second = SimulatedAmp(map: map)
    second.setMemory(Array("SECOND".padding(toLength: 16, withPad: " ", startingAt: 0).utf8), at: .temporaryPatch)
    let model = EditorModel(map: map)
    async let one: Void = model.connect(first, timing: quick)
    async let two: Void = model.connect(second, timing: quick)
    _ = await (one, two)
    // One amp ends connected, in editor mode and shown; the other was let go of.
    #expect(model.connection == .connected)
    let modes = [editorMode(of: first), editorMode(of: second)]
    #expect(modes.filter { $0 == 1 }.count == 1)
    #expect(model.liveName == (modes[1] == 1 ? "SECOND" : "SIM LIVE"))
}

@MainActor
@Test func aDisconnectDuringAConnectWins() async throws {
    let map = try ParameterMap.bundled()
    for wait in [0, 5, 20] {
        let amp = SimulatedAmp(map: map)
        let model = EditorModel(map: map)
        async let connecting: Void = model.connect(amp, timing: quick)
        try await Task.sleep(for: .milliseconds(wait))
        await model.disconnect()
        await connecting
        #expect(model.connection == .notConnected, "after \(wait) ms")
        #expect(editorMode(of: amp) != 1, "after \(wait) ms")
    }
}

@MainActor
@Test func aPanicReachesAConnectStillWaitingForItsTurn() async throws {
    let map = try ParameterMap.bundled()
    let volume = try #require(map.parameter(block: "Status", prm: "PRM_KNOB_POS_VOLUME"))
    let first = SimulatedAmp(map: map)
    let second = SimulatedAmp(map: map)
    second.setMemory([88], at: .temporaryPatch.advanced(by: volume.offset))
    let model = EditorModel(map: map)
    async let one: Void = model.connect(first, timing: quick)
    async let two: Void = model.connect(second, timing: quick)
    // The first connect is running; the second waits for its turn.
    try await Task.sleep(for: .milliseconds(2))
    await model.panic()
    _ = await (one, two)
    #expect(second.memory(at: .temporaryPatch.advanced(by: volume.offset), count: 1) == [0])
}
