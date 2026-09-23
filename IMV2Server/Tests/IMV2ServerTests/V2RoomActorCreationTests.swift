import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server
import SQLKit
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("D4 bootstrap replays fixed room ID and recovers staged finalize",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_ACTOR_D4_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func v2RoomActorCreationFixedIdentityAndFinalizeRecovery() async throws {
        let controlURL = try #require(ProcessInfo.processInfo.environment["IMV2_ACTOR_D4_CONTROL_DATABASE_URL"])
        let ownerURL = try #require(ProcessInfo.processInfo.environment["IMV2_ACTOR_D4_OWNER_DATABASE_URL"])
        let resources = makeV2DatabaseTestResources()
        let ownerID = DatabaseID(string: "d4-owner")
        resources.databases.use(try .postgres(url: controlURL, maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
        resources.databases.use(try .postgres(url: ownerURL, maxConnectionsPerEventLoop: 4), as: ownerID)
        let controlDB = resources.database(.psql), ownerDB = resources.database(ownerID)
        let control = try #require(controlDB as? any SQLDatabase)
        let owner = try #require(ownerDB as? any SQLDatabase)
        do {
            for sql in [control, owner] {
                guard try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS value")
                    .first(decoding: D4ExistsRow.self)?.value == false else {
                    throw TestConfigurationError.schemaAlreadyExists
                }
                try await installSchema(on: sql)
            }
            let actor = UserID(uuid: UUID()), member = UserID(uuid: UUID())
            for sql in [control, owner] {
                try await sql.raw("""
                    INSERT INTO im_v2.public_user_profiles
                        (user_id, public_handle, display_name, created_at, updated_at)
                    VALUES (\(bind: actor.uuidValue!), 'd4_actor', 'D4 Actor', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
                           (\(bind: member.uuidValue!), 'd4_member', 'D4 Member', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
                    """).run()
            }
            try await owner.raw("""
                INSERT INTO im_v2.shard_admission_pools
                    (room_shard_id, capacity_profile_id, lease_id, generation, valid_until, command_window_limit)
                VALUES ('rooms-01', 'standard', \(bind: UUID()), 1,
                        CURRENT_TIMESTAMP + INTERVAL '1 hour', 1000)
                """).run()
            let profile = try V2CapacityProfile(id: "standard", limits: .init(
                maxEligibleMembers: 100, maxCommandsPerWindow: 1000, retryAfterSeconds: 1))
            let bootstrap = try V2RoomBootstrapDomainExecutor(shardID: "rooms-01",
                direct: PostgresV2DirectMessagingStore(database: ownerDB),
                group: PostgresV2GroupMessagingStore(database: ownerDB),
                capacityProfile: profile)
            let drop = D4BootstrapResponseDrop()
            let port = V2ActorCreationBootstrapPort(execute: { command, _ in
                let result = try await bootstrap.execute(command)
                if await drop.consume() { throw D4SimulatedResponseLoss() }
                return result
            }, stage: { intent, page, _ in
                try await bootstrap.stage(intent: intent, page: page)
            })
            let coordinator = V2ActorRoomCreationCoordinator(controlDatabase: controlDB,
                directRoutes: V2PostgresRoomShardRouter(database: controlDB),
                directSelector: try .init(shardIDs: ["rooms-01"]),
                groupSelector: try .init(shardIDs: ["rooms-01"]),
                bootstrap: port, capacityProfile: profile)
            let deadline = ContinuousClock().now.advanced(by: .seconds(30))
            let groupOperation = GroupRoomOperationID(uuid: UUID())
            let group = V2ActorRoomCreationCommand.createGroup(.init(actorUserID: actor,
                operationID: groupOperation, title: "Recovery Group",
                initialMemberUserIDs: [member]))
            await drop.arm()
            await #expect(throws: D4SimulatedResponseLoss.self) {
                _ = try await coordinator.execute(group, deadline: deadline)
            }
            #expect(try await owner.raw("SELECT count(*)::bigint AS value FROM im_v2.rooms")
                .first(decoding: D4CountRow.self)?.value == 1)
            guard case .group(.idempotent(let recovered)) = try await coordinator.execute(group, deadline: deadline) else {
                throw V2GroupRoomCreationIntentStoreError.routeConflict
            }
            #expect(try await owner.raw("SELECT count(*)::bigint AS value FROM im_v2.rooms WHERE room_id = \(bind: recovered.roomID.uuidValue!)")
                .first(decoding: D4CountRow.self)?.value == 1)
            let direct = V2ActorRoomCreationCommand.openDirect(.init(actorUserID: actor,
                operationID: .init(uuid: UUID()), targetUserID: member))
            guard case .direct(.opened(let opened)) = try await coordinator.execute(direct, deadline: deadline),
                  case .direct(.idempotent(let reopened)) = try await coordinator.execute(direct, deadline: deadline)
            else { throw V2GroupRoomCreationIntentStoreError.routeConflict }
            #expect(opened.roomID == reopened.roomID)
            let stagedOperation = GroupRoomOperationID(uuid: UUID())
            let stagedBase = V2ActorStagedGroupOperationWire(actorUserID: actor, operationID: stagedOperation)
            guard case .draft = try await coordinator.execute(.beginStaged(.init(
                actorUserID: actor, operationID: stagedOperation, title: "Staged Recovery")),
                deadline: deadline) else { throw V2GroupAudienceImportError.invalidInput }
            guard case .draft = try await coordinator.execute(.appendStaged(.init(
                actorUserID: actor, operationID: stagedOperation, memberUserIDs: [member])),
                deadline: deadline) else { throw V2GroupAudienceImportError.invalidInput }
            await drop.arm()
            await #expect(throws: D4SimulatedResponseLoss.self) {
                _ = try await coordinator.execute(.finalizeStaged(stagedBase), deadline: deadline)
            }
            try await control.raw("""
                UPDATE im_v2.group_room_creation_drafts
                SET updated_at = CURRENT_TIMESTAMP - INTERVAL '1 day'
                WHERE actor_user_id = \(bind: actor.uuidValue!)
                  AND operation_id = \(bind: stagedOperation.uuidValue!)
                """).run()
            let report = try await coordinator.recoverFinalizing(limit: 8, deadline: deadline)
            #expect(report.claimedCount == 1 && report.recoveredCount == 1 && report.failedCount == 0)
            #expect(try await owner.raw("SELECT count(*)::bigint AS value FROM im_v2.rooms")
                .first(decoding: D4CountRow.self)?.value == 3)
            try await control.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await owner.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            try? await control.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            try? await owner.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            try? await resources.shutdown()
            throw error
        }
    }
}

private struct D4ExistsRow: Decodable { let value: Bool }
private struct D4CountRow: Decodable { let value: Int64 }
private struct D4SimulatedResponseLoss: Error {}
private actor D4BootstrapResponseDrop {
    private var armed = false
    func arm() { armed = true }
    func consume() -> Bool { defer { armed = false }; return armed }
}
