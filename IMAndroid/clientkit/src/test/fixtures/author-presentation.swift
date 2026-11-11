import Foundation
import IMV2Core

// Input is the existing Swift profile-presentations-swift.txt golden file.
// This generator uses the current repository's actual IMV2Core validation and JSONEncoder.
let lines = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).split(separator: "\n")
let actor = try UserID("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
let device = try DeviceID("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")
let stream = UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!
let view = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
for index in 1...5 {
    let batch = try JSONDecoder().decode(V2ProfilePresentationBatchResponse.self, from: Data(lines[index].utf8))
    let delta = try V2AuthorPresentationDelta(streamID: stream, viewID: view, sequence: UInt64(index), actorUserID: actor,
        deviceID: device, serverViewAgeMilliseconds: 200, batch: batch, retryAfterMilliseconds: index == 2 ? 1_000 : nil)
    print(String(data: try encoder.encode(delta), encoding: .utf8)!)
}
