@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
@testable import IMV2ServerInfrastructure
import Foundation
import IMV2Core
import SQLKit
import Testing

@Suite("Authoritative directory statement snapshot", .serialized)
struct PostgresV2AuthoritativeDirectoryTests {
    @Test("one SQL returns membership, routes and generation; empty and filtered pages retain exact scan position")
    func boundedSnapshot() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let user = UUID()
            let rooms = (1...3).map { UUID(uuidString: "00000000-0000-0000-0000-00000000000\($0)")! }
            for (index, room) in rooms.enumerated() {
                try await sql.raw("""
                    INSERT INTO \(unsafeRaw: schema).rooms
                      (room_id,room_kind,room_shard_id,capacity_profile_id,membership_revision,owner_epoch)
                    VALUES (\(bind: room),'group','a','standard',1,1)
                    """).run()
                try await sql.raw("""
                    INSERT INTO \(unsafeRaw: schema).room_memberships(room_id,user_id,joined_revision)
                    VALUES (\(bind: room),\(bind: user),1)
                    """).run()
                try await sql.raw("""
                    INSERT INTO \(unsafeRaw: schema).room_owner_routes(room_id,room_shard_id,route_epoch,created_at,updated_at)
                    VALUES (\(bind: room),\(bind: index == 1 ? "b" : "a"),1,now(),now())
                    """).run()
            }
            let recorder = RecoveryQueryRecorder(database: database, sql: sql)
            let store = try PostgresV2RoomRecoveryStore(database: recorder, schema: schema)
            let source = try PostgresV2RoomRecoveryTopology(database: recorder, schema: schema,
                stores: [store], orderedStoreIdentities: ["same-physical-store"],
                atomicStores: [0: .init(store: store, shardIDs: ["a"])])
            let first = try await source.snapshot(actorUserID: .init(uuid: user), after: nil, limit: 1, storeIndex: 0)
            #expect(recorder.snapshot().queries.count == 1)
            #expect(first.slice.entries.map(\.roomID) == [.init(uuid: rooms[0])])
            #expect(first.slice.scannedThrough == .init(uuid: rooms[0]) && first.slice.hasMore)
            let filtered = try await source.snapshot(actorUserID: .init(uuid: user), after: first.slice.scannedThrough, limit: 1, storeIndex: 0)
            #expect(filtered.slice.entries.isEmpty && filtered.slice.hasMore)
            #expect(filtered.slice.scannedThrough == .init(uuid: rooms[1]))
            let last = try await source.snapshot(actorUserID: .init(uuid: user), after: filtered.slice.scannedThrough, limit: 1, storeIndex: 0)
            #expect(last.slice.entries.map(\.roomID) == [.init(uuid: rooms[2])])
            #expect(!last.slice.hasMore && last.generation == first.generation)
            let empty = try await source.snapshot(actorUserID: .init(uuid: UUID()), after: nil, limit: 10, storeIndex: 0)
            #expect(empty.slice.entries.isEmpty && empty.slice.scannedThrough == nil && !empty.slice.hasMore)
            #expect(empty.generation == first.generation)
            #expect(recorder.snapshot().queries.count == 4)
            // A stale physical room epoch cannot be returned as authorized.
            try await sql.raw("UPDATE \(unsafeRaw: schema).room_owner_routes SET route_epoch=2 WHERE room_id=\(bind: rooms[0])").run()
            await #expect(throws: V2RoomRecoveryReadError.topologyChanged) {
                try await source.snapshot(actorUserID: .init(uuid: user), after: nil, limit: 1, storeIndex: 0)
            }
            try await sql.raw("DELETE FROM \(unsafeRaw: schema).room_owner_routes WHERE room_id=\(bind: rooms[0])").run()
            await #expect(throws: V2RoomShardRouteError.roomNotFound) {
                try await source.snapshot(actorUserID: .init(uuid: user), after: nil, limit: 1, storeIndex: 0)
            }
            try await sql.raw("DELETE FROM \(unsafeRaw: schema).room_recovery_topology").run()
            await #expect(throws: V2RoomRecoveryReadError.corruptPersistence) {
                try await source.snapshot(actorUserID: .init(uuid: UUID()), after: nil, limit: 1, storeIndex: 0)
            }
            print("AUTHORITATIVE_DIRECTORY_VERIFIED queriesPerPage=1 emptyGeneration=true filteredCursor=true missingFenceRejected=true")
        }
    }
    @Test("a signed cursor is rejected when the authoritative statement reports a new topology")
    func cursorUsesReturnedGeneration() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let user = UserID(uuid: UUID()), room = UUID()
            let store = try PostgresV2RoomRecoveryStore(database: database, schema: schema)
            let source = try PostgresV2RoomRecoveryTopology(database: database, schema: schema,
                stores: [store], orderedStoreIdentities: ["cursor-store"],
                atomicStores: [0: .init(store: store, shardIDs: ["a"])])
            let codec = try V2UserRoomDirectoryCursorCodec(key: Data(repeating: 7, count: 32))
            let before = try await source.snapshot(actorUserID: user, after: nil, limit: 1, storeIndex: 0)
            let cursor = try codec.encode(userID: user, topologyGeneration: before.generation, storeIndex: 0, after: nil)
            try await sql.raw("INSERT INTO \(unsafeRaw: schema).room_owner_routes(room_id,room_shard_id,route_epoch,created_at,updated_at) VALUES (\(bind: room),'a',3,now(),now())").run()
            let service = V2UserRoomDirectoryService(snapshotSource: source, cursorCodec: codec)
            await #expect(throws: V2RoomRecoveryReadError.topologyChanged) {
                try await service.list(actorUserID: user, cursor: cursor, pageSize: 1)
            }
        }
    }
}
