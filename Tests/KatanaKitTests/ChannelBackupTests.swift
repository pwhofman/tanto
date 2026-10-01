import Foundation
import Testing

@testable import KatanaKit

private func backup() throws -> (ChannelBackup, [Int: [UInt8]], ParameterMap) {
    let map = try ParameterMap.bundled()
    let amp = SimulatedAmp(map: map)
    var patches: [Int: [UInt8]] = [:]
    for slot in 1...8 {
        patches[slot] = amp.memory(at: .userPatch(slot), count: map.patchSize)
    }
    let created = Date(timeIntervalSince1970: 1_790_000_000)
    return (ChannelBackup(patches: patches, map: map, created: created), patches, map)
}

/// The backup as JSON, changed by `change` before it is loaded again.
private func load(_ change: (inout [String: Any]) -> Void) throws -> Result<ChannelBackup, any Error> {
    let (backup, _, map) = try backup()
    var object = try #require(try JSONSerialization.jsonObject(with: backup.encoded()) as? [String: Any])
    change(&object)
    let data = try JSONSerialization.data(withJSONObject: object)
    return Result { try ChannelBackup.load(data, map: map) }
}

/// Changes channel `index` of the JSON object.
private func changeChannel(_ index: Int, in object: inout [String: Any], _ change: (inout [String: Any]) -> Void) {
    var channels = object["channels"] as? [[String: Any]] ?? []
    change(&channels[index])
    object["channels"] = channels
}

private func changeBlock(_ name: String, of index: Int, in object: inout [String: Any], to hex: String?) {
    changeChannel(index, in: &object) { channel in
        var blocks = channel["blocks"] as? [String: String] ?? [:]
        blocks[name] = hex
        channel["blocks"] = blocks
    }
}

private func error(_ result: Result<ChannelBackup, any Error>) -> BackupError? {
    if case .failure(let error) = result { error as? BackupError } else { nil }
}

@Test func aBackupSurvivesItsFile() throws {
    let (backup, patches, map) = try backup()
    #expect(backup.format == 1 && backup.model == "KATANA MkII")
    #expect(backup.channels.map(\.slot) == Array(1...8))
    #expect(backup.channels[1].name == "SIM PATCH 2")
    #expect(backup.channels[0].blocks["Patch_0"]?.count == 2 * 72)
    let loaded = try ChannelBackup.load(backup.encoded(), map: map)
    #expect(loaded == backup)
    for slot in 1...8 {
        let patch = try #require(patches[slot])
        let restored = loaded.patch(of: slot, map: map)
        for block in map.table.blocks {
            let range = block.offset..<(block.offset + block.size)
            #expect(restored[range] == patch[range])
        }
    }
    let json = try #require(String(data: backup.encoded(), encoding: .utf8))
    #expect(json.contains("2026-09-21T14:13:20Z"))
}

@Test func aFileIsCheckedBeforeAnythingIsWritten() throws {
    #expect(error(try load { $0["format"] = 2 }) == .unknownFormat(2))
    #expect(error(try load { $0["model"] = "KATANA" }) == .otherModel("KATANA"))
    #expect(
        error(try load { $0["channels"] = Array(($0["channels"] as? [Any] ?? []).prefix(7)) })
            == .channels(Array(1...7)))
    #expect(error(try load { changeChannel(7, in: &$0) { $0["slot"] = 1 } }) == .channels([1, 2, 3, 4, 5, 6, 7, 1]))
    #expect(
        error(try load { changeBlock("Status", of: 2, in: &$0, to: nil) }) == .missingBlock(slot: 3, block: "Status"))
    #expect(
        error(try load { changeBlock("Extra", of: 2, in: &$0, to: "00") }) == .unknownBlock(slot: 3, block: "Extra"))
    #expect(
        error(try load { changeBlock("Contour(1)", of: 0, in: &$0, to: "0000AA") })
            == .blockLength(slot: 1, block: "Contour(1)", expected: 2, found: 3))
    #expect(
        error(try load { changeBlock("Contour(1)", of: 0, in: &$0, to: "00ZZ") })
            == .invalidBytes(slot: 1, block: "Contour(1)"))
    #expect(
        error(try load { changeBlock("Contour(1)", of: 0, in: &$0, to: "0080") })
            == .invalidBytes(slot: 1, block: "Contour(1)"))
    #expect(error(try load { changeChannel(4, in: &$0) { $0["name"] = "OTHER NAME" } }) == .nameMismatch(slot: 5))
    let map = try ParameterMap.bundled()
    #expect(throws: BackupError.self) { try ChannelBackup.load(Data("not json".utf8), map: map) }
}
