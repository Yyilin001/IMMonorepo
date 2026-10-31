import Foundation
import IMV2Core

// Single-room construction shorthand for existing fixtures. The current wire
// always carries complete keys and has no legacy room/user-ID decoder.
extension V2AuthorPresentationInterests {
    init(streamID: UUID, viewID: UUID, roomID: RoomID, sequence: UInt64, userIDs: [UserID]) throws {
        try self.init(streamID: streamID, viewID: viewID, sequence: sequence,
            keys: userIDs.map { .init(userID: $0, context: .room(roomID)) })
    }
    var userIDs: [UserID] { keys.map(\.userID) }
}
extension V2AuthorPresentationReceipt {
    init(streamID: UUID, viewID: UUID, roomID: RoomID, sequence: UInt64, userIDs: [UserID], minimumRemainingMilliseconds: Int64) throws {
        try self.init(streamID: streamID, viewID: viewID, sequence: sequence,
            keys: userIDs.map { .init(userID: $0, context: .room(roomID)) }, minimumRemainingMilliseconds: minimumRemainingMilliseconds)
    }
    var userIDs: [UserID] { keys.map(\.userID) }
}
extension V2AuthorPresentationDelta {
    init(streamID: UUID, viewID: UUID, sequence: UInt64, actorUserID: UserID, deviceID: DeviceID,
         roomID: RoomID, serverViewAgeMilliseconds: Int64, batch: V2ProfilePresentationBatchResponse,
         retryAfterMilliseconds: Int64? = nil) throws {
        try self.init(streamID: streamID, viewID: viewID, sequence: sequence, actorUserID: actorUserID,
            deviceID: deviceID, serverViewAgeMilliseconds: serverViewAgeMilliseconds,
            batch: batch, retryAfterMilliseconds: retryAfterMilliseconds)
    }
}

@testable import IMV2ServerApplication
@testable import IMV2ServerContracts

private actor RegisteredAuthorStreams {
    static let shared = RegisteredAuthorStreams()
    private var streams: [UUID: UUID] = [:]
    func set(_ stream: UUID, connectionID: UUID) { streams[connectionID] = stream }
    func get(_ connectionID: UUID) -> UUID? { streams[connectionID] }
}
extension V2AuthorPresentationDispatcher {
    func registerFixture(connectionID: UUID, identity: V2AuthenticatedConnection, streamID: UUID = UUID(),
                         send: @escaping @Sendable (Data, ContinuousClock.Instant) async -> Bool) async throws -> UUID {
        let stream = try register(connectionID: connectionID, identity: identity, streamID: streamID,
            send: { await send($0, $1) ? .enqueued : .discarded })
        await RegisteredAuthorStreams.shared.set(stream, connectionID: connectionID)
        return stream
    }
    func activateRoomFixture(connectionID: UUID, roomID: RoomID, viewID: UUID) async -> Bool {
        guard let stream = await RegisteredAuthorStreams.shared.get(connectionID),
              let start = try? V2AuthorPresentationStart(streamID: stream, viewID: viewID, messageRoomIDs: [roomID]) else { return false }
        return activateView(connectionID: connectionID, start: start)
    }
}
extension V2AuthorPresentationTransport {
    func activate(viewID: UUID, roomID: RoomID) { activate(viewID: viewID, messageRoomIDs: [roomID]) }
}

// Only the single-room fixtures use this projection; no wire field exists.
extension V2AuthorPresentationDelta {
    var roomID: RoomID { batch.results[0].key.context.authorizationRoomID! }
}
