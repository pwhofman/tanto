import Foundation
import Synchronization
import Testing

@testable import KatanaKit

// Regression tests for the independent safety review of plan 2a; each test names its finding (plan 2c).

private struct TransportFailure: Error {}

private final class Recorder<T: Sendable>: Sendable {
    private let items = Mutex<[T]>([])

    func append(_ item: T) {
        items.withLock { $0.append(item) }
    }

    var all: [T] { items.withLock { $0 } }
}

/// A VOLUME write as it reached the amp, with the amp's VOLUME just before it.
private struct VolumeWrite: Sendable, CustomStringConvertible {
    let before: Int
    let written: Int
    let time: ContinuousClock.Instant

    var description: String { "\(before)→\(written)" }
}

/// A connected session with the live patch read, and a guard with the spec's defaults.
private struct ReviewRig {
    let map: ParameterMap
    let amp: SimulatedAmp
    let transport: HookTransport
    let session: AmpSession
    let safety: SafetyGuard
    let volume: Parameter

    init(
        volume start: Int, timing: SessionTiming = .katana,
        prepare: (SimulatedAmp, ParameterMap, Parameter) -> Void = { _, _, _ in }
    ) async throws {
        map = try ParameterMap.bundled()
        amp = SimulatedAmp(map: map)
        volume = try #require(map.parameter(block: "Status", prm: "PRM_KNOB_POS_VOLUME"))
        amp.setMemory([UInt8(start)], at: .temporaryPatch.advanced(by: volume.offset))
        prepare(amp, map, volume)
        transport = HookTransport(amp: amp)
        session = AmpSession(transport: transport, timing: timing)
        _ = try await session.connect()
        try await session.readLivePatch(map)
        safety = try SafetyGuard(session: session, map: map, rampDuration: .seconds(2))
    }

    var volumeAddress: Address { .temporaryPatch.advanced(by: volume.offset) }

    /// The VOLUME knob register in the simulated amp's memory.
    var ampVolume: Int { Int(amp.memory(at: volumeAddress, count: 1)[0]) }

    /// VOLUME in Tanto's copy of the live patch.
    var copiedVolume: Int? {
        get async { await session.liveValue(of: volume) }
    }

    func parameter(_ block: String, _ prm: String) throws -> Parameter {
        try #require(map.parameter(block: block, prm: prm))
    }

    /// VOLUME values Tanto wrote after message `start`.
    func volumeWrites(after start: Int = 0) -> [Int] {
        amp.received.dropFirst(start).compactMap { received in
            guard case .dataSet(let address, let data) = IncomingMessage(received.message), address == volumeAddress
            else { return nil }
            return Int(data[0])
        }
    }

    /// Records every VOLUME write as it reaches the amp, with the amp's VOLUME just before it.
    func recordVolumeWrites() -> Recorder<VolumeWrite> {
        let recorder = Recorder<VolumeWrite>()
        let amp = amp
        let address = volumeAddress
        transport.setHook { message in
            if case .dataSet(let target, let data) = IncomingMessage(message), target == address {
                let before = Int(amp.memory(at: address, count: 1)[0])
                recorder.append(VolumeWrite(before: before, written: Int(data[0]), time: .now))
            }
        }
        return recorder
    }

    /// Presses a channel button on the amp with the timing of hardware check 1: the amp loads the stored patch at
    /// once, sends the channel number after `channelDelay`, then the patch in eight DT1s 36 ms apart, the Status block
    /// in the fourth. With `liveDump` each message carries the amp's memory when it is sent, otherwise the stored patch.
    func switchChannel(to slot: Int, channelDelay: Duration, liveDump: Bool) async throws {
        let size = map.patchSize
        let stored = amp.memory(at: .userPatch(slot), count: size)
        amp.setMemory(stored, at: .temporaryPatch)
        amp.setMemory([0, UInt8(slot)], at: .currentPatchNumber)
        try await Task.sleep(for: channelDelay)
        amp.sendFromAmp(SysEx.dt1(.currentPatchNumber, data: [0, UInt8(slot)], deviceID: amp.deviceID))
        for start in stride(from: 0, to: size, by: 241) {
            try await Task.sleep(for: .milliseconds(36))
            let count = min(241, size - start)
            let data =
                liveDump
                ? amp.memory(at: .temporaryPatch.advanced(by: start), count: count)
                : Array(stored[start..<(start + count)])
            amp.sendFromAmp(SysEx.dt1(.temporaryPatch.advanced(by: start), data: data, deviceID: amp.deviceID))
        }
    }
}

