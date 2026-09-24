import Foundation
import IMV2ActorContracts
import IMV2Core
import IMV2Server
import Testing

@Suite("Room log wire preserves durable recovery facts")
struct V2ActorRoomLogWireTests {
    @Test("full page round trip preserves event bytes, identity and trimmed floor")
    func pageRoundTrip() throws {
        let page = try V2GroupEventLogPage(
            roomID: RoomID("room"),
            events: [
                .init(
                    sourceEventID: EventID("event"), roomSequence: 43,
                    projectionKind: "message.edited",
                    payload: Data([0, 255, 1, 127])
                ),
            ],
            nextRoomSequence: 43, hasMore: true, logTrimmedThroughRoomSequence: 42
        )
        let wire = try V2ActorRoomLogPageWire(page)
        let decoded = try JSONDecoder().decode(
            V2ActorRoomLogPageWire.self, from: JSONEncoder().encode(wire)
        )
        #expect(try decoded.domainValue() == page)
    }

    @Test("subscription keeps its membership revision independent of the head")
    func subscriptionRoundTrip() throws {
        let subscription = try V2GroupEventSubscription(
            roomID: RoomID("room"), highWatermark: 125, membershipRevision: 7
        )
        let result = try V2RoomLogQueryResult.subscription(.init(subscription))
        let decoded = try JSONDecoder().decode(
            V2RoomLogQueryResult.self, from: JSONEncoder().encode(result)
        )
        guard case .subscription(let wire) = decoded else {
            Issue.record("wire result kind changed")
            return
        }
        #expect(try wire.domainValue() == subscription)
    }

    @Test("untrusted cursors and page sizes are rejected during decoding")
    func badRequest() throws {
        let request = try V2ActorRoomLogPullWire(
            roomID: RoomID("room"), actorUserID: UserID("actor"),
            afterRoomSequence: 0, pageSize: 500
        )
        #expect(V2ActorRoomLogPullWire.maximumPageSize == V2GroupEventLogService.maximumPageSize)
        let value = V2RoomLogQuery.pull(request)
        #expect(try JSONDecoder().decode(
            V2RoomLogQuery.self, from: JSONEncoder().encode(value)
        ) == value)
        var object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(request)
        ) as? [String: Any])
        object["pageSize"] = 501
        #expect(throws: V2ActorRoomLogWireError.invalidPageSize) {
            try JSONDecoder().decode(
                V2ActorRoomLogPullWire.self, from: JSONSerialization.data(withJSONObject: object)
            )
        }
        object["pageSize"] = 1
        object["afterRoomSequence"] = UInt64.max
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                V2ActorRoomLogPullWire.self, from: JSONSerialization.data(withJSONObject: object)
            )
        }
    }

    @Test("malformed output cannot introduce a zero event or overflowed revision")
    func badResponse() throws {
        let entry = try V2ActorRoomLogEntryWire(
            sourceEventID: EventID("event"), roomSequence: 1,
            projectionKind: "message.accepted", payload: Data()
        )
        var object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(entry)
        ) as? [String: Any])
        object["roomSequence"] = 0
        #expect(throws: V2ActorRoomLogWireError.invalidSequence) {
            try JSONDecoder().decode(
                V2ActorRoomLogEntryWire.self, from: JSONSerialization.data(withJSONObject: object)
            )
        }
        #expect(throws: (any Error).self) {
            try V2ActorRoomLogSubscriptionWire(
                roomID: RoomID("room"), highWatermark: 1, membershipRevision: UInt64.max
            )
        }
    }
}
