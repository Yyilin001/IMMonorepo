import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 room actor media authorization port")
struct V2RoomActorMediaAuthorizationPortTests {
    @Test("exchange re-queries the room and rejects a changed version")
    func rechecksVersion() async throws {
        let room = RoomID(uuid: UUID()), message = MessageID(uuid: UUID())
        let media = MediaID(uuid: UUID()), actor = UserID(uuid: UUID())
        let first = V2ActorMessageMediaVisibilitySnapshotWire(roomID: room,
            messageID: message, mediaID: media, membershipRevision: 2,
            contentRevision: 1, mediaUpdatedAt: Date(timeIntervalSince1970: 123),
            uploadSessionID: UUID())
        let state = V2MediaVisibilityState(value: .visible(first))
        let port = V2ActorRoomMediaAuthorizationPort(query: { query, _ in
            guard query.actorUserID == actor else { return .notVisible }
            return await state.get()
        })
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        let request = V2ActorMessageMediaVisibilityWire(roomID: room,
            messageID: message, mediaID: media, actorUserID: actor)
        #expect(try await port.capture(request, deadline: deadline) == first)
        #expect(try await port.recheck(first, actorUserID: actor, deadline: deadline))
        await state.set(.visible(.init(roomID: room, messageID: message, mediaID: media,
            membershipRevision: 3, contentRevision: 1,
            mediaUpdatedAt: first.mediaUpdatedAt,
            uploadSessionID: first.uploadSessionID)))
        #expect(try await port.recheck(first, actorUserID: actor, deadline: deadline) == false)
        await state.set(.notVisible)
        #expect(try await port.recheck(first, actorUserID: actor, deadline: deadline) == false)
    }
}

private actor V2MediaVisibilityState {
    private var value: V2RoomMediaAuthorizationResult
    init(value: V2RoomMediaAuthorizationResult) { self.value = value }
    func get() -> V2RoomMediaAuthorizationResult { value }
    func set(_ next: V2RoomMediaAuthorizationResult) { value = next }
}
