import Foundation
import GRDB
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Group nickname durable invalidations")
struct V2GroupNicknameProjectionTests {
    private let room = RoomID(uuid: UUID(uuidString: "00000000-0000-0000-0000-000000ABCDEF")!)
    private let user = UserID(uuid: UUID())
    private let binding = V2LocalInstallationBinding(value: UUID())

    @Test("member revisions are independent and only the nickname notification scope wakes")
    func scopedLookupAndNotifications() async throws {
        let store = try makeStore(temporaryURL()), other = UserID(uuid: UUID())
        let subscription = await store.projectionChanges()
        var notifications = subscription.makeAsyncIterator()
        _ = await notifications.next()
        try await store.applyGroupEventPage(page(fact(sequence: 1, revision: 2, roomSequence: 10), sequence: 10))
        #expect(await notifications.next()?.scopes == .groupNicknames)
        let keys: Set<V2ProfileViewLookupKey> = [
            .init(userID: user, context: .room(room)), .init(userID: other, context: .room(room)),
            .init(userID: user, context: .room(.init(uuid: UUID()))), .init(userID: user, context: .relationship)
        ]
        let revisions = try await store.groupNicknameRevisions(keys: keys)
        #expect(revisions.count == 4 && revisions.values.filter { $0 == 2 }.count == 1)
        let first = try fact(sequence: 2, revision: 1, roomSequence: 11, source: "other-member")
        var payload = try #require(JSONSerialization.jsonObject(with: first.payload) as? [String: Any])
        payload["target_user_id"] = other.rawValue
        let otherFact = try V2ClientSyncRecord(sequence: 2, sourceEventID: first.sourceEventID,
            projectionKind: first.projectionKind, payload: JSONSerialization.data(withJSONObject: payload))
        try await store.applyGroupEventPage(page(otherFact, sequence: 11))
        let current = try await store.groupNicknameRevisions(keys: keys)
        #expect(current[.init(userID: other, context: .room(room))] == 1)
        #expect(current[.init(userID: user, context: .room(room))] == 2)
        #expect(try await store.roomAppliedRoomSequence(roomID: room) == 11)
        try await store.close()
    }

    @Test("room log replay, out-of-order facts and restart never lower the invalidation floor")
    func replayAndOrdering() async throws {
        let url = temporaryURL()
        var store = try makeStore(url)
        let latest = try fact(sequence: 1, revision: 2, roomSequence: 20)
        _ = try await store.apply(batch([latest]))
        try await store.applyGroupEventPage(page(latest, sequence: 20))
        _ = try await store.apply(batch([fact(sequence: 2, revision: 1, roomSequence: 10)]))
        #expect(try await revision(store) == 2)
        #expect(try await store.roomAppliedRoomSequence(roomID: room) == 20)
        try await store.close()
        store = try makeStore(url)
        for conflicting in [
            try fact(sequence: 3, revision: 2, roomSequence: 20, source: "different-source"),
            try fact(sequence: 3, revision: 1, roomSequence: 11),
            try fact(sequence: 3, revision: 3, roomSequence: 19),
        ] {
            await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { _ = try await store.apply(batch([conflicting])) }
        }
        #expect(try await store.cursor()?.appliedSequence == 2)
        #expect(try await revision(store) == 2)
        #expect(try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM v2_group_nickname_effects") } == 2)
        try await store.close()
    }

