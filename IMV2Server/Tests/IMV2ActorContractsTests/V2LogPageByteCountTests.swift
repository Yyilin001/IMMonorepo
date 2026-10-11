@testable import IMV2ActorContracts
import Foundation
import IMV2Core
import Testing

struct V2LogPageByteCountTests {
    @Test(arguments: [0, 1, 127, 128, 16383, 16384])
    func matchesGeneratedEncoding(payloadBytes: Int) throws {
        let entry = try V2ActorRoomLogEntryWire(sourceEventID: .init(uuid: UUID()),
            roomSequence: UInt64(Int64.max), projectionKind: "消息📨", payload: Data(repeating: 255, count: payloadBytes))
        for count in [0, 1, 2] {
            let page = try V2ActorRoomLogPageWire(roomID: .init(uuid: UUID()), events: Array(repeating: entry, count: count),
                nextRoomSequence: UInt64(Int64.max), hasMore: count > 0, logTrimmedThroughRoomSequence: 0)
            #expect(try page.protobufResponseByteCount() == V2ActorProtobuf.encode(V2RoomResponse.roomLog(.page(page))).count)
        }
    }
}
