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
