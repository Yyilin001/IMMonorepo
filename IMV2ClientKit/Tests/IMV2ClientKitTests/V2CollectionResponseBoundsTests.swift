import Foundation
import IMV2ClientKit
import IMV2Core
import Testing

struct V2CollectionResponseBoundsTests {
    @Test(arguments:[UInt64(0),1,UInt64(Int64.max),UInt64(Int64.max)+1,UInt64.max])
    func forwardAcceptedSequenceBounds(value:UInt64) throws {
        let message=MessageID(uuid:UUID())
        let encoded=String(decoding:try JSONEncoder().encode(message),as:UTF8.self)
        let data=Data("{\"messageID\":\(encoded),\"roomSequence\":\(value)}".utf8)
        if value==0 || value>UInt64(Int64.max) {
            #expect(throws:(any Error).self) { try JSONDecoder().decode(V2MessageOperationAcceptance.self,from:data) }
        } else {
            #expect(try JSONDecoder().decode(V2MessageOperationAcceptance.self,from:data).roomSequence==value)
        }
    }

    @Test(arguments: ["members", "emptyEvents", "event", "subscription"],
          [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max])
    func responseBounds(kind: String, value: UInt64) async throws {
        let transport = V2ProtobufSyncTransport(wire: CollectionBoundsWire(kind: kind, value: value), protocolVersion: 1)
        let room = RoomID(uuid: UUID())
        func receivedValue() async throws -> UInt64? {
            switch kind {
            case "members":
                return try await transport.listRoomMembers(roomID: room, cursor: nil, pageSize: 1).membershipRevision
            case "subscription":
                return try await transport.subscribeToGroupEvents(roomID: room, afterRoomSequence: 0).highWatermark
            default:
                let page = try await transport.pullGroupEvents(roomID: room, afterRoomSequence: 0, pageSize: 1)
                #expect(page.events.count == (kind == "event" ? 1 : 0))
                if kind == "event" { #expect(page.events.first?.roomSequence == value) }
                return page.nextRoomSequence
            }
        }
        let zeroAllowed = kind == "emptyEvents" || kind == "subscription" || kind == "members"
        if value > UInt64(Int64.max) || (value == 0 && !zeroAllowed) {
            await #expect(throws: V2RealtimeTransportError.unexpectedResponse) { _ = try await receivedValue() }
        } else {
            #expect(try await receivedValue() == value)
        }
    }
}

private actor CollectionBoundsWire: V2AuthenticatedFrameTransport {
    let kind: String
    let value: UInt64
    init(kind: String, value: UInt64) { self.kind = kind; self.value = value }
    func request(_ frame: V2Frame) throws -> V2Frame {
        let request = try V2ProtobufFrameCodec.decode(frame)
        var response = IMV2Envelope()
        response.protocolVersion = 1
        response.requestID = frame.requestID
        switch request.body {
        case .listRoomMembers(let request):
            response.roomMembersPage.roomID = request.roomID
            response.roomMembersPage.membershipRevision = value; response.roomMembersPage.actorRole = .owner
        case .groupEventPull(let request):
            response.groupEventPage.roomID = request.roomID; response.groupEventPage.nextRoomSequence = value
            if kind == "event" {
                var item = IMV2GroupEvent()
                item.sourceEventID = UUID().uuidString; item.roomSequence = value
                item.projectionKind = "message"; item.payload = Data("{}".utf8)
                response.groupEventPage.events = [item]
            }
        case .groupEventSubscribe(let request):
            response.groupEventSubscribed.roomID = request.roomID; response.groupEventSubscribed.highWatermark = value
        default: throw V2RealtimeTransportError.unexpectedResponse
        }
        return try V2ProtobufFrameCodec.encode(response, frameVersion: 1)
    }
}