    @Test("malformed or credential-bearing nickname invalidations cannot advance the room cursor",
          arguments: ["room", "sequence", "zero", "fraction", "url", "nickname", "user"])
    func invalidPayload(kind: String) async throws {
        let store = try makeStore(temporaryURL())
        let valid = try fact(sequence: 1, revision: 1, roomSequence: 10)
        var payload = try #require(JSONSerialization.jsonObject(with: valid.payload) as? [String: Any])
        switch kind {
        case "room": payload["room_id"] = UUID().uuidString
        case "sequence": payload["room_sequence"] = 11
        case "zero": payload["revision"] = 0
        case "fraction": payload["revision"] = 1.5
        case "nickname": payload["nickname"] = "Private name must not be broadcast"
        case "user": payload["target_user_id"] = "not-a-uuid"
        default: payload["url"] = "https://provider.invalid/capability"
        }
        let malformed = try V2ClientSyncRecord(sequence: 1, sourceEventID: valid.sourceEventID,
            projectionKind: valid.projectionKind, payload: JSONSerialization.data(withJSONObject: payload))
        await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { _ = try await store.applyGroupEventPage(page(malformed, sequence: 10)) }
        #expect(try await store.groupEventCursor(roomID: room) == 0)
        #expect(try await revision(store) == 0)
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
        let old = try fact(sequence: 2, revision: 1, roomSequence: 10)
        let nickname = try V2SnapshotProjectionItem(key: .init(projectionKind: "group_capability", entityKey: "nickname:" + room.rawValue.lowercased() + ":" + user.rawValue.lowercased()), sourceEventID: old.sourceEventID, sequence: 2, payload: old.payload)
        let fixture = try makeSnapshotFixture(reset: reset, pages: removed ? [] : [.init(items: [nickname, item])])
        try await store.beginReset(reset)
        try await store.beginSnapshotImport(fixture.manifest, initialDigest: V2SnapshotV3Digest.initial(baseSequence: 10, capabilityProfile: "base"))
        for page in fixture.pages { try await store.applySnapshotPage(page, for: fixture.manifest) }
        try await store.prepareSnapshotActivation(fixture.manifest)
        try await store.activateAcknowledgedSnapshot(fixture.manifest)
        try await store.close()
        let reopened = try makeStore(url)
        #expect(try await revision(reopened) == (removed ? 0 : 2))
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
        #expect(try await revision(store) == 0)
        #expect(try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM v2_group_nickname_effects") } == 0)
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
        #expect(try await revision(reopened) == 0)
        try await reopened.close()
    }

    private func revision(_ store: GRDBV2LocalSyncStore) async throws -> UInt64? {
        let key = V2ProfileViewLookupKey(userID: user, context: .room(room))
        return try await store.groupNicknameRevisions(keys: [key])[key]
    }

    private func makeStore(_ url: URL) throws -> GRDBV2LocalSyncStore {
        try .init(databaseURL: url, installationBinding: binding, userID: user)
    }
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("group-nickname-\(UUID()).sqlite")
    }
    private func fact(sequence: UInt64, revision: Int, roomSequence: Int, source: String? = nil) throws -> V2ClientSyncRecord {
        try .init(sequence: sequence, sourceEventID: .init(source ?? "nickname-\(revision)"), projectionKind: "group_capability",
            payload: JSONSerialization.data(withJSONObject: ["event_type": "group.nickname_changed", "room_id": room.rawValue, "target_user_id": user.rawValue,
                "revision": revision, "room_sequence": roomSequence, "server_created_at_ms": revision * 1000]))
    }
    private func page(_ record: V2ClientSyncRecord, sequence: UInt64) throws -> V2ClientGroupEventPage {
        try .init(roomID: room, events: [.init(sourceEventID: record.sourceEventID, roomSequence: sequence,
            projectionKind: record.projectionKind, payload: record.payload)], nextRoomSequence: sequence, hasMore: false)
    }
    private func batch(_ records: [V2ClientSyncRecord]) throws -> V2ClientSyncBatch {
        try .init(generation: 1, records: records, nextSyncToken: .init("nickname-token"), receipt: .init("nickname-receipt"), hasMore: false, capabilityProfile: "base")
    }
    private func membership(sequence: UInt64, revision: Int, action: String = "add") throws -> V2ClientSyncRecord {
        try .init(sequence: sequence, sourceEventID: .init("membership-\(revision)"), projectionKind: "membership",
            payload: JSONSerialization.data(withJSONObject: ["event_type": "membership_changed", "room_id": room.rawValue,
                "title": "Nickname", "owner_user_id": user.rawValue, "target_user_id": user.rawValue, "action": action,
                "membership_revision": revision, "capacity_class": "standard", "created_at_ms": 1000, "server_created_at_ms": revision * 1000]))
    }
}
