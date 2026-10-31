import Foundation
import GRDB
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Group avatar durable invalidations")
struct V2GroupAvatarProjectionTests {
    private let room = RoomID(uuid: UUID(uuidString: "00000000-0000-0000-0000-000000ABCDEF")!)
    private let user = UserID(uuid: UUID())
    private let binding = V2LocalInstallationBinding(value: UUID())

    @Test("a failed room apply transaction reports its previous durable C and server C never promotes it")
    func failedApplyAndServerProgressCannotAdvanceCursor() async throws {
        let url = temporaryURL()
        let store = try makeStore(url)
        _ = try await store.applyGroupEventPage(.init(roomID: room, events: [], nextRoomSequence: 4, hasMore: false))
        let valid = try fact(sequence: 1, revision: 1, roomSequence: 5)
        var malformedPayload = try #require(JSONSerialization.jsonObject(with: valid.payload) as? [String: Any])
        malformedPayload["room_sequence"] = 7
        let invalid = try V2ClientSyncRecord(sequence: 2, sourceEventID: .init("invalid"),
            projectionKind: valid.projectionKind, payload: JSONSerialization.data(withJSONObject: malformedPayload))
        let failedPage = try V2ClientGroupEventPage(roomID: room, events: [
            .init(sourceEventID: valid.sourceEventID, roomSequence: 5, projectionKind: valid.projectionKind, payload: valid.payload),
            .init(sourceEventID: invalid.sourceEventID, roomSequence: 6, projectionKind: invalid.projectionKind, payload: invalid.payload)
        ], nextRoomSequence: 6, hasMore: false)
        await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { _ = try await store.applyGroupEventPage(failedPage) }
        #expect(try await store.groupAvatarRevision(roomID: room) == 0)
        #expect(try await store.groupEventCursor(roomID: room) == 4)
        let wire = RoomProgressHeartbeatWire(room: room, serverAccepted: 7)
        let transport = V2ProtobufSyncTransport(wire: wire, protocolVersion: 1,
            durableRoomProgress: { roomID in try await store.roomProgressAppliedSequence(roomID: roomID) })
        try await transport.sendHeartbeat()
        #expect(await wire.reportedApplied == 4)
        #expect(await wire.receivedHead == 7)
        #expect(try await store.roomProgressAppliedSequence(roomID: room) == 4)
        try await store.close()
        let reopened = try makeStore(url)
        #expect(try await reopened.groupEventCursor(roomID: room) == 4)
        #expect(try await reopened.groupAvatarRevision(roomID: room) == 0)
        try await reopened.close()
    }

    @Test("room progress comes only from committed authorized page processing and excludes trimmed gaps")
    func durableRoomProgressBoundary() async throws {
        let store = try makeStore(temporaryURL())
        _ = try await store.apply(batch([membership(sequence: 1, revision: 1)]))
        // Personal membership does not prove that the room log was applied.
        #expect(try await store.roomProgressAppliedSequence(roomID: room) == nil)
        // A server-authorized empty filtered page can still be processed through.
        _ = try await store.applyGroupEventPage(.init(roomID: room, events: [], nextRoomSequence: 20, hasMore: false))
        #expect(try await store.roomProgressAppliedSequence(roomID: room) == 20)
        _ = try await store.applyGroupEventPage(.init(roomID: room, events: [], nextRoomSequence: 30,
            hasMore: false, logTrimmedThroughRoomSequence: 25))
        #expect(try await store.groupEventCursor(roomID: room) == 30)
        #expect(try await store.roomProgressAppliedSequence(roomID: room) == nil)
        try await store.close()
    }

