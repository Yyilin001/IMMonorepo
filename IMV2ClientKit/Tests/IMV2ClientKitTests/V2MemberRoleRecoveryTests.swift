import Foundation
import GRDB
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Member roles during room recovery")
struct V2MemberRoleRecoveryTests {
    private static let room = RoomID(uuid: UUID(uuidString: "ABCDEF00-0000-0000-0000-000000000801")!)
    private static let viewer = UserID(uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000802")!)
    private static let member = UserID(uuid: UUID(uuidString: "ABCDEF00-0000-0000-0000-000000000803")!)

    @Test("member removal compares the target role rather than the viewer profile", arguments: [2, 4], [1, 10])
    func removalBehindViewerProfile(roleRevision: Int, viewerRevision: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "member-role-recovery-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "client.sqlite")
        let binding = V2LocalInstallationBinding(value: UUID())
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding, userID: Self.viewer)
        let grant = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init(uuid: UUID()), projectionKind: "membership",
            payload: Self.membership(user: Self.viewer, action: "add", revision: viewerRevision))
        _ = try await store.apply(.init(generation: 1, records: [grant], nextSyncToken: .init("grant"),
            receipt: .init("grant"), hasMore: false, capabilityProfile: "base"))
        let role = try V2ClientGroupEvent(sourceEventID: .init(uuid: UUID()), roomSequence: 1,
            projectionKind: "group_capability", payload: JSONSerialization.data(withJSONObject: [
                "event_type": "group.member_role_changed", "room_id": Self.room.rawValue.lowercased(),
                "target_user_id": Self.member.rawValue.lowercased(), "role": "admin", "membership_revision": roleRevision]))
        let removal = try V2ClientGroupEvent(sourceEventID: .init(uuid: UUID()), roomSequence: 2,
            projectionKind: "membership", payload: Self.membership(user: Self.member, action: "remove", revision: 3))
        _ = try await store.applyGroupEventPage(.init(roomID: Self.room, events: [role, removal], nextRoomSequence: 2, hasMore: false))
        #expect(try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_group_member_roles") } == (roleRevision < 3 ? 0 : 1))
        #expect(try await store.roomProfile(roomID: Self.room)?.membershipRevision == UInt64(max(viewerRevision, 3)))
        #expect(try await store.groupEventCursor(roomID: Self.room) == 2)
        // A personal snapshot must preserve the already recovered room state,
        // including the absence of a removed member's role.
        let manifest = try await Self.importSnapshot(store, items: [.init(
            key: .init(projectionKind: "room", entityKey: Self.room.rawValue),
            sourceEventID: grant.sourceEventID, sequence: 1, payload: grant.payload)])
        try await store.prepareSnapshotActivation(manifest)
        try await store.activateAcknowledgedSnapshot(manifest)
        #expect(try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_group_member_roles") } == (roleRevision < 3 ? 0 : 1))
        #expect(try await store.groupEventCursor(roomID: Self.room) == 2)
        try await store.close()
        let reopened = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding, userID: Self.viewer)
        #expect(try await reopened.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_group_member_roles") } == (roleRevision < 3 ? 0 : 1))
        if roleRevision < 3 {
            let stale = try V2ClientGroupEvent(sourceEventID: .init(uuid: UUID()), roomSequence: 3,
                projectionKind: "group_capability", payload: role.payload)
            let conflictingPage = try V2ClientGroupEventPage(roomID: Self.room, events: [stale], nextRoomSequence: 3, hasMore: false)
            await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await reopened.applyGroupEventPage(conflictingPage) }
            #expect(try await reopened.groupEventCursor(roomID: Self.room) == 2)
            var olderPayload = try #require(JSONSerialization.jsonObject(with: role.payload) as? [String: Any])
            olderPayload["membership_revision"] = 1
            let older = try V2ClientGroupEvent(sourceEventID: .init(uuid: UUID()), roomSequence: 3,
                projectionKind: "group_capability", payload: JSONSerialization.data(withJSONObject: olderPayload))
            _ = try await reopened.applyGroupEventPage(.init(roomID: Self.room, events: [older], nextRoomSequence: 3, hasMore: false))
            #expect(try await reopened.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_group_member_roles") } == 0)
        }
        try await reopened.close()
    }

    @Test("role payload must match its room envelope and domain", arguments: ["room", "sequence", "owner", "conflict"])
    func rejectsInvalidRole(scenario: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "member-role-invalid-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "client.sqlite"),
            installationBinding: .init(value: UUID()), userID: Self.viewer)
        var payload: [String: Any] = ["event_type": "group.member_role_changed", "room_id": Self.room.rawValue,
            "target_user_id": Self.member.rawValue, "role": "admin", "membership_revision": 2, "room_sequence": 1]
        func event(_ payload: [String: Any], sequence: UInt64) throws -> V2ClientGroupEvent {
            try .init(sourceEventID: .init(uuid: UUID()), roomSequence: sequence,
                projectionKind: "group_capability", payload: JSONSerialization.data(withJSONObject: payload))
        }
        var sequence: UInt64 = 1
        if scenario == "conflict" {
            _ = try await store.applyGroupEventPage(.init(roomID: Self.room,
                events: [event(payload, sequence: 1)], nextRoomSequence: 1, hasMore: false))
            sequence = 2; payload["role"] = "member"; payload["room_sequence"] = 2
        } else if scenario == "room" {
            payload["room_id"] = RoomID(uuid: UUID()).rawValue
        } else if scenario == "sequence" {
            payload["room_sequence"] = 2
        } else { payload["role"] = "owner" }
        let page = try V2ClientGroupEventPage(roomID: Self.room, events: [event(payload, sequence: sequence)],
            nextRoomSequence: sequence, hasMore: false)
        await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await store.applyGroupEventPage(page) }
        #expect(try await store.groupEventCursor(roomID: Self.room) == (scenario == "conflict" ? 1 : 0))
        let roles = try await store.databasePool.read { try String.fetchAll($0, sql: "SELECT role FROM v2_group_member_roles") }
        #expect(roles == (scenario == "conflict" ? ["admin"] : []))
        try await store.close()
    }

    @Test("member add/remove fences old roles and permits a later role", arguments: ["add", "remove"])
    func memberVersionSurvivesRestart(action: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "member-version-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "client.sqlite")
        let binding = V2LocalInstallationBinding(value: UUID())
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding, userID: Self.viewer)
        func role(_ revision: Int, _ sequence: UInt64) throws -> V2ClientGroupEvent {
            try .init(sourceEventID: .init(uuid: UUID()), roomSequence: sequence, projectionKind: "group_capability",
                payload: JSONSerialization.data(withJSONObject: ["event_type": "group.member_role_changed",
                    "room_id": Self.room.rawValue, "target_user_id": Self.member.rawValue,
                    "role": "admin", "membership_revision": revision]))
        }
        let change = try V2ClientGroupEvent(sourceEventID: .init(uuid: UUID()), roomSequence: 2,
            projectionKind: "membership", payload: Self.membership(user: Self.member, action: action, revision: 3))
        _ = try await store.applyGroupEventPage(.init(roomID: Self.room, events: [role(2, 1), change], nextRoomSequence: 2, hasMore: false))
        #expect(try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_group_member_roles") } == 0)
        try await store.close()
        let reopened = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding, userID: Self.viewer)
        _ = try await reopened.applyGroupEventPage(.init(roomID: Self.room, events: [role(1, 3)], nextRoomSequence: 3, hasMore: false))
        #expect(try await reopened.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_group_member_roles") } == 0)
        _ = try await reopened.applyGroupEventPage(.init(roomID: Self.room, events: [role(4, 4)], nextRoomSequence: 4, hasMore: false))
        #expect(try await reopened.databasePool.read { try Int64.fetchOne($0, sql: "SELECT membership_revision FROM v2_group_member_roles") } == 4)
        // Revoking the viewer erases all room content, but retains the viewer's own revocation fence.
        let revoke = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init(uuid: UUID()), projectionKind: "membership",
            payload: Self.membership(user: Self.viewer, action: "remove", revision: 5))
        _ = try await reopened.apply(.init(generation: 1, records: [revoke], nextSyncToken: .init("removed"),
            receipt: .init("removed"), hasMore: false, capabilityProfile: "base"))
        #expect(try await reopened.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_member_effects") } == 0)
        #expect(try await reopened.databasePool.read { try Int.fetchOne($0, sql: "SELECT is_member FROM v2_room_membership_states") } == 0)
        try await reopened.close()
    }

    @Test("snapshot member history merges removals and rejects conflicting sources", arguments: ["stale", "payload", "source", "sequence"])
    func snapshotMemberHistory(scenario: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "member-snapshot-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "client.sqlite"),
            installationBinding: .init(value: UUID()), userID: Self.viewer)
        let grant = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init(uuid: UUID()), projectionKind: "membership",
            payload: Self.membership(user: Self.viewer, action: "add", revision: 1))
        _ = try await store.apply(.init(generation: 1, records: [grant], nextSyncToken: .init("grant"),
            receipt: .init("grant"), hasMore: false, capabilityProfile: "base"))
        let source = EventID(uuid: UUID())
        var payload: [String: Any] = ["event_type": "group.member_role_changed", "room_id": Self.room.rawValue,
            "target_user_id": Self.member.rawValue, "role": "admin", "membership_revision": 2]
        let role = try V2ClientGroupEvent(sourceEventID: source, roomSequence: 1,
            projectionKind: "group_capability", payload: JSONSerialization.data(withJSONObject: payload))
        let removal = try V2ClientGroupEvent(sourceEventID: .init(uuid: UUID()), roomSequence: 2,
            projectionKind: "membership", payload: Self.membership(user: Self.member, action: "remove", revision: 3))
        _ = try await store.applyGroupEventPage(.init(roomID: Self.room, events: [role, removal], nextRoomSequence: 2, hasMore: false))
        if scenario == "payload" { payload["role"] = "member" }
        if scenario == "sequence" { payload["room_sequence"] = 3 }
        let manifest = try await Self.importSnapshot(store, items: [
            .init(key: .init(projectionKind: "room", entityKey: Self.room.rawValue), sourceEventID: grant.sourceEventID, sequence: 1, payload: grant.payload),
            .init(key: .init(projectionKind: "group_capability", entityKey: "member-role:\(Self.room.rawValue):\(Self.member.rawValue)"),
                sourceEventID: scenario == "source" ? .init(uuid: UUID()) : source, sequence: 8,
                payload: JSONSerialization.data(withJSONObject: payload))
        ])
        if scenario == "stale" {
            try await store.prepareSnapshotActivation(manifest)
            try await store.activateAcknowledgedSnapshot(manifest)
            #expect(try await store.cursor()?.generation == 2)
            // An absent source room sequence is enriched from the retained room log,
            // never from the snapshot's unrelated personal sequence 8.
            #expect(try await store.databasePool.read { try Int64.fetchOne($0, sql: "SELECT room_sequence FROM v2_member_effects WHERE source_event_id = ?", arguments: [source.rawValue]) } == 1)
            #expect(try await store.databasePool.read { try String.fetchOne($0, sql: "SELECT action FROM v2_member_effects WHERE room_id = ? AND user_id = ? ORDER BY membership_revision DESC LIMIT 1", arguments: [Self.room.rawValue, Self.member.rawValue]) } == "remove")
        } else {
            let before = try await store.cursor()
            #expect(before?.state == .resetPending)
            await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await store.prepareSnapshotActivation(manifest) }
            #expect(try await store.cursor() == before)
            #expect(try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_member_effects") } == 3)
        }
        #expect(try await store.groupEventCursor(roomID: Self.room) == 2)
        #expect(try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_group_member_roles") } == 0)
        try await store.close()
    }

    @Test("member history rejects noninteger versions and sequences without advancing", arguments:
        ["history", "membership_revision", "room_sequence", "projection_sequence"], [1.5, Double(Int64.max)])
    func memberStorageTypes(location: String, value: Double) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "member-storage-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "client.sqlite"),
            installationBinding: .init(value: UUID()), userID: Self.viewer)
        func record(_ revision: Int, _ sequence: UInt64, source: EventID = .init(uuid: UUID())) throws -> V2ClientSyncRecord {
            try .init(sequence: sequence, sourceEventID: source, projectionKind: "group_capability",
                payload: JSONSerialization.data(withJSONObject: ["event_type": "group.member_role_changed",
                    "room_id": Self.room.rawValue, "target_user_id": Self.member.rawValue,
                    "role": "admin", "membership_revision": revision, "room_sequence": revision]))
        }
        func apply(_ record: V2ClientSyncRecord) async throws {
            _ = try await store.apply(.init(generation: 1, records: [record], nextSyncToken: .init("member"),
                receipt: .init("member"), hasMore: false, capabilityProfile: "base"))
        }
        let original = try record(2, 1)
        try await apply(original)
        if location == "history" { try await apply(record(4, 2)) }
        let column = location == "history" ? "membership_revision" : location
        let before = try await store.cursor()
        // Keep the effect receipt but remove the separate delivery receipt so a
        // personal redelivery exercises the effect's independent replay checks.
        try await store.databasePool.write { db in
            if location != "history" { try db.execute(sql: "DELETE FROM v2_sync_events") }
            try db.execute(sql: "UPDATE v2_member_effects SET \(column) = ? WHERE source_event_id = ?",
                arguments: [value, original.sourceEventID.rawValue])
        }
        let incoming = try location == "history" ? record(5, 3) : record(2, 2, source: original.sourceEventID)
        await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await apply(incoming) }
        #expect(try await store.cursor() == before)
        let state = try await store.databasePool.read { db in
            let type = try String.fetchOne(db, sql: "SELECT typeof(\(column)) FROM v2_member_effects WHERE source_event_id = ?", arguments: [original.sourceEventID.rawValue])
            let raw = try Double.fetchOne(db, sql: "SELECT \(column) FROM v2_member_effects WHERE source_event_id = ?", arguments: [original.sourceEventID.rawValue])
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_member_effects")
            let role = try Int64.fetchOne(db, sql: "SELECT membership_revision FROM v2_group_member_roles")
            return (type, raw, count, role)
        }
        #expect(state.0 == "real")
        #expect(state.1 == value)
        #expect(state.2 == (location == "history" ? 2 : 1))
        #expect(state.3 == (location == "history" ? 4 : 2))
        try await store.databasePool.write { db in
            try db.execute(sql: "UPDATE v2_member_effects SET \(column) = ? WHERE source_event_id = ?",
                arguments: [column == "projection_sequence" ? 1 : 2, original.sourceEventID.rawValue])
        }
        try await apply(incoming)
        #expect(try await store.cursor()?.appliedSequence == incoming.sequence)
        try await store.close()
    }

    @Test("membership entry checks viewer and room profile storage before applying", arguments:
        ["viewer", "profile"], [1.5, Double(Int64.max)])
    func membershipEntryStorageTypes(location: String, value: Double) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "member-entry-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "client.sqlite"),
            installationBinding: .init(value: UUID()), userID: Self.viewer)
        func batch(_ sequence: UInt64, user: UserID, revision: Int) throws -> V2ClientSyncBatch {
            try .init(generation: 1, records: [.init(sequence: sequence, sourceEventID: .init(uuid: UUID()),
                projectionKind: "membership", payload: Self.membership(user: user, action: "add", revision: revision))],
                nextSyncToken: .init("entry"), receipt: .init("entry"), hasMore: false, capabilityProfile: "base")
        }
        _ = try await store.apply(batch(1, user: Self.viewer, revision: 1))
        let before = try await store.cursor()
        let table = location == "viewer" ? "v2_room_membership_states" : "v2_room_profile_projections"
        try await store.databasePool.write { try $0.execute(sql: "UPDATE \(table) SET membership_revision = ?", arguments: [value]) }
        let incoming = try batch(2, user: location == "viewer" ? Self.viewer : Self.member, revision: 2)
        await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await store.apply(incoming) }
        #expect(try await store.cursor() == before)
        let raw = try await store.databasePool.read { db in
            let value = try Double.fetchOne(db, sql: "SELECT membership_revision FROM \(table)")
            let type = try String.fetchOne(db, sql: "SELECT typeof(membership_revision) FROM \(table)")
            let effects = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_member_effects")
            return (value, type, effects)
        }
        #expect(raw.0 == value)
        #expect(raw.1 == "real")
        #expect(raw.2 == 1)
        try await store.databasePool.write { try $0.execute(sql: "UPDATE \(table) SET membership_revision = 1") }
        _ = try await store.apply(incoming)
        #expect(try await store.cursor()?.appliedSequence == 2)
        #expect(try await store.roomProfile(roomID: Self.room)?.membershipRevision == 2)
        try await store.close()
    }

    @Test("snapshot member history validates integer storage before reducing roles", arguments:
        ["live-membership_revision", "live-room_sequence", "live-projection_sequence", "shadow-membership_revision", "shadow-room_sequence", "shadow-projection_sequence"],
        [1.5, Double(Int64.max)])
    func snapshotMemberStorageTypes(location: String, value: Double) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "member-snapshot-storage-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "client.sqlite"), installationBinding: .init(value: UUID()), userID: Self.viewer)
        let grant = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init(uuid: UUID()), projectionKind: "membership",
            payload: Self.membership(user: Self.viewer, action: "add", revision: 1))
        let role = try V2ClientSyncRecord(sequence: 2, sourceEventID: .init(uuid: UUID()), projectionKind: "group_capability",
            payload: JSONSerialization.data(withJSONObject: ["event_type": "group.member_role_changed", "room_id": Self.room.rawValue,
                "target_user_id": Self.member.rawValue, "role": "admin", "membership_revision": 2, "room_sequence": 10]))
        _ = try await store.apply(.init(generation: 1, records: [grant, role], nextSyncToken: .init("members"), receipt: .init("members"), hasMore: false, capabilityProfile: "base"))
        let removal = try V2ClientGroupEvent(sourceEventID: .init(uuid: UUID()), roomSequence: 20, projectionKind: "membership",
            payload: Self.membership(user: Self.member, action: "remove", revision: 3))
        _ = try await store.applyGroupEventPage(.init(roomID: Self.room, events: [removal], nextRoomSequence: 20, hasMore: false))
        let manifest = try await Self.importSnapshot(store, items: [
            .init(key: .init(projectionKind: "room", entityKey: Self.room.rawValue), sourceEventID: grant.sourceEventID, sequence: 1, payload: grant.payload),
            .init(key: .init(projectionKind: "group_capability", entityKey: "member-role:\(Self.room.rawValue):\(Self.member.rawValue)"), sourceEventID: role.sourceEventID, sequence: 8, payload: role.payload)
        ])
        let shadow = location.hasPrefix("shadow-")
        let table = shadow ? "v2_snapshot_shadow_member_effects" : "v2_member_effects"
        let column = String(location.split(separator: "-", maxSplits: 1)[1])
        let cursor = try await store.cursor()
        let original = try await store.databasePool.write { db in
            let original = try #require(try Int64.fetchOne(db, sql: "SELECT \(column) FROM \(table) WHERE source_event_id = ?", arguments: [role.sourceEventID.rawValue]))
            try db.execute(sql: "UPDATE \(table) SET \(column) = ? WHERE source_event_id = ?", arguments: [value, role.sourceEventID.rawValue])
            return original
        }
        await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await store.prepareSnapshotActivation(manifest) }
        #expect(try await store.cursor() == cursor)
        #expect(try await store.groupEventCursor(roomID: Self.room) == 20)
        let state = try await store.databasePool.read { db in
            let raw = try Double.fetchOne(db, sql: "SELECT \(column) FROM \(table) WHERE source_event_id = ?", arguments: [role.sourceEventID.rawValue])
            let type = try String.fetchOne(db, sql: "SELECT typeof(\(column)) FROM \(table) WHERE source_event_id = ?", arguments: [role.sourceEventID.rawValue])
            let roles = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_group_member_roles")
            let prepared = try Bool.fetchOne(db, sql: "SELECT activation_prepared FROM v2_snapshot_import")
            return (raw, type, roles, prepared)
        }
        #expect(state.0 == value)
        #expect(state.1 == "real")
        #expect(state.2 == 0)
        #expect(state.3 == false)
        try await store.databasePool.write { try $0.execute(sql: "UPDATE \(table) SET \(column) = ? WHERE source_event_id = ?", arguments: [original, role.sourceEventID.rawValue]) }
        try await store.prepareSnapshotActivation(manifest)
        try await store.activateAcknowledgedSnapshot(manifest)
        #expect(try await store.cursor()?.generation == 2)
        #expect(try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_group_member_roles") } == 0)
        #expect(try await store.groupEventCursor(roomID: Self.room) == 20)
        try await store.close()
    }

    private static func importSnapshot(_ store: GRDBV2LocalSyncStore, items: [V2SnapshotProjectionItem]) async throws -> V2ClientSnapshotManifest {
        let projection = try V2SnapshotProjectionV3Page(items: items.sorted { $0.key < $1.key })
        let encoded = try V2SnapshotProjectionV3Codec.encode(projection)
        let initial = V2SnapshotV3Digest.initial(baseSequence: 10, capabilityProfile: "base")
        let digest = V2SnapshotV3Digest.page(encoded)
        let manifest = try V2ClientSnapshotManifest(reset: .init(snapshotID: .init(uuid: UUID()),
            generation: 2, baseSequence: 10, expiresAt: .distantFuture),
            rootDigest: V2SnapshotV3Digest.next(previous: initial, pageIndex: 0, pageDigest: digest,
                firstKey: projection.firstKey, lastKey: projection.lastKey, itemCount: UInt32(items.count)),
            pageCount: 1, totalItems: UInt64(items.count), totalBytes: UInt64(encoded.count),
            nextSyncToken: .init("snapshot"), receipt: .init("snapshot"), capabilityProfile: "base")
        try await store.beginReset(manifest.reset)
        try await store.beginSnapshotImport(manifest, initialDigest: initial)
        try await store.applySnapshotPage(.init(index: 0, digest: digest,
            firstKey: projection.firstKey, lastKey: projection.lastKey, itemCount: items.count, payload: encoded), for: manifest)
        return manifest
    }

    private static func membership(user: UserID, action: String, revision: Int) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["event_type": "membership_changed", "room_id": room.rawValue,
            "target_user_id": user.rawValue, "action": action, "membership_revision": revision,
            "title": "Recovery", "owner_user_id": viewer.rawValue, "capacity_class": "standard",
            "created_at_ms": 1000, "server_created_at_ms": revision * 1000])
    }
}
