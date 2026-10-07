import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Core
@testable import IMV2ActorApplication
@testable import IMV2Server
@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("policy actor applications bind production rooms and retain SQL through incomplete shutdown",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_POLICY_APPLICATION_TEST_DEPLOYMENT"] != nil),
          arguments: [false, true])
    func policyApplicationLifecycle(holdSQL: Bool) async throws {
        let root = try #require(ProcessInfo.processInfo.environment["IMV2_POLICY_APPLICATION_TEST_DEPLOYMENT"])
        let hostConfiguration = try V2RoomActorApplicationConfiguration(
            environment: PolicyApplicationEnvironment(path: root + "/gateway/configuration.json"),
            hostsRooms: true, configuredShardIDs: ["room-a"])
        let callerConfiguration = try V2RoomActorApplicationConfiguration(
            environment: PolicyApplicationEnvironment(path: root + "/account/configuration.json"),
            hostsRooms: false, configuredShardIDs: ["room-a"])
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let profile = try forwardImportTestProfile(), limits = try V2MessageCommandLimits(maxUTF8Bytes: 128)
            let identity = try #require(hostConfiguration.hostIdentity)
            let hostID = try #require(identity.hostID.uuidValue)
            let document = try #require(hostConfiguration.policyPlacement)
            let placement = try V2PolicyOwnerPlacement(document)
            try await PostgresV2PolicyDeploymentPlacementStore(database: database).require(placement)
            let binding = V2PolicyClusterClientBinding()
            let revoker = PostgresV2RemotePolicyRevoker(clientProvider: { try await binding.client() }, roomHosts: [hostID: ["room-a"]])
            let legacy = V2DirectAuthorizationCoordinator(controlDatabase: database, ownerDatabases: [:])
            let owners = PostgresV2PolicyOwnerDirectory(journal: .init(database: database),
                dispatcher: .init(database: database, projectionDelivery: SuccessfulProjectionDelivery(), legacyAuthorization: legacy),
                ownerID: identity.incarnationID, ownsScope: { placement.owns($0, hostID: hostID) },
                revoke: { try await revoker.revoke($0) })
            let remote = PostgresV2RemotePolicyOwners(clientProvider: { try await binding.client() }, resolve: { key in
                try await PostgresV2PolicyDeploymentRoutes(placement: placement, client: binding.client()).resolveScope(key)
            })
            let policies = V2RoomPolicyAuthorizationService(roomDatabase: database, controlDatabase: database,
                policyOwners: remote, locator: try .init(hostID: hostID, shardID: "room-a"), maximumRooms: 4)
            let writes = PostgresV2RoomWriteStore(database: database, contentReviewMode: .disabled)
            let resources = try V2RoomServerOwnerResources(database: database, writes: writes, membershipIdentities: V2PostgresMembershipIdentitySnapshotValidator(database: database),
                invitationIdentities: PostgresV2GroupInvitationIdentityReader(database: database),
                invitationSecretIssuer: .init(rawKey: Data(repeating: 0x73, count: 32)),
                receiptProjectionDelivery: SuccessfulProjectionDelivery(), capacityProfile: profile,
                messageLimits: limits, maximumEditBytes: 128, contentReviewMode: .disabled, queryBatchConfiguration: .init())
                .usingPolicyAuthorizations(policies)
            let pairs = V2RoomForwardPairService(executors: ["room-a": V2ActorForwardPairDomainExecutor(database: database,
                write: writes, capacityProfile: profile, limits: limits).usingPolicyAuthorizations(policies)])
            let hosted = V2PolicyHostedServices(placement: document,
                ownership: V2PolicyOwnershipService(owners: owners, endpoint: "room-a"),
                mutations: V2PolicyMutationService(owners: owners, endpoint: "room-a"),
                revocations: try V2RoomPolicyRevocationRouter(hostID: hostID, services: ["room-a": policies]))
                .bindingClient(binding).servingForwardPairs(pairs)
            let router = V2PostgresRoomShardRouter(database: database)
            let sourceRoom = RoomID(uuid: roomUUID)
            try await sql.raw("UPDATE im_v2.shard_admission_pools SET valid_until=clock_timestamp()+interval '10 minutes'").run()
            let now = Date()
            let target = try await V2DirectRoomOperationTestFixture(database: database, capacityProfile: profile,
                roomShardID: "room-a", now: { now }).openedIdentity(actorUserID: senderID,
                    operationID: .init(uuid: UUID()), targetUserID: .init(uuid: memberTwoUUID),
                    firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
            var host: V2RoomActorApplication?, caller: V2RoomActorApplication?
            let held = PolicyApplicationSQLHold()
            var holding: Task<Void, any Error>?, sending: Task<V2RoomResponse, any Error>?
            var phase = "application start"
            do {
                let hostApp = try await V2RoomActorApplication.start(configuration: hostConfiguration,
                    ownerRouter: router, roomDatabases: ["room-a": database],
                    factory: .init(owners: ["room-a": resources], safetyActorUserID: senderID),
                    // This fixture has one voting room host and a nonvoting caller.
                    qualification: .init(localNodeID: "gateway", roster: ["gateway"]), policyServices: hosted)
                host = hostApp
                let callerApp = try await V2RoomActorApplication.start(configuration: callerConfiguration,
                    ownerRouter: router, roomDatabases: ["room-a": database])
                caller = callerApp
                #expect(await hostApp.readiness())
                #expect(await callerApp.readiness())
                phase = "production group send"
                let first = try await callerApp.directory.room(sourceRoom).call(policyApplicationRequest(room: sourceRoom, text: "application source"),
                    principal: .user(senderID), deadline: .now + .seconds(10))
                try policyApplicationAccepted(first)
                let source = try #require(try await sql.raw("SELECT message_id AS value FROM im_v2.messages WHERE room_id=\(bind: roomUUID) ORDER BY room_sequence LIMIT 1").first(decoding: PolicyApplicationUUID.self)).value
                let pair = V2ActorForwardPairWire(actorUserID: senderID, operationID: .init(uuid: UUID()),
                    source: try .init(roomID: sourceRoom, messageID: .init(uuid: source), revision: .init(1)), targetRoomID: target.roomID)
                phase = "application forward pair"
                let forwarded = try await callerApp.forwardPair(pair, deadline: .now + .seconds(10))
                #expect(forwarded.messageID != nil && forwarded.errorCode == nil)
                #expect(try await callerApp.forwardPair(pair, deadline: .now + .seconds(10)) == forwarded)
                phase = "application policy mutation and revocation"
                let social = PostgresV2SocialRelationshipStore(database: database, projectionDelivery: SuccessfulProjectionDelivery())
                    .usingPolicyOwners(try await callerApp.policyMutationExecutor())
                let block = try await social.freezeSocialFixture(actorUserID: senderID, targetUserID: .init(uuid: memberTwoUUID),
                    operation: .userBlock(.init(uuid: UUID())), action: .userBlock(.block), now: Date())
                _ = try await social.submitSocialOperation(block, now: Date())
                let rejectedPair = V2ActorForwardPairWire(actorUserID: senderID, operationID: .init(uuid: UUID()), source: pair.source, targetRoomID: target.roomID)
                #expect(try await callerApp.forwardPair(rejectedPair, deadline: .now + .seconds(10)).errorCode == "DIRECT_MESSAGE_RESTRICTED")
                let unaffected = try await callerApp.directory.room(sourceRoom).call(policyApplicationRequest(room: sourceRoom, text: "unrelated group"),
                    principal: .user(senderID), deadline: .now + .seconds(10))
                try policyApplicationAccepted(unaffected)
                if holdSQL {
                    phase = "hold actual room SQL"
                    let transaction = Task {
                        try await database.transaction { transaction in
                            let sql = try #require(transaction as? any SQLDatabase)
                            _ = try await sql.raw("SELECT room_id FROM im_v2.rooms WHERE room_id=\(bind: roomUUID) FOR UPDATE").all()
                            let pid = try #require(try await sql.raw("SELECT pg_backend_pid()::bigint AS value").first(decoding: PolicyApplicationCount.self)).value
                            await held.wait(pid: pid)
                        }
                    }
                    holding = transaction
                    try await policyApplicationObserve { await held.pid != nil }
                    let pid = try #require(await held.pid)
                    let task = Task { try await callerApp.directory.room(sourceRoom).call(policyApplicationRequest(room: sourceRoom, text: "draining SQL"),
                        principal: .user(senderID), deadline: .now + .seconds(10)) }
                    sending = task
                    try await policyApplicationObserve {
                        try await sql.raw("SELECT count(*)::bigint AS value FROM pg_stat_activity WHERE \(bind: pid)::integer=ANY(pg_blocking_pids(pid))").first(decoding: PolicyApplicationCount.self)?.value ?? 0 > 0
                    }
                    phase = "incomplete shutdown retains actual SQL"
                    #expect(try await hostApp.stop(deadline: .now + .milliseconds(100)) == false)
                    #expect(try await callerApp.stop(deadline: .now + .milliseconds(100)) == false)
                    await held.release(); try await transaction.value
                    try policyApplicationAccepted(try await task.value)
                }
                phase = "complete application shutdown"
                #expect(try await callerApp.stop(deadline: .now + .seconds(10)))
                #expect(try await hostApp.stop(deadline: .now + .seconds(10)))
                #expect(await hostApp.readiness() == false)
                await #expect(throws: V2PolicyAuthorizationLifecycleError.closed) { try await pairs.bind(hostApp.reservations) }
                #expect(await hostApp.reservations.activePairCount() == 0)
                #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.messages").first(decoding: PolicyApplicationCount.self)?.value == (holdSQL ? 4 : 3))
                await resources.shutdownDurableSendOperations()
                await resources.shutdownRoomReadQueries(); await resources.shutdownRoomSubscriptionDelivery()
                await owners.shutdown(); await binding.close()
            } catch {
                Issue.record("Policy application failed during \(phase)")
                await held.release(); _ = await holding?.result; _ = await sending?.result
                if let caller { _ = try? await caller.stop(deadline: .now + .seconds(10)) }
                if let host { _ = try? await host.stop(deadline: .now + .seconds(10)) }
                await resources.shutdownDurableSendOperations()
                await resources.shutdownRoomReadQueries(); await resources.shutdownRoomSubscriptionDelivery()
                await owners.shutdown(); await binding.close(); throw error
            }
        }
    }
}
private struct PolicyApplicationEnvironment: V2RuntimeEnvironment {
    let path: String
    func value(for key: String) -> String? { key == "IMV2_ROOM_ACTOR_CONFIGURATION_FILE" ? path : nil }
}
private struct PolicyApplicationCount: Decodable { let value: Int64 }
private struct PolicyApplicationUUID: Decodable { let value: UUID }
private enum PolicyApplicationFailure: Error { case rejected, timeout }
private func policyApplicationRequest(room: RoomID, text: String) throws -> V2RoomRequest {
    .messaging(.sendOperation(try .init(command: .init(roomID: room, senderUserID: senderID,
        clientMessageID: .init(uuid: UUID()), text: text, limits: .init(maxUTF8Bytes: 128)),
        firstSubmissionDeadlineMilliseconds: UInt64(Date().timeIntervalSince1970 * 1000) + 60_000)))
}
private func policyApplicationAccepted(_ value: V2RoomResponse) throws {
    guard case .messaging(.sendOperation(.receipt(let receipt))) = value, case .accepted = receipt.outcome else { throw PolicyApplicationFailure.rejected }
}
private actor PolicyApplicationSQLHold {
    private(set) var pid: Int64?
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait(pid: Int64) async { self.pid = pid; if !released { await withCheckedContinuation { waiter = $0 } } }
    func release() { released = true; waiter?.resume(); waiter = nil }
}
private func policyApplicationObserve(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !(try await predicate()) {
        guard .now < deadline else { throw PolicyApplicationFailure.timeout }
        await Task.yield()
    }
}