private func storeVolume(_ value: UInt8, in slot: Int) -> (SimulatedAmp, ParameterMap, Parameter) -> Void {
    { amp, _, volume in amp.setMemory([value], at: Address.userPatch(slot).advanced(by: volume.offset)) }
}

// MARK: - C1: channel changes made on the amp

// A ramp runs while a channel with VOLUME 5 is selected on the amp. One step may still land on the new channel; the
// guard stops at the channel message and puts the channel's own value back.
@Test(arguments: [(Duration.zero, false), (.milliseconds(20), false), (.milliseconds(20), true)])
func c1_aChannelChangeOnTheAmpEndsTheRampAndUndoesAStepThatLanded(channelDelay: Duration, liveDump: Bool)
    async throws
{
    let rig = try await ReviewRig(volume: 10, prepare: storeVolume(5, in: 6))
    let writes = rig.recordVolumeWrites()
    try await rig.safety.set(rig.volume, to: 50)
    try await Task.sleep(for: .milliseconds(200))
    let load = ContinuousClock.now
    try await rig.switchChannel(to: 6, channelDelay: channelDelay, liveDump: liveDump)
    await rig.safety.settle()
    let raising = writes.all.filter { $0.time > load && $0.written > $0.before }
    #expect(raising.count <= 1, "writes that raised the new channel: \(raising)")
    #expect(rig.ampVolume == 5)
    #expect(await rig.copiedVolume == 5)
}

// The VOLUME dip of a soft switch has gone out when a loud channel is selected on the amp: the switch change must not
// follow on the new channel.
@Test func c1_aSwitchChangeIsDroppedWhenTheAmpChangesChannels() async throws {
    let rig = try await ReviewRig(volume: 30, prepare: storeVolume(88, in: 6))
    let booster = try rig.parameter("Patch_0", "PRM_ODDS_SW")
    let boosterAddress = Address.temporaryPatch.advanced(by: booster.offset)
    let boosterWrites = Recorder<Int>()
    let amp = rig.amp
    let volumeAddress = rig.volumeAddress
    rig.transport.setHook { message in
        if case .dataSet(let target, _) = IncomingMessage(message), target == boosterAddress {
            boosterWrites.append(Int(amp.memory(at: volumeAddress, count: 1)[0]))
        }
    }
    let start = rig.amp.received.count
    try await rig.safety.set(booster, to: 1)
    while !rig.volumeWrites(after: start).contains(0) {
        try await Task.sleep(for: .milliseconds(1))
    }
    try await rig.switchChannel(to: 6, channelDelay: .zero, liveDump: false)
    await rig.safety.settle()
    #expect(boosterWrites.all.isEmpty, "booster switched while VOLUME was \(boosterWrites.all)")
    #expect(rig.ampVolume == 88)
}

