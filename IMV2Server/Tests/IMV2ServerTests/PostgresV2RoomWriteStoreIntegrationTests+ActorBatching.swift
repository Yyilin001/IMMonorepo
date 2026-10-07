@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import FluentKit
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import SQLKit
import Synchronization
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("configured owner fence locks the full reverse-ordered room set and rejects route or kind drift")
    func configuredTwoRoomFence() async throws {
        try await withForwardOwnerDatabases(mode: .large) { database, _, sql, _, _ in
            let peer = RoomID(uuid: UUID())
            try await actorBatchSeedPeerRoom(peer, on: sql)
            let leases = PostgresV2RoomActivationStore(database: database)
            let first = try await actorBatchLease(leases, room: roomID)
            let second = try await actorBatchLease(leases, room: peer)
            let roomIDs = try [roomID, peer].map { try #require($0.uuidValue) }
                .sorted { $0.uuidString > $1.uuidString }
            let scope = try V2RoomActivationWriteScope(tokens: [first, second])
            let route = try V2RoomShardRoute(shardID: "room-a", epoch: 0)
            let routes = Dictionary(uniqueKeysWithValues: roomIDs.map { ($0, route) })
            let kinds = Dictionary(uniqueKeysWithValues: roomIDs.map { ($0, "group") })
            let unusedAfterSuccess = Mutex<V2ConfiguredRoomFenceContext?>(nil)
            try await v2WithRoomActivationTransactionWithContext(
                database: database, deadline: .now + .seconds(3)) { _, context in
                unusedAfterSuccess.withLock { $0 = context }
            }
            let endedUnused = try #require(unusedAfterSuccess.withLock { $0 })
            await #expect(throws: V2RoomActivationLeaseError.activationChanged) {
                try await endedUnused.requireSelectedOwnersAndActivations(
                    roomIDs: roomIDs, expectedRoutes: routes,
                    expectedKinds: kinds, scope: scope)
            }
            let unusedAfterThrow = Mutex<V2ConfiguredRoomFenceContext?>(nil)
            await #expect(throws: V2RoomActivationLeaseError.ownerChanged) {
                let _: Void = try await v2WithRoomActivationTransactionWithContext(
                    database: database, deadline: .now + .seconds(3)) { _, context in
                    unusedAfterThrow.withLock { $0 = context }
                    throw V2RoomActivationLeaseError.ownerChanged
                }
            }
            let rolledBackUnused = try #require(unusedAfterThrow.withLock { $0 })
            await #expect(throws: V2RoomActivationLeaseError.activationChanged) {
                try await rolledBackUnused.requireSelectedOwnersAndActivations(
                    roomIDs: roomIDs, expectedRoutes: routes,
                    expectedKinds: kinds, scope: scope)
            }
            let escaped = Mutex<V2ConfiguredRoomFenceContext?>(nil)
            try await v2WithRoomActivationTransactionWithContext(
                database: database, deadline: .now + .seconds(3)) { _, context in
                try await context.requireSelectedOwnersAndActivations(
                    roomIDs: roomIDs, expectedRoutes: routes,
                    expectedKinds: kinds, scope: scope)
                escaped.withLock { $0 = context }
            }
            let ended = try #require(escaped.withLock { $0 })
            await #expect(throws: V2RoomActivationLeaseError.activationChanged) {
                try await ended.requireSelectedOwnersAndActivations(
                    roomIDs: roomIDs, expectedRoutes: routes,
                    expectedKinds: kinds, scope: scope)
            }
            let different = try V2RoomActivationSQLTimeouts(lockMilliseconds: 75,
                statementMilliseconds: 250, idleTransactionMilliseconds: 400)
            let settings: ActorBatchTimeoutSettings = try await v2WithRoomActivationTransactionWithContext(
                database: database, deadline: .now + .seconds(3)) { borrowed, context in
                try await context.requireSelectedOwnersAndActivations(
                    roomIDs: roomIDs, expectedRoutes: routes,
                    expectedKinds: kinds, scope: scope, timeouts: different)
                let borrowedSQL = try #require(borrowed as? any SQLDatabase)
                return try #require(try await borrowedSQL.raw("""
                    SELECT current_setting('lock_timeout') AS lock_timeout,
                           current_setting('statement_timeout') AS statement_timeout,
                           current_setting('idle_in_transaction_session_timeout') AS idle_timeout
                    """).first(decoding: ActorBatchTimeoutSettings.self))
            }
            #expect(settings.lockTimeout == "75ms")
            #expect(settings.statementTimeout == "250ms")
            #expect(settings.idleTimeout == "400ms")
            var badKinds = kinds
            badKinds[roomIDs[0]] = "direct"
            let kindMismatch = badKinds
            await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) {
                try await v2WithRoomActivationTransactionWithContext(
                    database: database, deadline: .now + .seconds(3)) { _, context in
                    try await context.requireSelectedOwnersAndActivations(
                        roomIDs: roomIDs, expectedRoutes: routes,
                        expectedKinds: kindMismatch, scope: scope)
                }
            }
            var badRoutes = routes
            badRoutes[roomIDs[0]] = try V2RoomShardRoute(shardID: "room-a", epoch: 1)
            let routeMismatch = badRoutes
            await #expect(throws: V2RoomOwnerFenceError.ownerChanged) {
                try await v2WithRoomActivationTransactionWithContext(
                    database: database, deadline: .now + .seconds(3)) { _, context in
                    try await context.requireSelectedOwnersAndActivations(
                        roomIDs: roomIDs, expectedRoutes: routeMismatch,
                        expectedKinds: kinds, scope: scope)
                }
            }
            try await sql.raw("""
                UPDATE im_v2.room_activation_leases
                SET expires_at = clock_timestamp() - interval '1 second'
                WHERE room_id = \(bind: roomIDs[0])
                """).run()
            await #expect(throws: V2RoomActivationLeaseError.leaseExpired) {
                try await v2WithRoomActivationTransactionWithContext(
                    database: database, deadline: .now + .seconds(3)) { _, context in
                    try await context.requireSelectedOwnersAndActivations(
                        roomIDs: roomIDs, expectedRoutes: routes,
                        expectedKinds: kinds, scope: scope)
                }
            }
            #expect(try await count("im_v2.messages", on: sql) == 0)
            let valid = first.roomID.uuidValue == roomIDs[0] ? second : first
            #expect(try await leases.release(token: valid))
        }
    }

    @Test("configured single-room fence preserves owner, route, kind and exact lease errors",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"
              && ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"] != nil
              && ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_SECONDARY_DATABASE_URL"] != nil))
    func configuredSingleRoomFence() async throws {
        try await withForwardOwnerDatabases(mode: .large) { database, _, sql, _, _ in
            let room = try #require(roomID.uuidValue)
            let leases = PostgresV2RoomActivationStore(database: database)
            let token = try await actorBatchLease(leases, room: roomID)
            let scope = try V2RoomActivationWriteScope(tokens: [token])
            let route = try V2RoomShardRoute(shardID: "room-a", epoch: 0)
            let routes = [room: route]
            let kinds = [room: "group"]

            try await v2WithRoomActivationTransactionWithContext(
                database: database, deadline: .now + .seconds(3)) { _, context in
                try await context.requireSelectedOwnersAndActivations(
                    roomIDs: [room], expectedRoutes: routes,
                    expectedKinds: kinds, scope: scope)
            }
            let different = try V2RoomActivationSQLTimeouts(lockMilliseconds: 75,
                statementMilliseconds: 250, idleTransactionMilliseconds: 400)
            let settings: ActorBatchTimeoutSettings = try await v2WithRoomActivationTransactionWithContext(
                database: database, deadline: .now + .seconds(3)) { borrowed, context in
                try await context.requireSelectedOwnersAndActivations(
                    roomIDs: [room], expectedRoutes: routes,
                    expectedKinds: kinds, scope: scope, timeouts: different)
                let borrowedSQL = try #require(borrowed as? any SQLDatabase)
                return try #require(try await borrowedSQL.raw("""
                    SELECT current_setting('lock_timeout') AS lock_timeout,
                           current_setting('statement_timeout') AS statement_timeout,
                           current_setting('idle_in_transaction_session_timeout') AS idle_timeout
                    """).first(decoding: ActorBatchTimeoutSettings.self))
            }
            #expect(settings.lockTimeout == "75ms")
            #expect(settings.statementTimeout == "250ms")
            #expect(settings.idleTimeout == "400ms")
            let missingRoute: [UUID: V2RoomShardRoute] = [:]
            await #expect(throws: V2RoomOwnerFenceError.ownerChanged) {
                try await v2WithRoomActivationTransactionWithContext(
                    database: database, deadline: .now + .seconds(3)) { _, context in
                    try await context.requireSelectedOwnersAndActivations(
                        roomIDs: [room], expectedRoutes: missingRoute,
                        expectedKinds: kinds, scope: scope)
                }
            }
            let driftedKinds = [room: "direct"]
            let driftedRoute = try V2RoomShardRoute(shardID: "room-a", epoch: 1)
            let driftedRoutes = [room: driftedRoute]
            await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) {
                try await v2WithRoomActivationTransactionWithContext(
                    database: database, deadline: .now + .seconds(3)) { _, context in
                    try await context.requireSelectedOwnersAndActivations(
                        roomIDs: [room], expectedRoutes: driftedRoutes,
                        expectedKinds: driftedKinds, scope: scope)
                }
            }
            await #expect(throws: V2RoomOwnerFenceError.ownerChanged) {
                try await v2WithRoomActivationTransactionWithContext(
                    database: database, deadline: .now + .seconds(3)) { _, context in
                    try await context.requireSelectedOwnersAndActivations(
                        roomIDs: [room], expectedRoutes: driftedRoutes,
                        expectedKinds: kinds, scope: scope)
                }
            }

            let missingRoom = RoomID(uuid: UUID())
            let missingID = try #require(missingRoom.uuidValue)
            let missingToken = V2RoomActivationToken(roomID: missingRoom, owner: token.owner,
                activationEpoch: token.activationEpoch, host: token.host)
            let missingScope = try V2RoomActivationWriteScope(tokens: [missingToken])
            await #expect(throws: V2RoomActivationLeaseError.roomNotFound) {
                try await v2WithRoomActivationTransactionWithContext(
                    database: database, deadline: .now + .seconds(3)) { _, context in
                    try await context.requireSelectedOwnersAndActivations(
                        roomIDs: [missingID], expectedRoutes: nil,
                        expectedKinds: nil, scope: missingScope)
                }
            }
            let missingRoomRoute = [missingID: route]
            await #expect(throws: V2RoomOwnerFenceError.ownerChanged) {
                try await v2WithRoomActivationTransactionWithContext(
                    database: database, deadline: .now + .seconds(3)) { _, context in
                    try await context.requireSelectedOwnersAndActivations(
                        roomIDs: [missingID], expectedRoutes: missingRoomRoute,
                        expectedKinds: nil, scope: missingScope)
                }
            }
            await #expect(throws: V2RoomActivationLeaseError.activationChanged) {
                try await v2WithRoomActivationTransactionWithContext(
                    database: database, deadline: .now + .seconds(3)) { _, context in
                    try await context.requireSelectedOwnersAndActivations(
                        roomIDs: [room], expectedRoutes: routes,
                        expectedKinds: kinds, scope: missingScope)
                }
            }
            let differentOwner = try V2RoomDataOwner(shardID: "room-a", epoch: 1)
            let wrongOwnerToken = V2RoomActivationToken(roomID: roomID, owner: differentOwner,
                activationEpoch: token.activationEpoch, host: token.host)
            let wrongOwnerScope = try V2RoomActivationWriteScope(tokens: [wrongOwnerToken])
            await #expect(throws: V2RoomActivationLeaseError.ownerChanged) {
                try await v2WithRoomActivationTransactionWithContext(
                    database: database, deadline: .now + .seconds(3)) { _, context in
                    try await context.requireSelectedOwnersAndActivations(
                        roomIDs: [room], expectedRoutes: routes,
                        expectedKinds: kinds, scope: wrongOwnerScope)
                }
            }

            #expect(try await leases.release(token: token))
            let successor = try await actorBatchLease(leases, room: roomID)
            await #expect(throws: V2RoomActivationLeaseError.activationChanged) {
                try await v2WithRoomActivationTransactionWithContext(
                    database: database, deadline: .now + .seconds(3)) { _, context in
                    try await context.requireSelectedOwnersAndActivations(
                        roomIDs: [room], expectedRoutes: routes,
                        expectedKinds: kinds, scope: scope)
                }
            }
            let currentScope = try V2RoomActivationWriteScope(tokens: [successor])
            try await sql.raw("""
                UPDATE im_v2.room_activation_leases
                SET expires_at = clock_timestamp() - interval '1 second'
                WHERE room_id = \(bind: room)
                """).run()
            await #expect(throws: V2RoomActivationLeaseError.leaseExpired) {
                try await v2WithRoomActivationTransactionWithContext(
                    database: database, deadline: .now + .seconds(3)) { _, context in
                    try await context.requireSelectedOwnersAndActivations(
                        roomIDs: [room], expectedRoutes: routes,
                        expectedKinds: kinds, scope: currentScope)
                }
            }
            #expect(try await count("im_v2.messages", on: sql) == 0)
        }
    }



    private func actorBatchLease(_ leases: PostgresV2RoomActivationStore, room: RoomID) async throws -> V2RoomActivationToken {
        let owner = try V2RoomDataOwner(shardID: "room-a", epoch: 0)
        let host = V2ActorHostIdentity(hostID: try .init("batch-host"), incarnationID: UUID())
        guard case .acquired(let lease) = try await leases.acquire(roomID: room,
            owner: owner, host: host, duration: .init(30_000)) else {
            throw V2RoomActivationLeaseError.activationChanged
        }
        return lease.token
    }





    private func actorBatchSeedPeerRoom(_ room: RoomID, on sql: any SQLDatabase) async throws {
        let id = try #require(room.uuidValue)
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        try await sql.raw("INSERT INTO im_v2.rooms (room_id,room_shard_id,capacity_profile_id,capacity_class) VALUES (\(bind: id),'room-a','standard','large')").run()
        try await sql.raw("INSERT INTO im_v2.room_owner_routes (room_id,room_shard_id,route_epoch,created_at,updated_at) VALUES (\(bind: id),'room-a',0,\(bind: now),\(bind: now))").run()
        try await sql.raw("INSERT INTO im_v2.group_rooms (room_id,owner_user_id,title,created_at) VALUES (\(bind: id),\(bind: senderUUID),'Second batch room',\(bind: now))").run()
        try await sql.raw("INSERT INTO im_v2.room_admission (room_id,eligible_member_count,command_window_limit,shard_lease_id,shard_lease_generation) VALUES (\(bind: id),3,10,\(bind: leaseUUID),1)").run()
        for member in [senderUUID, memberTwoUUID, memberThreeUUID] {
            try await sql.raw("INSERT INTO im_v2.room_memberships (room_id,user_id,joined_revision) VALUES (\(bind: id),\(bind: member),0)").run()
        }
    }
}

private struct ActorBatchTimeoutSettings: Decodable, Sendable {
    let lockTimeout: String
    let statementTimeout: String
    let idleTimeout: String
    enum CodingKeys: String, CodingKey {
        case lockTimeout = "lock_timeout"
        case statementTimeout = "statement_timeout"
        case idleTimeout = "idle_timeout"
    }
}
