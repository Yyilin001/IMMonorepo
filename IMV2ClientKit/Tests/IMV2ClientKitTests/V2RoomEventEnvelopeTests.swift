import Foundation
import GRDB
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Room event payloads belong to their delivery envelope")
struct V2RoomEventEnvelopeTests {
    @Test("viewer-private timeline entries cannot enter the public room log", arguments: [false, true])
    func privateTimelineRejected(removed: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "room-private-envelope-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = UserID(uuid: UUID())
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "client.sqlite"), installationBinding: .init(value: UUID()), userID: user)
        let room = RoomID(uuid: UUID())
        if removed {
            let membership = try JSONSerialization.data(withJSONObject: ["event_type": "membership_changed",
                "room_id": room.rawValue, "target_user_id": user.rawValue, "action": "remove", "membership_revision": 1])
            _ = try await store.apply(.init(generation: 1, records: [.init(sequence: 1, sourceEventID: .init(uuid: UUID()),
                projectionKind: "membership", payload: membership)], nextSyncToken: .init("removed"),
                receipt: .init("removed"), hasMore: false, capabilityProfile: "base"))
        }
        let payload = try JSONSerialization.data(withJSONObject: ["event_type": "direct_message_restricted",
            "room_id": room.rawValue, "timeline_sequence": 7, "server_created_at_ms": 1000])
        let source = EventID(uuid: UUID())
        let page = try V2ClientGroupEventPage(roomID: room, events: [.init(sourceEventID: source,
            roomSequence: 1, projectionKind: "timeline_activity", payload: payload)], nextRoomSequence: 1, hasMore: false)
        await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await store.applyGroupEventPage(page) }
        #expect(try await store.groupEventCursor(roomID: room) == 0)
        #expect(try await store.timelineActivities(in: room).isEmpty)
        if !removed {
            _ = try await store.apply(.init(generation: 1, records: [.init(sequence: 1, sourceEventID: source,
                projectionKind: "timeline_activity", payload: payload)], nextSyncToken: .init("private-timeline"),
                receipt: .init("private-timeline"), hasMore: false, capabilityProfile: "base"))
            #expect(try await store.timelineActivities(in: room).count == 1)
        }
        #expect(try await store.groupEventCursor(roomID: room) == 0)
        try await store.close()
    }

    @Test(arguments: ["message.accepted", "message.reaction_changed", "member.muted", "room.frozen", "room.unfrozen"], ["room", "sequence"])
    func mismatchedPayloadRollsBackWholePage(type: String, defect: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "room-envelope-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "client.sqlite"),
            installationBinding: .init(value: UUID()))
        let room = RoomID(uuid: UUID()), other = RoomID(uuid: UUID()), actor = UserID(uuid: UUID())
        let firstID = MessageID(uuid: UUID()), secondID = MessageID(uuid: UUID()), secondSource = EventID(uuid: UUID())
        func payload(_ type: String, room: RoomID, sequence: UInt64, message: MessageID) throws -> Data {
            var fields: [String: Any] = ["event_type": type, "room_id": room.rawValue, "room_sequence": sequence,
                "server_created_at_ms": 1000]
            if type == "message.accepted" {
                fields["message_id"] = message.rawValue; fields["message_revision"] = 1
                fields["sender_user_id"] = actor.rawValue; fields["text"] = "room content"
            } else if type == "message.reaction_changed" {
                fields["message_id"] = message.rawValue; fields["actor_user_id"] = actor.rawValue
                fields["reaction"] = "👍"; fields["action"] = "add"
            } else {
                fields["actor_user_id"] = actor.rawValue
                if type == "member.muted" { fields["target_user_id"] = actor.rawValue; fields["mute_until_ms"] = 2000 }
            }
            return try JSONSerialization.data(withJSONObject: fields)
        }
        do {
            let first = try V2ClientGroupEvent(sourceEventID: .init(uuid: UUID()), roomSequence: 1,
                projectionKind: "message", payload: payload("message.accepted", room: room, sequence: 1, message: firstID))
            let invalid = try V2ClientGroupEvent(sourceEventID: secondSource, roomSequence: 2,
                projectionKind: type == "message.accepted" ? "message" : (type == "message.reaction_changed" ? "message_reaction" : "moderation"),
                payload: payload(type, room: defect == "room" ? other : room,
                    sequence: defect == "sequence" ? 99 : 2, message: secondID))
            let page = try V2ClientGroupEventPage(roomID: room, events: [first, invalid], nextRoomSequence: 2, hasMore: false)
            await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await store.applyGroupEventPage(page) }
            #expect(try await store.groupEventCursor(roomID: room) == 0)
            #expect(try await store.messages(in: room).isEmpty)
            #expect(try await store.messages(in: other).isEmpty)
            #expect(try await store.moderationActions().isEmpty)
            #expect(try await store.roomControl(roomID: room) == nil)
            #expect(try await store.roomControl(roomID: other) == nil)
            #expect(try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_message_effects") } == 0)
            #expect(try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_reaction_effects") } == 0)

            let corrected = try V2ClientGroupEvent(sourceEventID: secondSource, roomSequence: 2,
                projectionKind: invalid.projectionKind, payload: payload(type, room: room, sequence: 2, message: secondID))
            _ = try await store.applyGroupEventPage(.init(roomID: room, events: [first, corrected], nextRoomSequence: 2, hasMore: false))
            #expect(try await store.groupEventCursor(roomID: room) == 2)
            #expect(try await store.messages(in: room).count == (type == "message.accepted" ? 2 : 1))
            if type == "message.reaction_changed" { #expect(try await store.reactions(for: secondID).count == 1) }
            if type == "member.muted" { #expect(try await store.moderationActions().first?.roomSequence == 2) }
            if type.hasPrefix("room.") { #expect(try await store.roomControl(roomID: room)?.isFrozen == (type == "room.frozen")) }
            #expect(try await store.cursor() == nil)
            try await store.close()
        } catch { try? await store.close(); throw error }
    }
}
