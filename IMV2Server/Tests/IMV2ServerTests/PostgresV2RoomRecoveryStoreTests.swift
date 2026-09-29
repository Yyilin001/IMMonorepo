@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

@Suite("Identity-indexed room recovery", .serialized)
struct PostgresV2RoomRecoveryStoreTests {
    @Test("parameterized membership lookup must not hide duplicate active revisions")
    func duplicateActiveMembership() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let user = UUID(), room = UUID()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).rooms(room_id,room_shard_id,capacity_profile_id,membership_revision)
                VALUES (\(bind: room),'room-a','standard',2)
                """).run()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).room_memberships(room_id,user_id,joined_revision)
                VALUES (\(bind: room),\(bind: user),1),(\(bind: room),\(bind: user),2)
                """).run()
            let store = try PostgresV2RoomRecoveryStore(database: database, schema: schema)
            await #expect(throws: V2RoomRecoveryReadError.corruptPersistence) {
                try await store.states(roomIDs: [.init(uuid: room)], actorUserID: .init(uuid: user))
            }
        }
    }

    @Test("large identity directories recover every room while activity changes", arguments: [1000, 10000])
    func largeDirectory(count: Int) async throws {
        try await withUserEventDatabase { db, sql, schema in
            let user = UUID(), actor = UserID(uuid: user)
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).rooms
                    (room_id, room_shard_id, capacity_profile_id, membership_revision)
                SELECT ('00000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid,
                       'room-a', 'standard', 1
                FROM generate_series(1, \(bind: count)) AS n
                """).run()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).room_memberships(room_id, user_id, joined_revision)
                SELECT room_id, \(bind: user), 1 FROM \(unsafeRaw: schema).rooms
                """).run()
            try await sql.raw("ANALYZE \(unsafeRaw: schema).room_memberships").run()
            try await sql.raw("ANALYZE \(unsafeRaw: schema).rooms").run()
            let store = try PostgresV2RoomRecoveryStore(database: db, schema: schema)
            var after: RoomID?, seen: Set<RoomID> = []
            var pages = 0, stateBatches = 0
            let start = ContinuousClock.now
            while true {
                let page = try await store.rooms(actorUserID: actor, after: after, limit: 100)
                pages += 1
                #expect(page.entries.count <= 100)
                #expect(pages <= count / 100)
                guard pages <= count / 100 else { throw V2RoomRecoveryReadError.corruptPersistence }
                let ids = page.entries.map(\.roomID)
                #expect(ids.count == 100)
                #expect(Set(ids).isDisjoint(with: seen))
                seen.formUnion(ids)
                let states = try await store.states(roomIDs: ids, actorUserID: actor)
                stateBatches += 1
                #expect(states.count == ids.count)
                for id in ids {
                    guard case .state(let state)? = states[id] else {
                        Issue.record("authorized room missing from state batch")
                        continue
                    }
                    #expect(state.head == 0 && state.viewerMembershipRevision == 1)
                }
                if pages == 1 {
                    // Ranking changes both before and after the scan cursor.
                    // Identity pagination must neither repeat nor omit rooms.
                    try await sql.raw("""
                        UPDATE \(unsafeRaw: schema).rooms
                        SET last_event_at = TIMESTAMPTZ '2026-01-01' + random() * INTERVAL '1 day'
                        """).run()
                }
                if !page.hasMore { break }
                let next = try #require(page.scannedThrough)
                #expect(next != after)
                after = next
            }
            #expect(seen.count == count)
            #expect(pages == count / 100 && stateBatches == pages)
            print("ROOM_RECOVERY_DATABASE_SCALE rooms=\(count) directoryPages=\(pages) stateBatches=\(stateBatches) elapsed=\(start.duration(to: .now))")
        }
    }

    @Test("directory order ignores activity and advances across invisible candidates")
    func directoryPages() async throws {
        try await withUserEventDatabase { db, sql, schema in
            let user = UUID()
            let rooms = (1...3).map { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))! }
            for (index, room) in rooms.enumerated() {
                try await sql.raw("""
                    INSERT INTO \(unsafeRaw: schema).rooms
                        (room_id, room_shard_id, capacity_profile_id, membership_revision, last_event_at)
                    VALUES (\(bind: room), 'room-a', 'standard', 1, \(bind: Date(timeIntervalSince1970: Double(100 - index))))
                    """).run()
                // A candidate ahead of the room's committed revision must not become authorized.
                try await sql.raw("""
                    INSERT INTO \(unsafeRaw: schema).room_memberships(room_id, user_id, joined_revision)
                    VALUES (\(bind: room), \(bind: user), \(bind: index == 1 ? 2 : 1))
                    """).run()
            }
            let store = try PostgresV2RoomRecoveryStore(database: db, schema: schema)
            let first = try await store.rooms(actorUserID: .init(uuid: user), after: nil, limit: 1)
            #expect(first.entries.map(\.roomID) == [.init(uuid: rooms[0])])
            #expect(first.hasMore)
            let second = try await store.rooms(actorUserID: .init(uuid: user), after: first.scannedThrough, limit: 1)
            #expect(second.entries.isEmpty)
            #expect(second.scannedThrough == .init(uuid: rooms[1]))
            #expect(second.hasMore)
            let third = try await store.rooms(actorUserID: .init(uuid: user), after: second.scannedThrough, limit: 1)
            #expect(third.entries.map(\.roomID) == [.init(uuid: rooms[2])])
            #expect(!third.hasMore)
            let stranger = try await store.rooms(actorUserID: .init(uuid: UUID()), after: nil, limit: 100)
            #expect(stranger.entries.isEmpty && !stranger.hasMore)
        }
    }

    @Test("state batches distinguish unavailable from authorized zero and reject invalid bounds")
    func stateAuthorization() async throws {
        try await withUserEventDatabase { db, sql, schema in
            let user = UUID(), room = UUID(), missing = RoomID(uuid: UUID())
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).rooms(room_id, room_shard_id, capacity_profile_id, membership_revision)
                VALUES (\(bind: room), 'room-a', 'standard', 1)
                """).run()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).room_memberships(room_id, user_id, joined_revision)
                VALUES (\(bind: room), \(bind: user), 1)
                """).run()
            let id = RoomID(uuid: room), actor = UserID(uuid: user)
            let store = try PostgresV2RoomRecoveryStore(database: db, schema: schema)
            let result = try await store.states(roomIDs: [id, missing, id], actorUserID: actor)
            #expect(result.count == 2)
            #expect(result[missing] == .unavailable)
            let expected = try V2RoomSynchronizationState(roomID: id, ownerEpoch: 0, viewerMembershipRevision: 1,
                head: 0, trimmedThrough: 0, readThrough: 0, latestOwnMessageSequence: 0)
            #expect(result[id] == .state(expected))
            try await sql.raw("UPDATE \(unsafeRaw: schema).room_memberships SET left_revision = 2 WHERE room_id = \(bind: room)").run()
            #expect(try await store.states(roomIDs: [id], actorUserID: actor)[id] == .unavailable)
            await #expect(throws: V2RoomRecoveryReadError.invalidRequest) {
                try await store.states(roomIDs: [], actorUserID: actor)
            }
            await #expect(throws: V2RoomRecoveryReadError.invalidRequest) {
                try await store.rooms(actorUserID: actor, after: nil, limit: 101)
            }
        }
    }
}
