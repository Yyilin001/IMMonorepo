import Foundation
import FluentKit
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerApplication
import IMV2ServerContracts
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("confirmed replies omit stranger dependencies while current blocks still deny",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func establishedReplyOmitsStrangerDependency() async throws {
        try await withForwardOwnerDatabases(mode: .standard, messageSessionDefaults: true) { control, owner, controlSQL, ownerSQL, _ in
            let now = Date(), profile = try forwardImportTestProfile()
            try await ownerSQL.raw("UPDATE im_v2.shard_admission_pools SET valid_until=clock_timestamp()+interval '10 minutes'").run()
            let opened = try await V2DirectRoomOperationTestFixture(store: PostgresV2DirectMessagingStore(database: owner,
                identityReader: PostgresV2DirectRoomIdentityReader(database: control), projectionDelivery: SuccessfulProjectionDelivery()),
                capacityProfile: profile, roomShardID: "room-b", now: { now }).openedIdentity(actorUserID: senderID,
                    operationID: .init(uuid: UUID()), targetUserID: .init(uuid: memberTwoUUID),
                    firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
            let writes = PostgresV2RoomWriteStore(database: owner,
                strangerMessagePolicy: try .init(maximumMessagesPerWindow: 10, window: 86_400), contentReviewMode: .disabled)
                .usingControlDatabase(control)
            let seed = try V2SendMessageService(store: V2PolicyAuthorizedTestWriteStore(database: owner,
                controlDatabase: control, store: writes, shardID: "room-b", epoch: 0), capacityProfile: profile, limits: .init(maxUTF8Bytes: 64))
            for user in [senderID, UserID(uuid: memberTwoUUID)] {
                guard case .accepted = try await seed.send(.init(roomID: opened.roomID, actorUserID: user,
                    clientMessageID: .init(uuid: UUID()), text: "establish conversation")) else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
            }
            try await controlSQL.raw("INSERT INTO im_v2.user_stranger_message_preferences VALUES (\(bind: memberTwoUUID),false,clock_timestamp())").run()
            let owners = PostgresV2PolicyOwnerDirectory(journal: .init(database: control),
                dispatcher: .init(database: control, projectionDelivery: SuccessfulProjectionDelivery()))
            let policies = V2RoomPolicyAuthorizationService(roomDatabase: owner,
                policyOwners: owners, endpoint: "room-b", maximumRooms: 1)
            let sendDatabase = try V2EventLoopBalancedDatabase(databases: [owner],
                loanPolicy: .init(maximumConnections: 2, reservedRenewalConnections: 0,
                    maximumQueued: 32, maximumWait: .seconds(10)), sessionTimeouts: .default)
            let resources = try V2RoomServerOwnerResources(database: owner, sendDatabase: sendDatabase, writes: writes,
                membershipIdentities: V2PostgresMembershipIdentitySnapshotValidator(database: owner),
                invitationIdentities: PostgresV2GroupInvitationIdentityReader(database: owner),
                invitationSecretIssuer: .init(rawKey: Data(repeating: 0x73, count: 32)),
                receiptProjectionDelivery: SuccessfulProjectionDelivery(), capacityProfile: profile,
                messageLimits: .init(maxUTF8Bytes: 64), maximumEditBytes: 64,
                contentReviewMode: .disabled, queryBatchConfiguration: .init()).usingPolicyAuthorizations(policies)
            let leases = try V2RoomServerLeaseStore(databases: ["room-b": owner])
            let configuration = try V2RoomRuntimeConfiguration()
            let host = V2RoomActivationHost<V2RoomRequest, V2RoomResponse>(
                identity: .init(hostID: .init(uuid: UUID()), incarnationID: UUID()), leaseStore: leases,
                configuration: configuration, budget: .init(configuration: configuration), classify: { $0.turnSchedulingClass },
                factory: try V2RoomServerActivationFactory(owners: ["room-b": resources], safetyActorUserID: senderID).runtimeFactory())
            await host.start()
            var hidden = false
            do {
                try await V2PostgresSessionReadiness.verify(database: sendDatabase, timeouts: .default)
                guard case .ready(let token) = try await host.activate(roomID: opened.roomID,
                    owner: .init(shardID: "room-b", epoch: 0), deadline: .now + .seconds(10)) else {
                    throw V2RoomCallFailure.notAccepted(.notReady)
                }
                let first = try await host.invoke(token: token, encodedRequest: repliedRequest(room: opened.roomID), deadline: .now + .seconds(10))
                try repliedAccepted(first)
                #expect(try await owners.cachedSnapshots(scopes: [.stranger(memberTwoUUID)]) == nil)
                // Warm sends must not request a missing stranger scope. A cold
                // reader would fail SQL name resolution after this rename.
                try await controlSQL.raw("ALTER TABLE im_v2.user_stranger_message_preferences RENAME TO stranger_reply_hidden").run()
                hidden = true
                try repliedAccepted(try await host.invoke(token: token, encodedRequest: repliedRequest(room: opened.roomID), deadline: .now + .seconds(10)))
                #expect(resources.sendOperationMetrics.sendOperationBatchMetricsSnapshot().stages[.ownerSingleStatement]?.count == 2)
                try await controlSQL.raw("ALTER TABLE im_v2.stranger_reply_hidden RENAME TO user_stranger_message_preferences").run()
                hidden = false
                let social = PostgresV2SocialRelationshipStore(database: control, projectionDelivery: SuccessfulProjectionDelivery(), policyOwners: owners)
                let block = try await social.freezeSocialFixture(actorUserID: senderID, targetUserID: .init(uuid: memberTwoUUID),
                    operation: .userBlock(.init(uuid: UUID())), action: .userBlock(.block), now: Date())
                _ = try await social.submitSocialOperation(block)
                let response = try await host.invoke(token: token, encodedRequest: repliedRequest(room: opened.roomID), deadline: .now + .seconds(10))
                guard case .messaging(.sendOperation(.receipt(let receipt))) = response else { throw V2RoomWriteStoreError.corruptPersistenceState }
                #expect(receipt.outcome == .rejected(.directPolicyDenied))
                #expect(try await owners.cachedSnapshots(scopes: [.stranger(memberTwoUUID)]) == nil)
                #expect(try await ownerSQL.raw("SELECT count(*)::bigint AS value FROM im_v2.messages WHERE room_id=\(bind: opened.roomID.uuidValue!)").first(decoding: RepliedCount.self)?.value == 4)
                #expect(await host.stop(deadline: .now + .seconds(10)).completed)
                await resources.shutdownDurableSendOperations()
                await leases.shutdownLifecycle(); await leases.shutdownRenewals()
                await policies.shutdown(); await owners.shutdown()
            } catch {
                if hidden { try? await controlSQL.raw("ALTER TABLE im_v2.stranger_reply_hidden RENAME TO user_stranger_message_preferences").run() }
                _ = await host.stop(deadline: .now + .seconds(10))
                await resources.shutdownDurableSendOperations()
                await leases.shutdownLifecycle(); await leases.shutdownRenewals()
                await policies.shutdown(); await owners.shutdown()
                throw error
            }
        }
    }
}
private struct RepliedCount: Decodable { let value: Int64 }
private func repliedRequest(room: RoomID) throws -> Data {
    try JSONEncoder().encode(V2RoomRequest.messaging(.sendOperation(.init(command: .init(roomID: room,
        senderUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "replied", limits: .init(maxUTF8Bytes: 64)),
        firstSubmissionDeadlineMilliseconds: UInt64(Date().timeIntervalSince1970 * 1000) + 60_000))))
}
private func repliedAccepted(_ response: V2RoomResponse) throws {
    guard case .messaging(.sendOperation(.receipt(let receipt))) = response, case .accepted = receipt.outcome else {
        throw V2RoomWriteStoreError.corruptPersistenceState
    }
}
