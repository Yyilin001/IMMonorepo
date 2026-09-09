import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

struct V2PreparedGroupResponseBoundsTests {
    @Test(arguments: [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max], [false, true])
    func watermarkBounds(value: UInt64, hasMore: Bool) async throws {
        let room = try RoomID("room"), user = try UserID("user")
        var envelope = IMV2Envelope()
        envelope.requestID = 7
        envelope.protocolVersion = 21
        envelope.groupEventPage.roomID = room.rawValue
        envelope.groupEventPage.nextRoomSequence = value
        envelope.groupEventPage.hasMore_p = hasMore
        let frame = try V2ServerProtobufFrameCodec.encode(envelope, frameVersion: 21, compression: nil,
            maximumUncompressedPayloadBytes: 65536, compressionThresholdBytes: 1024,
            maximumExpansionRatio: 64, bindRequestIDToHeader: true)
        let expected = V2PreparedGroupEventPageResponse(frame: frame, roomID: room, nextRoomSequence: value, hasMore: hasMore)
        let service = V2GroupEventLogService(store: PreparedResponseBoundsStore(response: expected))
        let context = V2PreparedGroupEventPageEncodingContext(requestID: 7, frameVersion: 21, compression: nil,
            maximumUncompressedPayloadBytes: 65536, compressionThresholdBytes: 1024, maximumExpansionRatio: 64,
            maximumGroupEventPagePayloadBytes: 60000,
            cache: .init(configuration: .init(maximumEntries: 1, maximumBytes: 65536, shardCount: 1)))
        for after in [UInt64(0), 1, UInt64(Int64.max)] {
            if value > UInt64(Int64.max) || value < after || (hasMore && value == after) {
                await #expect(throws: V2GroupEventLogError.corruptPersistenceState) {
                    try await service.pullPrepared(roomID: room, actorUserID: user, afterRoomSequence: after, pageSize: 1, context: context)
                }
            } else {
                guard case .prepared(let actual) = try await service.pullPrepared(roomID: room, actorUserID: user, afterRoomSequence: after, pageSize: 1, context: context) else { Issue.record("expected prepared response"); return }
                #expect(actual.nextRoomSequence == value)
                #expect(actual.frame == frame)
            }
        }
    }
}

private struct PreparedResponseBoundsStore: V2PreparedGroupEventLogStore {
    let response: V2PreparedGroupEventPageResponse
    func pull(roomID: RoomID, actorUserID: UserID, afterRoomSequence: UInt64, pageSize: Int) async throws -> V2GroupEventLogPage { throw V2GroupEventLogError.invalidRequest }
    func subscribe(roomID: RoomID, actorUserID: UserID) async throws -> V2GroupEventSubscription { throw V2GroupEventLogError.invalidRequest }
    func pullPrepared(roomID: RoomID, actorUserID: UserID, afterRoomSequence: UInt64, pageSize: Int, context: V2PreparedGroupEventPageEncodingContext) async throws -> V2PreparedGroupEventPullResult { .prepared(response) }
}
