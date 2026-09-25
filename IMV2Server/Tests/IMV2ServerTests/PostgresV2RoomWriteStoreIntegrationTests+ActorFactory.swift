import Foundation
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Core
@testable import IMV2Server
import SQLKit
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("concrete room factory sends, reads and recovers the same operation after retirement",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func actorFactoryRestoresSendAndQueries() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            // The generic write fixture predates recovery's positive membership
            // generation contract. Seed the current creation invariant here.
            try await sql.raw("UPDATE im_v2.rooms SET membership_revision = 1").run()
            try await sql.raw("UPDATE im_v2.room_memberships SET joined_revision = 1").run()
            let writes = PostgresV2RoomWriteStore(database: database)
            let batcher = V2SendMessageAdmissionBatcher(store: writes,
                configuration: .init(maximumBatchSize: 16, maximumDelay: .milliseconds(2)),
                actorGrantedStore: writes)
            let admission = V2DatabaseWorkAdmissionController(policy: .init(
                maximumForegroundWriteInFlight: 1, maximumInteractiveReadInFlight: 1,
                maximumSyncInFlight: 1, maximumForegroundWriteQueued: 2,
                maximumInteractiveReadQueued: 2, maximumSyncQueued: 1,
                timeout: .seconds(1)))
            let ownerResources = try V2RoomServerOwnerResources(database: database, writes: writes,
                sendBatcher: batcher,
                membershipIdentities: V2PostgresMembershipIdentitySnapshotValidator(database: database),
                invitationIdentities: PostgresV2GroupInvitationIdentityReader(database: database),
                receiptShadowForwarder: ActorFactoryShadow(), capacityProfile: forwardImportTestProfile(),
                messageLimits: .init(maxUTF8Bytes: 64), maximumEditBytes: 64,
                contentReviewMode: .disabled, queryBatchConfiguration: .init(),
                databaseWorkAdmission: admission)
            let factory = try V2RoomServerActivationFactory(owners: ["room-a": ownerResources],
                safetyActorUserID: senderID, now: { now }).runtimeFactory()
            let configuration = try V2RoomRuntimeConfiguration()
            let leases = try V2RoomServerLeaseStore(databases: ["room-a": database])
            let owner = try V2RoomDataOwner(shardID: "room-a", epoch: 0)
            let makeHost = { () throws -> V2RoomActivationHost<V2RoomRequest, V2RoomResponse> in
                .init(identity: .init(hostID: try .init("factory-host"), incarnationID: UUID()),
                    leaseStore: leases, configuration: configuration, budget: .init(configuration: configuration),
                    classify: { $0.canShareSendTurn ? .send : .barrier }, factory: factory)
            }
            let first = try makeHost(), next = try makeHost()
            await first.start()
            await next.start()
            do {
                guard case .ready(let token) = try await first.activate(roomID: roomID, owner: owner,
                    deadline: .now + .seconds(10)) else { throw V2RoomCallFailure.notAccepted(.notReady) }
                let request = V2RoomRequest.messaging(.send(.init(roomID: roomID, actorUserID: senderID,
                    clientMessageID: .init(uuid: UUID()), text: "factory send", media: [], mentions: [],
                    entities: [], replyTo: nil)))
                let bytes = try JSONEncoder().encode(request)
                let response = try await first.invoke(token: token, encodedRequest: bytes,
                    deadline: .now + .seconds(10))
                guard case .messaging(.send(let sent)) = response,
                      let receipt = try sent.toDomain().acceptanceReceipt else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                let read = try V2ActorRecordReadReceiptWire(roomID: roomID, actorUserID: senderID,
                    operationID: .init(uuid: UUID()), readThroughRoomSequence: receipt.roomSequence)
                let recorded = try await first.invoke(token: token,
                    encodedRequest: JSONEncoder().encode(V2RoomRequest.receipt(.record(read))),
                    deadline: .now + .seconds(10))
                guard case .receipt(.record(.recorded(let readReceipt))) = recorded else {
                    throw V2ReadReceiptStoreError.corruptPersistenceState
                }
                #expect(readReceipt.readThroughRoomSequence == receipt.roomSequence)
                let query = V2RoomRequest.recovery(.init(roomID: roomID, actorUserID: senderID, kind: .state))
                let state = try await first.invoke(token: token, encodedRequest: JSONEncoder().encode(query),
                    deadline: .now + .seconds(10))
                guard case .recovery(.state(.state(let value))) = state else {
                    throw V2RoomRecoveryReadError.corruptPersistence
                }
                #expect(value.roomID == roomID)

                let denied = V2RoomRequest.roomLog(.subscribe(.init(roomID: roomID, actorUserID: .init(uuid: UUID()))))
                let denial = try await first.invoke(token: token, encodedRequest: JSONEncoder().encode(denied),
                    deadline: .now + .seconds(10))
                #expect(denial == .roomLog(.failure(.actorNotMember)))
                // An Account-style direct invoke has no Gateway permit. The
                // physical Host still admits its recovery and room-log SQL.
                let admissionSnapshot = await admission.snapshot()
                #expect(admissionSnapshot.foregroundWrite.admittedRequests == 1)
                #expect(admissionSnapshot.interactiveRead.admittedRequests == 2)
                #expect(admissionSnapshot.interactiveRead.inFlight == 0)
                #expect(await first.stop(deadline: .now + .seconds(10)).completed)
                guard case .ready(let replacement) = try await next.activate(roomID: roomID, owner: owner,
                    deadline: .now + .seconds(10)) else { throw V2RoomCallFailure.notAccepted(.notReady) }
                #expect(replacement.activationEpoch.rawValue > token.activationEpoch.rawValue)
                let repeated = try await next.invoke(token: replacement, encodedRequest: bytes,
                    deadline: .now + .seconds(10))
                guard case .messaging(.send(let wire)) = repeated,
                      case .idempotent(let recovered) = try wire.toDomain() else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                #expect(recovered.messageID == receipt.messageID)
                #expect(try await count("im_v2.messages", on: sql) == 1)
                #expect(await next.stop(deadline: .now + .seconds(10)).completed)
            } catch {
                _ = await first.stop(deadline: .now + .seconds(10))
                _ = await next.stop(deadline: .now + .seconds(10))
                throw error
            }
        }
    }

    @Test("readiness rejects a control draft foreign key to the local owner rooms",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func actorCreationDraftReadiness() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            try await V2SchemaReadiness.verify(database: database)
            try await sql.raw("""
                ALTER TABLE im_v2.group_room_creation_drafts
                ADD CONSTRAINT invalid_control_room_fk FOREIGN KEY (room_id) REFERENCES im_v2.rooms(room_id)
                """).run()
            await #expect(throws: V2SchemaReadinessError.unavailableTable("im_v2.group_room_creation_drafts[remote-owner]")) {
                try await V2SchemaReadiness.verify(database: database)
            }
        }
    }

    @Test("control route selects the physical owner for an Actor-hosted send")
    func actorSendUsesSelectedRemoteOwner() async throws {
        try await withForwardOwnerDatabases(mode: .standard) {
            control, ownerDatabase, controlSQL, ownerSQL, room in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            try await controlSQL.raw("""
                INSERT INTO im_v2.room_owner_routes
                    (room_id, room_shard_id, route_epoch, created_at, updated_at)
                VALUES (\(bind: room.uuidValue!), 'room-b', 0, \(bind: now), \(bind: now))
                """).run()
            let route = try await V2PostgresRoomShardRouter(database: control).route(for: room)
            let selectedOwner = try V2RoomDataOwner(shardID: route.shardID, epoch: route.epoch)
            #expect(selectedOwner.shardID == "room-b")
            await #expect(throws: V2RoomActivationLeaseError.roomNotFound) {
                _ = try await PostgresV2RoomActivationStore(database: control)
                    .locate(roomID: room, owner: selectedOwner)
            }

            let writes = PostgresV2RoomWriteStore(database: ownerDatabase)
                .usingControlDatabase(control)
            let batcher = V2SendMessageAdmissionBatcher(
                store: writes,
                configuration: .init(maximumBatchSize: 8, maximumDelay: .milliseconds(2)),
                actorGrantedStore: writes
            )
            let admission = V2DatabaseWorkAdmissionController(policy: .init(
                maximumForegroundWriteInFlight: 1, maximumInteractiveReadInFlight: 1,
                maximumSyncInFlight: 1, maximumForegroundWriteQueued: 2,
                maximumInteractiveReadQueued: 2, maximumSyncQueued: 1,
                timeout: .seconds(1)))
            let resources = try V2RoomServerOwnerResources(
                database: ownerDatabase, writes: writes, sendBatcher: batcher,
                membershipIdentities: V2PostgresMembershipIdentitySnapshotValidator(database: control),
                invitationIdentities: PostgresV2GroupInvitationIdentityReader(database: control),
                receiptShadowForwarder: ActorFactoryShadow(), capacityProfile: forwardImportTestProfile(),
                messageLimits: .init(maxUTF8Bytes: 64), maximumEditBytes: 64,
                contentReviewMode: .disabled, queryBatchConfiguration: .init(),
                databaseWorkAdmission: admission
            )
            let factory = try V2RoomServerActivationFactory(
                owners: ["room-b": resources], safetyActorUserID: senderID, now: { now }
            ).runtimeFactory()
            let configuration = try V2RoomRuntimeConfiguration()
            let leases = try V2RoomServerLeaseStore(databases: ["room-b": ownerDatabase])
            let host = V2RoomActivationHost<V2RoomRequest, V2RoomResponse>(
                identity: .init(hostID: try .init("remote-send-host"), incarnationID: UUID()),
                leaseStore: leases, configuration: configuration,
                budget: .init(configuration: configuration),
                classify: { $0.canShareSendTurn ? .send : .barrier }, factory: factory
            )
            await host.start()
            do {
                guard case .ready(let token) = try await host.activate(
                    roomID: room, owner: selectedOwner, deadline: .now + .seconds(10)
                ) else { throw V2RoomCallFailure.notAccepted(.notReady) }
                let request = V2RoomRequest.messaging(.send(.init(
                    roomID: room, actorUserID: senderID,
                    clientMessageID: .init(uuid: UUID()), text: "remote owner send",
                    media: [], mentions: [], entities: [], replyTo: nil
                )))
                let response = try await host.invoke(
                    token: token, encodedRequest: JSONEncoder().encode(request),
                    deadline: .now + .seconds(10)
                )
                guard case .messaging(.send(let sent)) = response,
                      case .accepted = try sent.toDomain() else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                #expect(try await count("im_v2.messages", on: ownerSQL) == 1)
                #expect(try await count("im_v2.messages", on: controlSQL) == 0)
                #expect(await host.stop(deadline: .now + .seconds(10)).completed)
            } catch {
                _ = await host.stop(deadline: .now + .seconds(10))
                throw error
            }
        }
    }
}

private struct ActorFactoryShadow: V2UserShardProjectionShadowing {
    func shadowIfForwarding(userID: UserID, sourceEventID: EventID, projectionKinds: Set<String>) async throws -> UInt64? { nil }
}
