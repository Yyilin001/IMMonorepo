@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
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
            for sql in [control] {
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
                direct: PostgresV2DirectMessagingStore(database: ownerDB, identityReader: PostgresV2DirectRoomIdentityReader(database: controlDB),
                    projectionDelivery: V2DiscardingUserShardProjectionDelivery()),
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
            let fixedNow = Date()
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            let groups = PostgresV2GroupCreationOperationStore(database: controlDB,
                selector: try .init(shardIDs: ["rooms-01"]), bootstrap: port, capacityProfile: profile)
            func groupIntent(title: String) throws -> V2GroupCreationIntent {
                try .init(identity: .init(accountID: actor, scope: .account(actor), operation: .groupRoom(.init(uuid: UUID()))),
                    title: title, capacityClass: .standard, initialMemberCount: 1,
                    audienceDigest: V2GroupCreationAudience.digest([member]), firstSubmissionDeadlineMilliseconds: UInt64(fixedNow.timeIntervalSince1970 * 1_000) + 600_000)
            }
            let group = try groupIntent(title: "Recovery Group")
            _ = try await groups.begin(group, now: fixedNow)
            _ = try await groups.append(.init(intent: group, offset: 0, memberUserIDs: [member]), now: fixedNow)
            await drop.arm()
            await #expect(throws: D4SimulatedResponseLoss.self) {
                _ = try await groups.finalize(group, now: fixedNow, deadline: deadline)
            }
            #expect(try await owner.raw("SELECT count(*)::bigint AS value FROM im_v2.rooms")
                .first(decoding: D4CountRow.self)?.value == 1)
            guard case .receipt(let recovered) = try await groups.recover(.init(intent: group, action: .query), now: fixedNow),
                  case .created(let recoveredRoom, _, _, _) = recovered.outcome else { throw V2GroupRoomCreationIntentStoreError.routeConflict }
            #expect(recovered.validates(intent: group))
            #expect(try await owner.raw("SELECT count(*)::bigint AS value FROM im_v2.rooms WHERE room_id = \(bind: recoveredRoom.uuidValue!)")
                .first(decoding: D4CountRow.self)?.value == 1)
            let direct = PostgresV2DirectRoomOperationStore(database: controlDB,
                routes: V2PostgresRoomShardRouter(database: controlDB), selector: try .init(shardIDs: ["rooms-01"]), bootstrap: port)
            let command = try V2DirectRoomOperationCommand(actorUserID: actor, operationID: .init(uuid: UUID()),
                targetUserID: member, firstSubmissionDeadlineMilliseconds: UInt64(fixedNow.timeIntervalSince1970 * 1_000) + 600_000)
            let first = try await direct.submit(command, now: fixedNow, deadline: deadline)
            guard case .receipt(let opened) = first, case .opened = opened.outcome else { throw V2GroupRoomCreationIntentStoreError.routeConflict }
            #expect(opened.validates(command: command))
            #expect(try await direct.submit(command, now: fixedNow, deadline: deadline) == first)
            let staged = try groupIntent(title: "Staged Recovery")
            _ = try await groups.begin(staged, now: fixedNow)
            _ = try await groups.append(.init(intent: staged, offset: 0, memberUserIDs: [member]), now: fixedNow)
            await drop.arm()
            await #expect(throws: D4SimulatedResponseLoss.self) {
                _ = try await groups.finalize(staged, now: fixedNow, deadline: deadline)
            }
            // Recovery progresses the already frozen owner operation after its
            // original admission expires, rather than creating a new identity.
            guard case .receipt(let resumed) = try await groups.recover(.init(intent: staged, action: .closeIfAbsent), now: fixedNow.addingTimeInterval(601)),
                  case .created = resumed.outcome else { throw V2GroupRoomCreationIntentStoreError.routeConflict }
            #expect(resumed.validates(intent: staged))
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