@Test func c1_requestsWaitForTheNewChannelsPatch() async throws {
    let rig = try await ReviewRig(volume: 10)
    rig.amp.sendFromAmp(SysEx.dt1(.currentPatchNumber, data: [0, 6], deviceID: rig.amp.deviceID))
    while await rig.session.currentChannel != 6 {
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(await !rig.session.isLivePatchValid)
    await #expect(throws: SafetyError.notReady) { try await rig.safety.set(rig.volume, to: 5) }
    let patch = rig.amp.memory(at: .temporaryPatch, count: rig.map.patchSize)
    for start in stride(from: 0, to: patch.count, by: 241) {
        let data = Array(patch[start..<min(start + 241, patch.count)])
        rig.amp.sendFromAmp(SysEx.dt1(.temporaryPatch.advanced(by: start), data: data, deviceID: rig.amp.deviceID))
    }
    while await !rig.session.isLivePatchValid {
        try await Task.sleep(for: .milliseconds(1))
    }
    try await rig.safety.set(rig.volume, to: 5)
}

// MARK: - C2: requests judged against a copy above the amp

// The knob is turned up to 48 just as a ramp step lands, so the copy says 48 while the amp holds the step. Asking for
// 45 is then a rise, not a decrease.
@Test func c2_aCrossedKnobTurnDoesNotTurnARiseIntoAJump() async throws {
    let rig = try await ReviewRig(volume: 10)
    try await rig.safety.set(rig.volume, to: 45)
    try await Task.sleep(for: .milliseconds(150))
    rig.amp.turnKnobWhenNextWritten([48], at: rig.volumeAddress)
    while await rig.copiedVolume != 48 {
        try await Task.sleep(for: .milliseconds(1))
    }
    let writes = rig.recordVolumeWrites()
    try await rig.safety.set(rig.volume, to: 45)
    await rig.safety.settle()
    #expect(writes.all.allSatisfy { $0.written <= $0.before + 1 }, "VOLUME jumped: \(writes.all)")
}

// A loud channel (VOLUME 88) is selected during a ramp; then the user lowers VOLUME to 70 or 40.
@Test(arguments: [70, 40])
func c2_loweringAfterAChannelChangeNeverRaisesTheAmp(request: Int) async throws {
    let rig = try await ReviewRig(volume: 10, prepare: storeVolume(88, in: 6))
    try await rig.safety.set(rig.volume, to: 50)
    try await Task.sleep(for: .milliseconds(200))
    try await rig.switchChannel(to: 6, channelDelay: .milliseconds(20), liveDump: false)
    await rig.safety.settle()
    let writes = rig.recordVolumeWrites()
    do {
        try await rig.safety.set(rig.volume, to: request)
    } catch SafetyError.aboveCeiling {
        // Allowed: the amp may hold a step below the ceiling while the copy said 88.
    }
    await rig.safety.settle()
    for write in writes.all {
        #expect(write.written <= write.before || write.written == write.before + 1, "VOLUME jumped: \(write)")
        #expect(write.written <= 50 || write.written <= write.before, "VOLUME rose above the ceiling: \(write)")
    }
}

// MARK: - C3: a read of the live patch never undoes a newer write

@Test func c3_aReReadDoesNotUndoPanic() async throws {
    let rig = try await ReviewRig(volume: 88)
    let start = rig.amp.received.count
    let reread = Task { try await rig.session.readLivePatch(rig.map) }
    // Panic just after the re-read has asked for the Status block.
    let statusRead = SysEx.rq1(.temporaryPatch.advanced(by: 848), size: 18, deviceID: 0)
    while !rig.amp.received.dropFirst(start).contains(where: { $0.message == statusRead }) {
        try await Task.sleep(for: .milliseconds(1))
    }
    await rig.safety.panic()
    try await reread.value
    #expect(rig.ampVolume == 0)
    #expect(await rig.copiedVolume == 0)
    let writes = rig.recordVolumeWrites()
    await #expect(throws: SafetyError.aboveCeiling("PRM_KNOB_POS_VOLUME", value: 70, ceiling: 50)) {
        try await rig.safety.set(rig.volume, to: 70)
    }
    await rig.safety.settle()
    #expect(writes.all.isEmpty)
}

@Test func c3_aLateReplyIsAReadNotAChangeOnTheAmp() async throws {
    let rig = try await ReviewRig(
        volume: 10, timing: SessionTiming(spacing: .milliseconds(20), readTimeout: .milliseconds(50)))
    rig.amp.setAnswersReads(false)
    await #expect(throws: AmpError.timeout(rig.volumeAddress)) {
        _ = try await rig.session.read(rig.volumeAddress, size: 1)
    }
    rig.amp.sendFromAmp(SysEx.dt1(rig.volumeAddress, data: [10], deviceID: rig.amp.deviceID))
    try await Task.sleep(for: .milliseconds(20))
    #expect(await rig.session.ampReports(for: rig.volume).count == 0)
}

// A read of VOLUME goes out, then Panic; the amp's reply describes VOLUME before Panic and must not bring it back.
@Test func c3_aReplyToAReadSentBeforePanicDoesNotUndoIt() async throws {
    let rig = try await ReviewRig(volume: 30)
    rig.amp.setAnswersReads(false)
    let refresh = Task { try await rig.session.refresh(rig.volume) }
    let read = SysEx.rq1(rig.volumeAddress, size: 1, deviceID: 0)
    while !rig.amp.received.contains(where: { $0.message == read }) {
        try await Task.sleep(for: .milliseconds(1))
    }
    await rig.safety.panic()
    rig.amp.sendFromAmp(SysEx.dt1(rig.volumeAddress, data: [30], deviceID: rig.amp.deviceID))
    _ = try await refresh.value
    #expect(rig.ampVolume == 0)
    #expect(await rig.copiedVolume == 0)
}