    @Test("room log replay, out-of-order facts and restart never lower the invalidation floor")
    func replayAndOrdering() async throws {
        let url = temporaryURL()
        var store = try makeStore(url)
        let latest = try fact(sequence: 1, revision: 2, roomSequence: 20)
        _ = try await store.applyGroupEventPage(page(fact(sequence: 1, revision: 1, roomSequence: 10), sequence: 10))
        _ = try await store.applyGroupEventPage(page(latest, sequence: 20))
        _ = try await store.applyGroupEventPage(page(latest, sequence: 20))
        #expect(try await store.groupAvatarRevision(roomID: room) == 2)
        #expect(try await store.roomAppliedRoomSequence(roomID: room) == 20)
        try await store.close()
        store = try makeStore(url)
        for (sequence, conflicting) in [
            (UInt64(20), try fact(sequence: 3, revision: 2, roomSequence: 20, source: "different-source")),
            (UInt64(11), try fact(sequence: 3, revision: 1, roomSequence: 11)),
            (UInt64(19), try fact(sequence: 3, revision: 3, roomSequence: 19)),
        ] {
            await #expect(throws: V2ClientSyncError.invalidRecordOrdering) {
                _ = try await store.applyGroupEventPage(page(conflicting, sequence: sequence))
            }
        }
        // A later log position must not carry a regressing content revision.
        await #expect(throws: V2ClientProjectionError.invalidMessagePayload) {
            _ = try await store.applyGroupEventPage(page(fact(sequence: 3, revision: 1,
                roomSequence: 30, source: "regressing-revision"), sequence: 30))
        }
        #expect(try await store.cursor() == nil)
        #expect(try await store.groupEventCursor(roomID: room) == 20)
        #expect(try await store.groupAvatarRevision(roomID: room) == 2)
        #expect(try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM v2_group_avatar_effects") } == 2)
        try await store.close()
    }

    @Test("malformed or credential-bearing avatar invalidations cannot advance the room cursor",
          arguments: ["room", "sequence", "zero", "fraction", "url"])
    func invalidPayload(kind: String) async throws {
        let store = try makeStore(temporaryURL())
        let valid = try fact(sequence: 1, revision: 1, roomSequence: 10)
        var payload = try #require(JSONSerialization.jsonObject(with: valid.payload) as? [String: Any])
        switch kind {
        case "room": payload["room_id"] = UUID().uuidString
        case "sequence": payload["room_sequence"] = 11
        case "zero": payload["revision"] = 0
        case "fraction": payload["revision"] = 1.5
        default: payload["url"] = "https://provider.invalid/capability"
        }
        let malformed = try V2ClientSyncRecord(sequence: 1, sourceEventID: valid.sourceEventID,
            projectionKind: valid.projectionKind, payload: JSONSerialization.data(withJSONObject: payload))
        await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { _ = try await store.applyGroupEventPage(page(malformed, sequence: 10)) }
        #expect(try await store.groupEventCursor(roomID: room) == 0)
        #expect(try await store.groupAvatarRevision(roomID: room) == 0)
        try await store.close()
    }

    @Test("a snapshot preserves newer room state only for rooms still authorized", arguments: [false, true])
    func snapshot(removed: Bool) async throws {
        let url = temporaryURL(), store = try makeStore(url)
        let member = try membership(sequence: 1, revision: 1)
        _ = try await store.apply(batch([member]))
        try await store.applyGroupEventPage(page(fact(sequence: 2, revision: 2, roomSequence: 20), sequence: 20))
        let reset = try V2ClientResetRequired(snapshotID: .init(uuid: UUID()), generation: 2, baseSequence: 10, expiresAt: .distantFuture)
        let item = try V2SnapshotProjectionItem(key: .init(projectionKind: "room", entityKey: room.rawValue), sourceEventID: member.sourceEventID, sequence: 1, payload: member.payload)
        // Personal snapshots contain membership only; recovered room-log
        // invalidations are retained exactly when this room remains eligible.
        let fixture = try makeSnapshotFixture(reset: reset, pages: removed ? [] : [.init(items: [item])])
        try await store.beginReset(reset)
        try await store.beginSnapshotImport(fixture.manifest, initialDigest: V2SnapshotV3Digest.initial(baseSequence: 10, capabilityProfile: "base"))
        for page in fixture.pages { try await store.applySnapshotPage(page, for: fixture.manifest) }
        try await store.prepareSnapshotActivation(fixture.manifest)
        try await store.activateAcknowledgedSnapshot(fixture.manifest)
        try await store.close()
        let reopened = try makeStore(url)
        #expect(try await reopened.groupAvatarRevision(roomID: room) == (removed ? 0 : 2))
        #expect(try await reopened.roomAppliedRoomSequence(roomID: room) == (removed ? 0 : 20))
        try await reopened.close()
    }

    @Test("leaving a room removes invalidation state and wakes presentation consumers")
    func membershipRemoval() async throws {
        let store = try makeStore(temporaryURL())
        _ = try await store.apply(batch([membership(sequence: 1, revision: 1)]))
        try await store.applyGroupEventPage(page(fact(sequence: 2, revision: 1, roomSequence: 10), sequence: 10))
        let subscription = await store.projectionChanges()
        var changes = subscription.makeAsyncIterator()
        _ = await changes.next()
        _ = try await store.apply(batch([membership(sequence: 2, revision: 2, action: "remove")]))
        #expect(await changes.next()?.scopes.contains(.presentations) == true)
        #expect(try await store.groupAvatarRevision(roomID: room) == 0)
        #expect(try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM v2_group_avatar_effects") } == 0)
        try await store.close()
    }

    @Test("restart preserves projection tables in an in-progress snapshot bank")
    func resumePendingSnapshot() async throws {
        let url = temporaryURL(), store = try makeStore(url)
        let reset = try V2ClientResetRequired(snapshotID: .init(uuid: UUID()), generation: 2, baseSequence: 10, expiresAt: .distantFuture)
        let fixture = try makeSnapshotFixture(reset: reset, pages: [])
        try await store.beginReset(reset)
        try await store.beginSnapshotImport(fixture.manifest, initialDigest: V2SnapshotV3Digest.initial(baseSequence: 10, capabilityProfile: "base"))
        try await store.close()
        let reopened = try makeStore(url)
        try await reopened.prepareSnapshotActivation(fixture.manifest)
        try await reopened.activateAcknowledgedSnapshot(fixture.manifest)
        #expect(try await reopened.groupAvatarRevision(roomID: room) == 0)
        try await reopened.close()
    }

    private func makeStore(_ url: URL) throws -> GRDBV2LocalSyncStore {
        try .init(databaseURL: url, installationBinding: binding, userID: user)
    }
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("group-avatar-\(UUID()).sqlite")
    }
    private func fact(sequence: UInt64, revision: Int, roomSequence: Int, source: String? = nil) throws -> V2ClientSyncRecord {
        try .init(sequence: sequence, sourceEventID: .init(source ?? "avatar-\(revision)"), projectionKind: "group_capability",
            payload: JSONSerialization.data(withJSONObject: ["event_type": "group.avatar_changed", "room_id": room.rawValue,
                "revision": revision, "room_sequence": roomSequence, "server_created_at_ms": revision * 1000]))
    }
    private func page(_ record: V2ClientSyncRecord, sequence: UInt64) throws -> V2ClientGroupEventPage {
        try .init(roomID: room, events: [.init(sourceEventID: record.sourceEventID, roomSequence: sequence,
            projectionKind: record.projectionKind, payload: record.payload)], nextRoomSequence: sequence, hasMore: false)
    }
    private func batch(_ records: [V2ClientSyncRecord]) throws -> V2ClientSyncBatch {
        try .init(generation: 1, records: records, nextSyncToken: .init("avatar-token"), receipt: .init("avatar-receipt"), hasMore: false, capabilityProfile: "base")
    }
    private func membership(sequence: UInt64, revision: Int, action: String = "add") throws -> V2ClientSyncRecord {
        try .init(sequence: sequence, sourceEventID: .init("membership-\(revision)"), projectionKind: "membership",
            payload: JSONSerialization.data(withJSONObject: ["event_type": "membership_changed", "room_id": room.rawValue,
                "title": "Avatar", "owner_user_id": user.rawValue, "target_user_id": user.rawValue, "action": action,
                "membership_revision": revision, "capacity_class": "standard", "created_at_ms": 1000, "server_created_at_ms": revision * 1000]))
    }
}
