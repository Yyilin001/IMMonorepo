import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("Gateway RoomRef composition")
struct V2GatewayRoomActorCompositionTests {
    @Test("event log pull and subscription use only the room capability; prepared pull falls back to a page")
    func eventLogBoundary() async throws {
        let room = RoomID(uuid: UUID()), user = UserID(uuid: UUID())
        let calls = GatewayRoomCalls()
        let page = try V2GroupEventLogPage(roomID: room, events: [],
            nextRoomSequence: 7, hasMore: false)
        let subscription = try V2GroupEventSubscription(roomID: room,
            highWatermark: 7, membershipRevision: 4)
        let caller = V2RoomRefUserCaller(timeout: .seconds(5)) { request, principal, deadline in
            #expect(principal == user && deadline > .now)
            switch request {
            case .roomLog(.pull(let query)):
                #expect(query.roomID == room && query.afterRoomSequence == 7)
                await calls.add("pull")
                return .roomLog(.page(try .init(page)))
            case .roomLog(.subscribe(let query)):
                #expect(query.roomID == room)
                await calls.add("subscribe")
                return .roomLog(.subscription(try .init(subscription)))
            default:
                Issue.record("event log escaped its room capability")
                throw V2RoomCallFailure.outcomeUnknown
            }
        }
        let client = V2RoomRefGroupEventLogClient(rooms: .init(caller: caller))
        #expect(try await client.pull(roomID: room, actorUserID: user,
            afterRoomSequence: 7, pageSize: 10) == page)
        #expect(try await client.subscribe(roomID: room, actorUserID: user) == subscription)
        let context = V2PreparedGroupEventPageEncodingContext(requestID: 1,
            frameVersion: 21, compression: nil, maximumUncompressedPayloadBytes: 65_536,
            compressionThresholdBytes: 1_024, maximumExpansionRatio: 64,
            maximumGroupEventPagePayloadBytes: 60_000,
            cache: .init(configuration: .init(maximumEntries: 1,
                maximumBytes: 65_536, shardCount: 1)))
        guard case .page(let fallback) = try await client.pullPrepared(roomID: room,
            actorUserID: user, afterRoomSequence: 7, pageSize: 10,
            context: context) else {
            Issue.record("prepared path skipped ordinary RoomRef page"); return
        }
        #expect(fallback == page)
        #expect(await calls.values() == ["pull", "subscribe", "pull"])
    }




}

private actor GatewayRoomCalls {
    private var recorded: [String] = []
    func add(_ value: String) { recorded.append(value) }
    func values() -> [String] { recorded }
}
