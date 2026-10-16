@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2ActorCluster
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
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
            // Restoration must use its own budget rather than the foreground gate.
            let initializationDatabase = try V2EventLoopBalancedDatabase(databases: [database], loanPolicy: .init(
                maximumConnections: 1, reservedRenewalConnections: 0,
                maximumQueued: 16, maximumWait: .seconds(5)))
            let database = try V2EventLoopBalancedDatabase(databases: [database], loanPolicy: .init(
                maximumConnections: 11, reservedRenewalConnections: 2,
                maximumQueued: 16, maximumWait: .seconds(5)))
            // Match the factory's declared review policy. The generic test
            // convenience initializer enables review and forces scalar fallback.
            let writes = PostgresV2RoomWriteStore(database: database, contentReviewMode: .disabled)
            let admission = V2DatabaseWorkAdmissionController(policy: .init(
                maximumForegroundWriteInFlight: 1, maximumInteractiveReadInFlight: 1,
                maximumSyncInFlight: 1, maximumForegroundWriteQueued: 2,
                maximumInteractiveReadQueued: 2, maximumSyncQueued: 1,
                timeout: .seconds(1)))
            let sendDatabase = try v2FixtureMessageWriteDatabase(database, capacity: 1)
            let ownerResources = try V2RoomServerOwnerResources(database: database, initializationDatabase: initializationDatabase, sendDatabase: sendDatabase, writes: writes,
                membershipIdentities: V2PostgresMembershipIdentitySnapshotValidator(database: database),
                invitationIdentities: PostgresV2GroupInvitationIdentityReader(database: database),
                invitationSecretIssuer: try .init(rawKey: Data(repeating: 0x73, count: 32)),
                receiptProjectionDelivery: ActorFactoryProjectionDelivery(), capacityProfile: forwardImportTestProfile(),
                messageLimits: .init(maxUTF8Bytes: 64), maximumEditBytes: 64,
                contentReviewMode: .disabled, queryBatchConfiguration: .init(),
                databaseWorkAdmission: admission)
            let factory = try V2RoomServerActivationFactory(owners: ["room-a": ownerResources.usingFixturePolicyAuthorizations(endpoint: "room-a")],
                safetyActorUserID: senderID, now: { now }).runtimeFactory()
            let configuration = try V2RoomRuntimeConfiguration()
            let owner = try V2RoomDataOwner(shardID: "room-a", epoch: 0)
            let firstIdentity = V2ActorHostIdentity(hostID: try .init("factory-host"), incarnationID: UUID())
            let nextIdentity = V2ActorHostIdentity(hostID: firstIdentity.hostID, incarnationID: UUID())
            try await withNativePlacementTestControl(host: firstIdentity, shardID: owner.shardID) { control in
            let firstPlacement = try await control.register(firstIdentity, shard: owner.shardID)
            let first = V2RoomActivationHost<V2RoomRequest, V2RoomResponse>(identity: firstIdentity,
                placement: firstPlacement, configuration: configuration, budget: .init(configuration: configuration),
                classify: { $0.turnSchedulingClass }, factory: factory)
            var next: V2RoomActivationHost<V2RoomRequest, V2RoomResponse>?
            await first.start()
            do {
                guard case .ready(let token) = try await first.activate(roomID: roomID, owner: owner,
                    deadline: .now + .seconds(10)) else { throw V2RoomCallFailure.notAccepted(.notReady) }
                #expect(initializationDatabase.loanMetricsSnapshot().classes[.ordinary]?.granted == 1)
                #expect(database.loanMetricsSnapshot().classes[.activation]?.granted == 0)
                #expect(database.loanMetricsSnapshot().classes[.ordinary]?.granted == 0)
                let staleDataOwner = try V2RoomDataOwner(shardID: "room-a", epoch: 1)
                let staleToken = V2RoomActivationToken(roomID: roomID, owner: staleDataOwner,
                    activationEpoch: try .init(1), host: .init(hostID: .init(uuid: UUID()), incarnationID: UUID()))
                await #expect(throws: V2RoomOwnerFenceError.ownerChanged) {
                    try await v2RestoreRoomSendInitialization(database: database, token: staleToken)
                }
                let command = try V2MessageSendOperationCommand(command: .init(roomID: roomID, senderUserID: senderID,
                    clientMessageID: .init(uuid: UUID()), text: "factory send", limits: .init(maxUTF8Bytes: 64)),
                    firstSubmissionDeadlineMilliseconds: UInt64(now.timeIntervalSince1970 * 1000) + 600_000)
                let request = V2RoomRequest.messaging(.sendOperation(command))
                let bytes = try request
                let response = try await first.invoke(token: token, request: bytes,
                    deadline: .now + .seconds(10))
                guard case .messaging(.sendOperation(.receipt(let originalProof))) = response,
                      case .accepted(let receipt) = originalProof.outcome else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                let sendAdmission = await admission.snapshot()
                #expect(sendAdmission.foregroundWrite.admittedRequests == 0)
                #expect(sendAdmission.foregroundWrite.inFlight == 0)
                let durableMetrics = ownerResources.sendOperationMetrics.sendOperationBatchMetricsSnapshot()
                #expect(durableMetrics.attemptedBatches == 1 && durableMetrics.committedCommands == 1)
                #expect(durableMetrics.inFlightBatches == 0)
                // Actor lifetime and prepared authorization replace the former
                // standalone owner fence.
                for source in [V2RoomSQLContinuationSource.durableFenceRooms] {
                    #expect(durableMetrics.sqlContinuations[source]?.settledToResumedCount == 0)
                }
                let read = try V2ActorRecordReadReceiptWire(roomID: roomID, actorUserID: senderID,
                    operationID: .init(uuid: UUID()), readThroughRoomSequence: receipt.roomSequence)
                let recorded = try await first.invoke(token: token,
                    request: V2RoomRequest.receipt(.record(read)),
                    deadline: .now + .seconds(10))
                guard case .receipt(.record(.recorded(let readReceipt))) = recorded else {
                    throw V2ReadReceiptStoreError.corruptPersistenceState
                }
                #expect(readReceipt.readThroughRoomSequence == receipt.roomSequence)
                let query = V2RoomRequest.recovery(.init(roomID: roomID, actorUserID: senderID, kind: .state))
                let state = try await first.invoke(token: token, request: query,
                    deadline: .now + .seconds(10))
                guard case .recovery(.state(.state(let value))) = state else {
                    throw V2RoomRecoveryReadError.corruptPersistence
                }
                #expect(value.roomID == roomID)

                let denied = V2RoomRequest.roomLog(.subscribe(.init(roomID: roomID, actorUserID: .init(uuid: UUID()))))
                let denial = try await first.invoke(token: token, request: denied,
                    deadline: .now + .seconds(10))
                #expect(denial == .roomLog(.failure(.actorNotMember)))
                // An Account-style direct invoke has no Gateway permit. The
                // physical Host still admits its recovery and room-log SQL.
                // Message sends use physical write capacity directly.
                let admissionSnapshot = await admission.snapshot()
                #expect(admissionSnapshot.foregroundWrite.admittedRequests == 1)
                #expect(admissionSnapshot.interactiveRead.admittedRequests == 2)
                #expect(admissionSnapshot.interactiveRead.inFlight == 0)
                let drained = await first.stop(deadline: .now + .seconds(10))
                #expect(drained.completed)
                try await firstPlacement.retireAfterDrain(try #require(drained.proof), shards: [owner.shardID])
                let nextPlacement = try await control.register(nextIdentity, shard: owner.shardID)
                let successor = V2RoomActivationHost<V2RoomRequest, V2RoomResponse>(identity: nextIdentity,
                    placement: nextPlacement, configuration: configuration, budget: .init(configuration: configuration),
                    classify: { $0.turnSchedulingClass }, factory: factory)
                next = successor
                await successor.start()
                guard case .ready(let replacement) = try await successor.activate(roomID: roomID, owner: owner,
                    deadline: .now + .seconds(10)) else { throw V2RoomCallFailure.notAccepted(.notReady) }
                #expect(replacement.activationEpoch.rawValue > token.activationEpoch.rawValue)
                let repeated = try await successor.invoke(token: replacement, request: bytes,
                    deadline: .now + .seconds(10))
                guard case .messaging(.sendOperation(.receipt(let replay))) = repeated,
                      case .accepted(let recovered) = replay.outcome else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                #expect(replay == originalProof)
                #expect(recovered.messageID == receipt.messageID)
                #expect(try await count("im_v2.messages", on: sql) == 1)
                #expect(await successor.stop(deadline: .now + .seconds(10)).completed)
                await ownerResources.shutdownDurableSendOperations()
                let loans = database.loanMetricsSnapshot()
                #expect((loans.classes[.activation]?.granted ?? 0) == 0)
                #expect((loans.classes[.ordinary]?.granted ?? 0) > 0)
                #expect(loans.classes.values.allSatisfy { $0.inFlight == 0 && $0.queued == 0 })
                for source in [V2DatabaseLoanSource.groupEventSubscribe, .roomRecovery] {
                    let observed = try #require(loans.observations[source])
                    #expect(observed.actualHeldCount > 0)
                    #expect((observed.stages[.sql]?.count ?? 0) > 0)
                    #expect(observed.stages.values.allSatisfy { $0.active == 0 })
                }
                let initializationLoans = initializationDatabase.loanMetricsSnapshot()
                #expect(initializationLoans.classes[.ordinary]?.granted == 2)
                #expect(initializationLoans.classes.values.allSatisfy { $0.inFlight == 0 && $0.queued == 0 })
                let restoration = try #require(initializationLoans.observations[.lifecycle])
                #expect(restoration.sqlPhases[.other]?.count == 2)
                #expect(restoration.sqlPhases[.transactionControl]?.count == 0)
                let messageLoans = sendDatabase.loanMetricsSnapshot()
                #expect(messageLoans.classes.values.allSatisfy { $0.inFlight == 0 && $0.queued == 0 })
                let messageWork = try #require(messageLoans.observations[.durableOwner])
                #expect(messageWork.actualHeldCount > 0 && (messageWork.stages[.sql]?.count ?? 0) > 0)
                #expect((loans.observations[.groupEventSubscribe]?.sqlPhases[.fence]?.count ?? 0) > 0)
                #expect((loans.observations[.groupEventSubscribe]?.sqlPhases[.readBody]?.count ?? 0) > 0)
                let sqlContinuations = ownerResources.sendOperationMetrics.sendOperationBatchMetricsSnapshot().sqlContinuations
                #expect((sqlContinuations[.scalarFenceRooms]?.settledToResumedCount ?? 0) > 0)
                #expect(sqlContinuations.values.allSatisfy { $0.settledNotResumed == 0 && $0.resumedNotDispatched == 0 })
                await database.shutdownLoans()
                await initializationDatabase.shutdownLoans()
            } catch {
                _ = await first.stop(deadline: .now + .seconds(10))
                _ = await next?.stop(deadline: .now + .seconds(10))
                await ownerResources.shutdownDurableSendOperations()
                await database.shutdownLoans()
                await initializationDatabase.shutdownLoans()
                throw error
            }
            }
        }
    }

    @Test("readiness rejects a retired control draft table",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func actorCreationDraftReadiness() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            try await V2SchemaReadiness.verify(database: database)
            try await sql.raw("""
                CREATE TABLE im_v2.group_room_creation_drafts (
                    room_id UUID REFERENCES im_v2.rooms(room_id)
                )
                """).run()
            await #expect(throws: V2SchemaReadinessError.unavailableTable("im_v2.group_room_creation_drafts.retired")) {
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

            let writes = PostgresV2RoomWriteStore(database: ownerDatabase)
                .usingControlDatabase(control)
            let admission = V2DatabaseWorkAdmissionController(policy: .init(
                maximumForegroundWriteInFlight: 1, maximumInteractiveReadInFlight: 1,
                maximumSyncInFlight: 1, maximumForegroundWriteQueued: 2,
                maximumInteractiveReadQueued: 2, maximumSyncQueued: 1,
                timeout: .seconds(1)))
            let resources = try V2RoomServerOwnerResources(
                database: ownerDatabase, initializationDatabase: ownerDatabase, sendDatabase: try v2FixtureMessageWriteDatabase(ownerDatabase, capacity: 1), writes: writes, membershipIdentities: V2PostgresMembershipIdentitySnapshotValidator(database: control),
                invitationIdentities: PostgresV2GroupInvitationIdentityReader(database: control),
                invitationSecretIssuer: try .init(rawKey: Data(repeating: 0x73, count: 32)),
                receiptProjectionDelivery: ActorFactoryProjectionDelivery(), capacityProfile: forwardImportTestProfile(),
                messageLimits: .init(maxUTF8Bytes: 64), maximumEditBytes: 64,
                contentReviewMode: .disabled, queryBatchConfiguration: .init(),
                databaseWorkAdmission: admission
            )
            let factory = try V2RoomServerActivationFactory(
                owners: ["room-b": resources.usingFixturePolicyAuthorizations(controlDatabase: control, endpoint: "room-b")], safetyActorUserID: senderID, now: { now }
            ).runtimeFactory()
            let configuration = try V2RoomRuntimeConfiguration()
            let identity = V2ActorHostIdentity(hostID: try .init("remote-send-host"), incarnationID: UUID())
            try await withNativePlacementTestControl(host: identity, shardID: selectedOwner.shardID) { placementControl in
            let placement = try await placementControl.register(identity, shard: selectedOwner.shardID)
            let host = V2RoomActivationHost<V2RoomRequest, V2RoomResponse>(
                identity: identity, placement: placement, configuration: configuration,
                budget: .init(configuration: configuration),
                classify: { $0.canShareSendTurn ? .send : .barrier }, factory: factory
            )
            await host.start()
            do {
                guard case .ready(let token) = try await host.activate(
                    roomID: room, owner: selectedOwner, deadline: .now + .seconds(10)
                ) else { throw V2RoomCallFailure.notAccepted(.notReady) }
                let command = try V2MessageSendOperationCommand(command: .init(roomID: room, senderUserID: senderID,
                    clientMessageID: .init(uuid: UUID()), text: "remote owner send", limits: .init(maxUTF8Bytes: 64)),
                    firstSubmissionDeadlineMilliseconds: UInt64(now.timeIntervalSince1970 * 1000) + 600_000)
                let request = V2RoomRequest.messaging(.sendOperation(command))
                let response = try await host.invoke(
                    token: token, request: request,
                    deadline: .now + .seconds(10)
                )
                guard case .messaging(.sendOperation(.receipt(let proof))) = response,
                      case .accepted = proof.outcome else {
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
}

private struct ActorFactoryProjectionDelivery: V2UserShardProjectionDelivering {
    func deliverToCurrentShard(userID: UserID, sourceEventID: EventID, projectionKinds: Set<String>) async throws -> UInt64? { nil }
}
