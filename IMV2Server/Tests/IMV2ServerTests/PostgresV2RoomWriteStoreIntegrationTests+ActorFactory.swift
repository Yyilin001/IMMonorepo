@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("explicit physical lease aliases share lifecycle and renewal actors and reject incomplete private mappings",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func leasePhysicalAliasesShareRenewalCoordinator() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, _, _, _ in
            // The physical identity is explicitly supplied, even when all three
            // logical handles happen to use this fixture's same database value.
            let databases = ["lease-a": database, "lease-b": database, "lease-c": database]
            let privateKey = "postgresql://fixture-user:credential-secret@fixture/owner"
            let keys = ["lease-a": privateKey, "lease-b": privateKey, "lease-c": "independent-owner"]
            let shared = try V2RoomServerLeaseStore(databases: databases, physicalRegistrationKeys: keys)
            let legacy = try V2RoomServerLeaseStore(databases: databases)
            let sharedIDs = shared.renewalBatcherIdentities
            let legacyIDs = legacy.renewalBatcherIdentities
            #expect(Set(sharedIDs.keys) == Set(databases.keys))
            #expect(sharedIDs["lease-a"] != nil)
            #expect(sharedIDs["lease-a"] == sharedIDs["lease-b"])
            #expect(sharedIDs["lease-a"] != sharedIDs["lease-c"])
            #expect(legacyIDs["lease-a"] != nil)
            #expect(legacyIDs["lease-a"] != legacyIDs["lease-b"])
            let lifecycleIDs = shared.lifecycleBatcherIdentities
            let legacyLifecycleIDs = legacy.lifecycleBatcherIdentities
            #expect(Set(lifecycleIDs.keys) == Set(databases.keys))
            #expect(lifecycleIDs["lease-a"] != nil)
            #expect(lifecycleIDs["lease-a"] == lifecycleIDs["lease-b"])
            #expect(lifecycleIDs["lease-a"] != lifecycleIDs["lease-c"])
            #expect(legacyLifecycleIDs["lease-a"] != nil)
            #expect(legacyLifecycleIDs["lease-a"] != legacyLifecycleIDs["lease-b"])
            var missing = keys; missing.removeValue(forKey: "lease-c")
            var extra = keys; extra["lease-extra"] = privateKey
            var empty = keys; empty["lease-c"] = ""
            var whitespace = keys; whitespace["lease-c"] = " \t\n"
            for invalidKeys in [missing, extra, empty, whitespace] {
                do {
                    let unexpected = try V2RoomServerLeaseStore(databases: databases,
                        physicalRegistrationKeys: invalidKeys)
                    await unexpected.shutdownRenewals()
                    await unexpected.shutdownLifecycle()
                    Issue.record("invalid physical registration mapping was accepted")
                } catch {
                    #expect((error as? V2ActorContractError) == .invalidConfiguration("room lease physical registration keys"))
                    let diagnostic = String(reflecting: error)
                    #expect(!diagnostic.contains(privateKey))
                    #expect(!diagnostic.contains("credential-secret"))
                }
            }
            await shared.shutdownRenewals()
            await legacy.shutdownRenewals()
            await shared.shutdownLifecycle()
            await legacy.shutdownLifecycle()
        }
    }

    @Test("concrete room factory sends, reads and recovers the same operation after retirement",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func actorFactoryRestoresSendAndQueries() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            // The generic write fixture predates recovery's positive membership
            // generation contract. Seed the current creation invariant here.
            try await sql.raw("UPDATE im_v2.rooms SET membership_revision = 1").run()
            try await sql.raw("UPDATE im_v2.room_memberships SET joined_revision = 1").run()
            // Exercise production lifecycle facades against actual PostgreSQL,
            // while observing a single shared physical admission gate.
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
            let ownerResources = try V2RoomServerOwnerResources(database: database, sendDatabase: try v2FixtureMessageWriteDatabase(database, capacity: 1), writes: writes,
                membershipIdentities: V2PostgresMembershipIdentitySnapshotValidator(database: database),
                invitationIdentities: PostgresV2GroupInvitationIdentityReader(database: database),
                invitationSecretIssuer: try .init(rawKey: Data(repeating: 0x73, count: 32)),
                receiptProjectionDelivery: ActorFactoryProjectionDelivery(), capacityProfile: forwardImportTestProfile(),
                messageLimits: .init(maxUTF8Bytes: 64), maximumEditBytes: 64,
                contentReviewMode: .disabled, queryBatchConfiguration: .init(),
                databaseWorkAdmission: admission)
            let leases = try V2RoomServerLeaseStore(databases: ["room-a": database],
                sqlContinuationMetricsByOwner: ["room-a": ownerResources.sendOperationMetrics])
            let factory = try V2RoomServerActivationFactory(owners: ["room-a": ownerResources.usingFixturePolicyAuthorizations(endpoint: "room-a")],
                safetyActorUserID: senderID, now: { now }).runtimeFactory(validation: {
                    try await leases.validate(token: $0)
                })
            let configuration = try V2RoomRuntimeConfiguration()
            let owner = try V2RoomDataOwner(shardID: "room-a", epoch: 0)
            let makeHost = { () throws -> V2RoomActivationHost<V2RoomRequest, V2RoomResponse> in
                .init(identity: .init(hostID: try .init("factory-host"), incarnationID: UUID()),
                    leaseStore: leases, configuration: configuration, budget: .init(configuration: configuration),
                    classify: { $0.turnSchedulingClass }, factory: factory)
            }
            let first = try makeHost(), next = try makeHost()
            await first.start()
            await next.start()
            do {
                guard case .ready(let token) = try await first.activate(roomID: roomID, owner: owner,
                    deadline: .now + .seconds(10)) else { throw V2RoomCallFailure.notAccepted(.notReady) }
                #expect(database.loanMetricsSnapshot().classes[.activation]?.granted == 3)
                #expect(database.loanMetricsSnapshot().classes[.ordinary]?.granted == 0)
                let initialSQL = ownerResources.sendOperationMetrics.sendOperationBatchMetricsSnapshot().sqlContinuations
                for source in [V2RoomSQLContinuationSource.lifecycleRooms, .lifecycleLeases] {
                    #expect(initialSQL[source]?.settledToResumedCount == 2)
                    #expect(initialSQL[source]?.resumedToDispatchCount == 2)
                    #expect(initialSQL[source]?.settledNotResumed == 0)
                    #expect(initialSQL[source]?.resumedNotDispatched == 0)
                }
                let command = try V2MessageSendOperationCommand(command: .init(roomID: roomID, senderUserID: senderID,
                    clientMessageID: .init(uuid: UUID()), text: "factory send", limits: .init(maxUTF8Bytes: 64)),
                    firstSubmissionDeadlineMilliseconds: UInt64(now.timeIntervalSince1970 * 1000) + 600_000)
                let request = V2RoomRequest.messaging(.sendOperation(command))
                let bytes = try JSONEncoder().encode(request)
                let response = try await first.invoke(token: token, encodedRequest: bytes,
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
                for source in [V2RoomSQLContinuationSource.durableFenceCombined,
                    .durableFenceRooms, .durableFenceLeases] {
                    #expect(durableMetrics.sqlContinuations[source]?.settledToResumedCount == 0)
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
                // Message sends use physical write capacity directly.
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
                guard case .messaging(.sendOperation(.receipt(let replay))) = repeated,
                      case .accepted(let recovered) = replay.outcome else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                #expect(replay == originalProof)
                #expect(recovered.messageID == receipt.messageID)
                #expect(try await count("im_v2.messages", on: sql) == 1)
                #expect(await next.stop(deadline: .now + .seconds(10)).completed)
                let loans = database.loanMetricsSnapshot()
                #expect((loans.classes[.activation]?.granted ?? 0) >= 6)
                #expect((loans.classes[.ordinary]?.granted ?? 0) > 0)
                #expect(loans.classes.values.allSatisfy { $0.inFlight == 0 && $0.queued == 0 })
                for source in [V2DatabaseLoanSource.durableOwner, .groupEventSubscribe, .roomRecovery, .lifecycle] {
                    let observed = try #require(loans.observations[source])
                    #expect(observed.actualHeldCount > 0)
                    #expect((observed.stages[.sql]?.count ?? 0) > 0)
                    #expect(observed.stages.values.allSatisfy { $0.active == 0 })
                }
                #expect((loans.observations[.groupEventSubscribe]?.sqlPhases[.fence]?.count ?? 0) > 0)
                #expect((loans.observations[.groupEventSubscribe]?.sqlPhases[.readBody]?.count ?? 0) > 0)
                let sqlContinuations = ownerResources.sendOperationMetrics.sendOperationBatchMetricsSnapshot().sqlContinuations
                #expect((sqlContinuations[.scalarFenceRooms]?.settledToResumedCount ?? 0) > 0)
                #expect(sqlContinuations.values.allSatisfy { $0.settledNotResumed == 0 && $0.resumedNotDispatched == 0 })
                await leases.shutdownLifecycle()
                await database.shutdownLoans()
            } catch {
                _ = await first.stop(deadline: .now + .seconds(10))
                _ = await next.stop(deadline: .now + .seconds(10))
                await leases.shutdownLifecycle()
                await database.shutdownLoans()
                throw error
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
            await #expect(throws: V2RoomActivationLeaseError.roomNotFound) {
                _ = try await PostgresV2RoomActivationStore(database: control)
                    .locate(roomID: room, owner: selectedOwner)
            }

            let writes = PostgresV2RoomWriteStore(database: ownerDatabase)
                .usingControlDatabase(control)
            let admission = V2DatabaseWorkAdmissionController(policy: .init(
                maximumForegroundWriteInFlight: 1, maximumInteractiveReadInFlight: 1,
                maximumSyncInFlight: 1, maximumForegroundWriteQueued: 2,
                maximumInteractiveReadQueued: 2, maximumSyncQueued: 1,
                timeout: .seconds(1)))
            let resources = try V2RoomServerOwnerResources(
                database: ownerDatabase, sendDatabase: try v2FixtureMessageWriteDatabase(ownerDatabase, capacity: 1), writes: writes, membershipIdentities: V2PostgresMembershipIdentitySnapshotValidator(database: control),
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
                let command = try V2MessageSendOperationCommand(command: .init(roomID: room, senderUserID: senderID,
                    clientMessageID: .init(uuid: UUID()), text: "remote owner send", limits: .init(maxUTF8Bytes: 64)),
                    firstSubmissionDeadlineMilliseconds: UInt64(now.timeIntervalSince1970 * 1000) + 600_000)
                let request = V2RoomRequest.messaging(.sendOperation(command))
                let response = try await host.invoke(
                    token: token, encodedRequest: JSONEncoder().encode(request),
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

private struct ActorFactoryProjectionDelivery: V2UserShardProjectionDelivering {
    func deliverToCurrentShard(userID: UserID, sourceEventID: EventID, projectionKinds: Set<String>) async throws -> UInt64? { nil }
}