// MARK: - C4: a correction follows the knob

// The knob is turned down to 0 just as a ramp step lands; the amp holds the step until the guard reads it back and
// writes the knob's 0.
@Test func c4_aStepThatCrossedTheKnobIsSetBackToTheKnob() async throws {
    let rig = try await ReviewRig(volume: 10)
    try await rig.safety.set(rig.volume, to: 45)
    try await Task.sleep(for: .milliseconds(150))
    rig.amp.turnKnobWhenNextWritten([0], at: rig.volumeAddress)
    await rig.safety.settle()
    #expect(rig.ampVolume == 0)
    #expect(await rig.copiedVolume == 0)
    #expect(rig.volumeWrites().last == 0)
}

// As above, but the knob moves on to 0 just before the guard's correction to 12 lands, so the correction itself is
// crossed; the guard corrects again.
@Test func c4_aCrossedCorrectionIsCorrectedAgain() async throws {
    let rig = try await ReviewRig(volume: 10)
    try await rig.safety.set(rig.volume, to: 45)
    try await Task.sleep(for: .milliseconds(150))
    let amp = rig.amp
    let address = rig.volumeAddress
    rig.transport.setHook { message in
        if case .dataSet(let target, let data) = IncomingMessage(message), target == address, data == [12] {
            amp.changeOnAmp([0], at: address)
        }
    }
    rig.amp.turnKnobWhenNextWritten([12], at: rig.volumeAddress)
    await rig.safety.settle()
    #expect(rig.ampVolume == 0)
    #expect(await rig.copiedVolume == 0)
}

// MARK: - M1: requests that Panic overtook

@Test func m1_aRequestInFlightWhenPanicComesDoesNotRampAfterIt() async throws {
    let rig = try await ReviewRig(volume: 10)
    // Keep the session busy inside one send for 100 ms, so that the request and Panic interleave the same way each time.
    let marker = SysEx.rq1(.userPatch(3), size: 16, deviceID: 0)
    rig.transport.setHook { message in
        if message == marker { Thread.sleep(forTimeInterval: 0.1) }
    }
    let read = Task { try await rig.session.read(.userPatch(3), size: 16) }
    try await Task.sleep(for: .milliseconds(20))
    let request = Task { try await rig.safety.set(rig.volume, to: 40) }
    try await Task.sleep(for: .milliseconds(20))
    await rig.safety.panic()
    _ = try await read.value
    do {
        try await request.value
    } catch SafetyError.overtakenByPanic {
        // The expected outcome when the request was still being decided.
    }
    await rig.safety.settle()
    #expect(rig.ampVolume == 0)
}

// The window's pattern: a slider task, then the Esc task, both from the main actor.
@MainActor
@Test(arguments: 0..<10)
func m1_aSliderTaskThenPanicLeavesVolumeAtZero(run: Int) async throws {
    let map = try ParameterMap.bundled()
    let amp = SimulatedAmp(map: map)
    let volume = try #require(map.parameter(block: "Status", prm: "PRM_KNOB_POS_VOLUME"))
    amp.setMemory([10], at: .temporaryPatch.advanced(by: volume.offset))
    let model = EditorModel(map: map)
    await model.connect(amp)
    let slider = Task { await model.set(volume, to: 40) }
    let escape = Task { await model.panic() }
    await slider.value
    await escape.value
    await model.settle()
    #expect(amp.memory(at: .temporaryPatch.advanced(by: volume.offset), count: 1) == [0])
}

// MARK: - M2: Panic does not wait

@Test(arguments: [Duration.milliseconds(500), .seconds(3)])
func m2_panicDoesNotWaitForAnUnansweredRead(readTimeout: Duration) async throws {
    let rig = try await ReviewRig(
        volume: 10, timing: SessionTiming(spacing: .milliseconds(20), readTimeout: readTimeout))
    try await rig.safety.set(rig.volume, to: 45)
    try await Task.sleep(for: .milliseconds(100))
    rig.amp.setAnswersReads(false)
    let read = Task { try await rig.session.read(.userPatch(2), size: 16) }
    try await Task.sleep(for: .milliseconds(30))
    let atPanic = rig.amp.received.count
    let panicTime = ContinuousClock.now
    await rig.safety.panic()
    let after = Array(rig.amp.received.dropFirst(atPanic))
    let zero = try #require(
        after.firstIndex { received in
            if case .dataSet(let address, let data) = IncomingMessage(received.message) {
                return address == rig.volumeAddress && data == [0]
            }
            return false
        })
    #expect(after[zero].time - panicTime < .milliseconds(60))
    #expect(zero <= 1, "messages before VOLUME 0: \(zero)")
    read.cancel()
    await rig.safety.settle()
}

