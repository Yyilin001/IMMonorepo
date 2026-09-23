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
            let ownerResources = try V2RoomServerOwnerResources(database: database, writes: writes,
                sendBatcher: batcher,
                membershipIdentities: V2PostgresMembershipIdentitySnapshotValidator(database: database),
                invitationIdentities: PostgresV2GroupInvitationIdentityReader(database: database),
                receiptShadowForwarder: ActorFactoryShadow(), capacityProfile: forwardImportTestProfile(),
                messageLimits: .init(maxUTF8Bytes: 64), maximumEditBytes: 64,
                contentReviewMode: .disabled, queryBatchConfiguration: .init())
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
}

private struct ActorFactoryShadow: V2UserShardProjectionShadowing {
    func shadowIfForwarding(userID: UserID, sourceEventID: EventID, projectionKinds: Set<String>) async throws -> UInt64? { nil }
}
