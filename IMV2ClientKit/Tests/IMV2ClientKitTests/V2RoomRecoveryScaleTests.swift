import Foundation
import GRDB
import IMV2Core
@testable import IMV2ClientKit
import Testing

/// Explicit scale gate: production recovery and SQLite, deterministic network boundary.
@Suite("Room recovery SQLite scale", .timeLimit(.minutes(10)))
struct V2RoomRecoveryScaleTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_CLIENT_RECOVERY_SCALE"] == "1"), arguments: [1_000, 10_000])
    func durableNonemptyRooms(count: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "room-scale-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "client.sqlite")
        let binding = V2LocalInstallationBinding(value: UUID())
        let user = UserID(uuid: UUID())
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding, userID: user)
        try await store.databasePool.write {
            try $0.execute(sql: "INSERT INTO v2_sync_cursor(singleton,state,generation,applied_sequence,server_acknowledged_sequence,sync_token) VALUES(1,'ready',1,0,0,'initial')")
        }
        let wire = ScaleRecoveryWire(count: count)
        let engine = V2RoomRecoveryEngine(transport: wire, latestVisible: wire, store: store,
            groupEvents: V2GroupEventSyncEngine(transport: wire, store: store))
        let start = ContinuousClock.now
        var rounds = 0
        while rounds < count {
            _ = try await engine.runBudget(userID: user, maximumDirectoryPages: 1, maximumRooms: 100)
            rounds += 1
            let progress = try await engine.progress()
            if progress.directoryComplete && progress.pendingRoomCount == 0 { break }
        }
        #expect(rounds < count)
        let progress = try await engine.progress()
        #expect(progress.directoryComplete && progress.pendingRoomCount == 0)
        await engine.stop()
        try await verify(store, count: count)
        try await store.databasePool.close()
        let reopened = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding, userID: user)
        try await verify(reopened, count: count)
        try await reopened.databasePool.close()
        #expect(await wire.directoryPages == count / 100)
        #expect(await wire.contentPulls == count)
        print("IMV2_CLIENT_RECOVERY_SCALE rooms=\(count) rounds=\(rounds) elapsed=\(start.duration(to: .now))")
    }

    private func verify(_ store: GRDBV2LocalSyncStore, count: Int) async throws {
        let counts = try await store.databasePool.read { db in
            try [
                Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_message_projections WHERE text_body = 'scale-message'"),
                Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_group_event_cursors WHERE applied_room_sequence = 1 AND history_incomplete = 0"),
                Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_room_sync_states"),
                Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_room_recovery_work")
            ]
        }
        #expect(counts == [count, count, count, 0])
    }
}

private actor ScaleRecoveryWire: V2ClientRoomRecoveryTransport, V2ClientGroupEventTransport, V2ClientRoomLatestVisibleTransport {
    let rooms: [RoomID]
    let sender = UserID(uuid: UUID())
    private(set) var directoryPages = 0
    private(set) var contentPulls = 0
    init(count: Int) { rooms = (0..<count).map { _ in RoomID(uuid: UUID()) } }
    func startAccountRoomChanges() -> UUID { UUID() }
    func userRoomDirectory(cursor: String?, pageSize: Int) throws -> V2ClientUserRoomPage {
        #expect(pageSize <= 100)
        let offset = cursor.flatMap(Int.init) ?? 0
        let end = min(rooms.count, offset + pageSize)
        directoryPages += 1
        return try .init(rooms: rooms[offset..<end].map {
            try .init(roomID: $0, kind: .group, viewerMembershipRevision: 1, ownerEpoch: 1)
        }, nextCursor: end < rooms.count ? String(end) : nil, topologyGeneration: "scale")
    }
    func roomSyncStates(roomIDs: [RoomID]) throws -> [RoomID: V2ClientRoomStateResult] {
        #expect(roomIDs.count <= 100)
        return try Dictionary(uniqueKeysWithValues: roomIDs.map {
            ($0, .state(try .init(roomID: $0, ownerEpoch: 1, viewerMembershipRevision: 1,
                head: 1, trimmedThrough: 0, readThrough: 0, latestOwnMessageSequence: 0)))
        })
    }
    func latestVisible(roomIDs: [RoomID]) throws -> [RoomID: V2ClientRoomLatestVisibleResult] {
        #expect(roomIDs.count <= 100)
        return try Dictionary(uniqueKeysWithValues: roomIDs.map {
            ($0, .snapshot(try .init(roomID: $0, ownerEpoch: 1, membershipRevision: 1, head: 1,
                latest: .init(id: .init($0.rawValue), senderID: sender, sequence: 1, revision: 1,
                    preview: "scale-message", mediaCount: 0, createdAt: Date(timeIntervalSince1970: 1_750_000_000)))))
        })
    }
    func pullGroupEvents(roomID: RoomID, afterRoomSequence: UInt64, pageSize: Int) throws -> V2ClientGroupEventPage {
        contentPulls += 1
        #expect(afterRoomSequence == 0)
        let payload = try JSONSerialization.data(withJSONObject: [
            "event_type": "message.accepted", "room_id": roomID.rawValue,
            "room_sequence": 1, "message_id": roomID.rawValue, "message_revision": 1,
            "sender_user_id": sender.rawValue, "text": "scale-message",
            "server_created_at_ms": 1_750_000_000_000
        ])
        return try .init(roomID: roomID, events: [.init(sourceEventID: .init(roomID.rawValue),
            roomSequence: 1, projectionKind: "message", payload: payload)], nextRoomSequence: 1, hasMore: false)
    }
}