// Four writes wait in the session when Panic comes; VOLUME 0 passes all but the one already on its way.
@Test func m2_panicGoesAheadOfEverythingQueuedInTheSession() async throws {
    let rig = try await ReviewRig(volume: 10)
    let bass = try rig.parameter("Status", "PRM_KNOB_POS_BASS")
    let start = rig.amp.received.count
    let queued = (1...4).map { value in Task { try await rig.session.write(value, to: bass) } }
    try await Task.sleep(for: .milliseconds(5))
    await rig.safety.panic()
    for task in queued {
        _ = try await task.value
    }
    let offsets = rig.amp.received.dropFirst(start).compactMap { received -> Int? in
        guard case .dataSet(let address, _) = IncomingMessage(received.message) else { return nil }
        return address.linear - Address.temporaryPatch.linear
    }
    #expect(offsets.prefix(2).contains(rig.volume.offset), "order: \(offsets)")
}

// MARK: - M3: a switch right after Panic

@Test func m3_aSwitchRightAfterPanicKeepsVolumeAtZero() async throws {
    let rig = try await ReviewRig(volume: 10)
    try await rig.safety.set(rig.volume, to: 40)
    try await Task.sleep(for: .milliseconds(200))
    async let panic: Void = rig.safety.panic()
    do {
        try await rig.safety.set(rig.parameter("Patch_0", "PRM_ODDS_SW"), to: 1)
    } catch SafetyError.overtakenByPanic {
        // Also fine: the switch began before Panic.
    }
    await panic
    await rig.safety.settle()
    #expect(rig.ampVolume == 0)
}

// MARK: - M4: the model's guard and Panic while connecting

@MainActor
@Test func m4_panicWhileConnectingIsSent() async throws {
    let map = try ParameterMap.bundled()
    let amp = SimulatedAmp(map: map)
    let volume = try #require(map.parameter(block: "Status", prm: "PRM_KNOB_POS_VOLUME"))
    amp.setMemory([88], at: .temporaryPatch.advanced(by: volume.offset))
    let model = EditorModel(map: map)
    let connecting = Task { await model.connect(amp) }
    try await Task.sleep(for: .milliseconds(5))
    #expect(model.connection == .connecting)
    await model.panic()
    await connecting.value
    #expect(amp.memory(at: .temporaryPatch.advanced(by: volume.offset), count: 1) == [0])
    #expect(model.value(of: volume) == 0)
}

@MainActor
@Test func m4_theOldGuardStopsWhenTheModelReconnects() async throws {
    let map = try ParameterMap.bundled()
    let volume = try #require(map.parameter(block: "Status", prm: "PRM_KNOB_POS_VOLUME"))
    let oldPort = SimulatedAmp(map: map)
    oldPort.setMemory([5], at: .temporaryPatch.advanced(by: volume.offset))
    let newPort = SimulatedAmp(map: map)
    let model = EditorModel(map: map)
    await model.connect(oldPort)
    await model.set(volume, to: 45)
    try await Task.sleep(for: .milliseconds(60))
    await model.connect(newPort)
    let atReconnect = oldPort.received.count
    try await Task.sleep(for: .milliseconds(300))
    let later = oldPort.received.dropFirst(atReconnect).filter {
        if case .dataSet(let address, _) = IncomingMessage($0.message) {
            return address == Address.temporaryPatch.advanced(by: volume.offset)
        }
        return false
    }
    #expect(later.isEmpty)
}

// MARK: - M5: a request during a soft switch

