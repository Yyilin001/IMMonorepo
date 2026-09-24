import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server
import SQLKit
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("D5 cross-owner export/import replay stays fenced to both owner turns",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_ACTOR_D5_IMPORT_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func v2RoomActorCrossOwnerImportFence() async throws {
        let sourceURL = try #require(ProcessInfo.processInfo.environment["IMV2_ACTOR_D5_SOURCE_DATABASE_URL"])
        let targetURL = try #require(ProcessInfo.processInfo.environment["IMV2_ACTOR_D5_TARGET_DATABASE_URL"])
        let resources = makeV2DatabaseTestResources()
        let targetID = DatabaseID(string: "d5-target")
        resources.databases.use(try .postgres(url: sourceURL, maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
        resources.databases.use(try .postgres(url: targetURL, maxConnectionsPerEventLoop: 4), as: targetID)
        let sourceDB = resources.database(.psql), targetDB = resources.database(targetID)
        let sourceSQL = try #require(sourceDB as? any SQLDatabase)
        let targetSQL = try #require(targetDB as? any SQLDatabase)
        do {
            for sql in [sourceSQL, targetSQL] {
                guard try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS value")
                    .first(decoding: D5ImportBool.self)?.value == false else {
                    throw TestConfigurationError.schemaAlreadyExists
                }
                try await installSchema(on: sql)
            }
            let targetUUID = UUID(), sourceRoom = RoomID(uuid: roomUUID)
            let targetRoom = RoomID(uuid: targetUUID)
            try await seedRoom(on: sourceSQL)
            try await seedRoom(roomID: targetUUID, shardID: "room-b", on: targetSQL)
            let oldNow = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(
                maxEligibleMembers: 10, maxCommandsPerWindow: 10, retryAfterSeconds: 1))
            let limits = try V2MessageCommandLimits(maxUTF8Bytes: 128)
            let send = V2SendMessageService(store: PostgresV2RoomWriteStore(database: sourceDB),
                capacityProfile: profile, limits: limits, now: { oldNow })
            guard case .accepted(let message) = try await send.send(.init(roomID: sourceRoom,
                actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "remote source")) else {
                throw V2ForwardInboxError.corruptPersistenceState
            }
            try await targetSQL.raw("""
                UPDATE im_v2.shard_admission_pools
                SET valid_until = CURRENT_TIMESTAMP + INTERVAL '1 hour'
                WHERE room_shard_id = 'room-b'
                """).run()
            let sourceLeases = PostgresV2RoomActivationStore(database: sourceDB)
            let targetLeases = PostgresV2RoomActivationStore(database: targetDB)
            let host = V2ActorHostIdentity(hostID: try .init("d5-import-host"), incarnationID: UUID())
            guard case .acquired(let sourceGrant) = try await sourceLeases.acquire(
                roomID: sourceRoom, owner: try .init(shardID: "room-a", epoch: 0),
                host: host, duration: try .init(30_000)),
                  case .acquired(let targetGrant) = try await targetLeases.acquire(
                roomID: targetRoom, owner: try .init(shardID: "room-b", epoch: 0),
                host: host, duration: try .init(30_000)) else {
                throw V2RoomActivationLeaseError.activationChanged
            }
            let exporter = try PostgresV2ForwardExportStore(database: sourceDB)
                .usingActivationToken(sourceGrant.token)
            let reference = try V2ForwardMessageReference(roomID: sourceRoom,
                messageID: message.messageID, revision: .init(1))
            guard case .export(let export) = try await exporter.prepareForDelivery(
                actorUserID: senderID, operationID: .init(uuid: UUID()), source: reference,
                sourceRoute: .init(shardID: "room-a", epoch: 0), targetRoomID: targetRoom,
                targetRoute: .init(shardID: "room-b", epoch: 0), now: Date()) else {
                throw V2ForwardExportError.corruptPersistenceState
            }
            let importExecutor = try V2RoomForwardDomainExecutor(database: targetDB,
                token: targetGrant.token, write: PostgresV2RoomWriteStore(database: targetDB),
                capacityProfile: profile, limits: limits)
            let command = V2RoomForwardCommand.importExport(.init(domain: export))
            let first = try await importExecutor.execute(command)
            guard case .imported(.accepted(let id, let sequence)) = first else {
                throw V2ForwardInboxError.corruptPersistenceState
            }
            #expect(sequence > 0)
            #expect(try await importExecutor.execute(command) == first)
            #expect(try await targetSQL.raw("""
                SELECT count(*)::bigint AS value FROM im_v2.messages
                WHERE message_id = \(bind: id.uuidValue!) AND room_id = \(bind: targetUUID)
                """).first(decoding: D5ImportCount.self)?.value == 1)
            #expect(try await targetLeases.release(token: targetGrant.token))
            await #expect(throws: V2RoomActivationLeaseError.activationChanged) {
                _ = try await importExecutor.execute(command)
            }
            #expect(try await sourceLeases.release(token: sourceGrant.token))
            await #expect(throws: V2RoomActivationLeaseError.activationChanged) {
                _ = try await exporter.prepareForDelivery(actorUserID: senderID,
                    operationID: .init(uuid: UUID()), source: reference,
                    sourceRoute: .init(shardID: "room-a", epoch: 0),
                    targetRoomID: targetRoom,
                    targetRoute: .init(shardID: "room-b", epoch: 0), now: Date())
            }
            try await sourceSQL.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await targetSQL.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            try? await sourceSQL.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            try? await targetSQL.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            try? await resources.shutdown()
            throw error
        }
    }
}

private struct D5ImportBool: Decodable { let value: Bool }
private struct D5ImportCount: Decodable { let value: Int64 }