// A switch click followed at once by VOLUME 5: the user's last word is 5.
@Test(arguments: 0..<10)
func m5_aLowerVolumeRequestDuringASoftSwitchWins(run: Int) async throws {
    let rig = try await ReviewRig(volume: 30)
    let booster = try rig.parameter("Patch_0", "PRM_ODDS_SW")
    async let switching: Void = rig.safety.set(booster, to: 1)
    async let lowering: Void = rig.safety.set(rig.volume, to: 5)
    try await switching
    try await lowering
    await rig.safety.settle()
    #expect(rig.ampVolume <= 5)
}

// MARK: - m1: a failed dip

@Test func m1_aFailedDipLeavesNoRestoreBehind() async throws {
    let rig = try await ReviewRig(volume: 30)
    let address = rig.volumeAddress
    let failures = Recorder<Int>()
    rig.transport.setHook { message in
        if case .dataSet(let target, let data) = IncomingMessage(message), target == address, data == [0],
            failures.all.isEmpty
        {
            failures.append(1)
            throw TransportFailure()
        }
    }
    try await rig.safety.set(rig.parameter("Patch_0", "PRM_ODDS_SW"), to: 1)
    await rig.safety.settle()
    // The user turns VOLUME down to 5 on the amp, then switches the booster again.
    rig.amp.changeOnAmp([5], at: address)
    while await rig.copiedVolume != 5 {
        try await Task.sleep(for: .milliseconds(1))
    }
    try await rig.safety.set(rig.parameter("Patch_0", "PRM_ODDS_SW"), to: 1)
    await rig.safety.settle()
    #expect(rig.ampVolume <= 5)
}

// MARK: - m3, m4, m7

@Test func m3_connectingStartsFromAnEmptyCopy() async throws {
    let rig = try await ReviewRig(volume: 10)
    _ = try await rig.session.connect()
    #expect(await rig.copiedVolume == nil)
    #expect(await !rig.session.isLivePatchValid)
}

@Test func m4_theGuardChecksItsTableAndTiming() async throws {
    let map = try ParameterMap.bundled()
    let amp = SimulatedAmp(map: map)
    let fast = AmpSession(transport: amp, timing: SessionTiming(spacing: .milliseconds(1), readTimeout: .seconds(1)))
    #expect(throws: SafetyError.invalidTiming) { try SafetyGuard(session: fast, map: map) }
    let table = map.table
    let unguarded = ParameterTable(
        source: table.source, blocks: table.blocks,
        parameters: table.parameters.filter { $0.prm != "PRM_KNOB_POS_VOLUME" })
    #expect(throws: SafetyError.invalidTable("no guarded VOLUME knob")) {
        try SafetyGuard(session: AmpSession(transport: amp), map: ParameterMap(unguarded))
    }
}

@Test func m7_aReportOfOneByteOfATwoByteValueCounts() async throws {
    let rig = try await ReviewRig(volume: 10)
    let time = try rig.parameter("Delay(1)", "PRM_DLY_COMMON_DLY_TIME")
    #expect(time.encoding == .int2x7)
    rig.amp.changeOnAmp([3], at: Address.temporaryPatch.advanced(by: time.offset + 1))
    while await rig.session.ampReports(for: time).count == 0 {
        try await Task.sleep(for: .milliseconds(1))
    }
}

// MARK: - Checked and found correct by the review

@Test func theCeilingStopsARampWhenLoweredAndEffectKnobsStartFromOff() async throws {
    let rig = try await ReviewRig(volume: 10)
    try await rig.safety.set(rig.volume, to: 50)
    try await Task.sleep(for: .milliseconds(150))
    try await rig.safety.setCeilingPercent(20)
    await rig.safety.settle()
    #expect(rig.ampVolume == 20)
    try await rig.safety.setCeilingPercent(50)
    try await Task.sleep(for: .milliseconds(100))
    #expect(rig.ampVolume == 20)
    let boost = try rig.parameter("Status", "PRM_KNOB_POS_BOOST")
    try await rig.safety.setCeilingPercent(0)
    await #expect(throws: SafetyError.self) { try await rig.safety.set(boost, to: 0) }
    try await rig.safety.setCeilingPercent(50)
    #expect(await rig.safety.ceiling(of: boost) == 49)
    for parameter in rig.map.table.parameters where parameter.guarded {
        for percent in stride(from: 0, through: 100, by: 5) {
            let exact = Double(parameter.minimum) + Double(percent * (parameter.maximum - parameter.minimum)) / 100
            #expect(Ceiling.value(of: parameter, percent: percent) == Int(exact.rounded(.down)))
        }
    }
}
