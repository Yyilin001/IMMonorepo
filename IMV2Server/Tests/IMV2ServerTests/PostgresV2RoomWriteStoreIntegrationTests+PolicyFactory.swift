import Foundation
import FluentKit
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("remote policy state waits retain no control SQL permit while a warm room commits independently", arguments: [false, true])
    func remotePolicyWaitDoesNotHoldDatabaseAdmission(usesCurrentState: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(), profile = try forwardImportTestProfile(), gate = PolicyRemotePreparationGate()
            try await sql.raw("UPDATE im_v2.shard_admission_pools SET valid_until=clock_timestamp()+interval '10 minutes'").run()
            var rooms: [RoomID] = []
            for recipient in [memberTwoUUID, memberThreeUUID] {
                let room = try await V2DirectRoomOperationTestFixture(database: database, capacityProfile: profile,
                    roomShardID: "room-a", roomID: .init(uuid: UUID()), now: { now }).openedIdentity(actorUserID: senderID,
                        operationID: .init(uuid: UUID()), targetUserID: .init(uuid: recipient),
                        firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
                rooms.append(room.roomID)
            }
            let admission = V2DatabaseWorkAdmissionController(policy: .init(maximumForegroundWriteInFlight: 1,
                maximumInteractiveReadInFlight: 1, maximumSyncInFlight: 1,
                maximumForegroundWriteQueued: 1, maximumInteractiveReadQueued: 1,
                maximumSyncQueued: 16, timeout: .seconds(5)))
            let owners = PostgresV2PolicyOwnerDirectory(journal: .init(database: database, stateReadAdmission: admission,
                roomDrainRequired: !usesCurrentState),
                dispatcher: .init(database: database, projectionDelivery: SuccessfulProjectionDelivery(),
                    legacyAuthorization: .init(controlDatabase: database, ownerDatabases: [:])),
                ownsScope: { $0 != V2PolicyAuthorizationScope.account(memberThreeUUID).key },
                revoke: { _ in throw V2PolicyAuthorizationLifecycleError.invalidTarget })
            let remote = PostgresV2RemotePolicyOwners(clientProvider: {
                await gate.hold()
                throw V2PolicyAuthorizationLifecycleError.invalidTarget
            }, localOwners: owners, resolve: { _ in throw V2PolicyAuthorizationLifecycleError.invalidTarget })
            let policies = V2RoomPolicyAuthorizationService(roomDatabase: database, controlDatabase: database,
                policyOwners: remote, endpoint: "room-a", maximumRooms: 2, usesCurrentState: usesCurrentState, roomPreparationAdmission: admission,
                controlPreparationAdmission: admission)
            // A fresh room registry has no installed snapshot, but can reuse
            // complete policy facts already owned by this process.
            let freshPolicies = V2RoomPolicyAuthorizationService(roomDatabase: database, controlDatabase: database,
                policyOwners: remote, endpoint: "room-a-fresh", maximumRooms: 2, usesCurrentState: usesCurrentState, roomPreparationAdmission: admission,
                controlPreparationAdmission: admission)
            let store = PostgresV2MessageSendOperationStore(database: database,
                writes: PostgresV2RoomWriteStore(database: database,
                    strangerMessagePolicy: try .init(maximumMessagesPerWindow: 10, window: 86_400), contentReviewMode: .disabled)
                    .usingControlDatabase(database))
            @Sendable func command(_ room: RoomID) throws -> V2MessageSendOperationCommand {
                try .init(command: .init(roomID: room, senderUserID: senderID, clientMessageID: .init(uuid: UUID()),
                    text: "independent room", limits: .init(maxUTF8Bytes: 64)),
                    firstSubmissionDeadlineMilliseconds: UInt64(now.timeIntervalSince1970 * 1000) + 60_000)
            }
            let warmRoom = rooms[0]
            do {
                try await withRoomActivation(database: database, roomID: rooms[0]) { firstToken in
                    try await withRoomActivation(database: database, roomID: rooms[1]) { secondToken in
                        @Sendable func sendWarm() async throws {
                            let prepared = try await policies.prepareOwnerBatches(store: store, requests: [
                                .init(commands: [command(warmRoom)], token: firstToken, deadline: .now + .seconds(10))
                            ], now: Date.init)
                            let results = try await store.executeIndependentRoomTurns(prepared.map { try $0.get() },
                                capacityProfile: profile, identifiers: .init(), now: Date.init)
                            guard case .sendOperation(.receipt(let receipt))? = try results[0].get().first,
                                  case .accepted = receipt.outcome else { throw V2RoomWriteStoreError.corruptPersistenceState }
                        }
                        guard case .admitted = await admission.acquire(.sync, callerDeadline: .now + .seconds(5)) else {
                            throw V2PolicyAuthorizationLifecycleError.busy
                        }
                        let warming = Task { try await sendWarm() }
                        var permitHeld = true
                        do {
                            let deadline = ContinuousClock.now + .seconds(5)
                            while await admission.snapshot().sync.queued != 1, .now < deadline { await Task.yield() }
                            let waiting = await admission.snapshot().sync
                            try #require(waiting.queued == 1)
                            // Production registry creation must obtain its
                            // SQL permit before reaching any policy Owner.
                            #expect(await owners.pressure().owners == 0)
                            #expect(await gate.entered == false)
                            await admission.release(.sync)
                            permitHeld = false
                            try await warming.value
                        } catch {
                            if permitHeld { await admission.release(.sync) }
                            _ = await warming.result
                            throw error
                        }
                        let coldCommand = try command(rooms[1])
                        let cold = Task {
                            try await policies.prepareOwnerBatches(store: store, requests: [
                                .init(commands: [coldCommand], token: secondToken, deadline: .now + .seconds(10))
                            ], now: Date.init)
                        }
                        do {
                            let deadline = ContinuousClock.now + .seconds(5)
                            while !(await gate.entered), .now < deadline { await Task.yield() }
                            #expect(await gate.entered)
                            let waiting = await admission.snapshot().value(for: .sync)
                            #expect(waiting.inFlight == 0 && waiting.queued == 0)
                            try await v2WithAdmittedRoomDatabaseWork(admission, workClass: .sync,
                                callerDeadline: .now + .seconds(2)) {
                                let value = try await sql.raw("SELECT 1::bigint AS value").first(decoding: PolicyFactoryCount.self)?.value
                                #expect(value == 1)
                            }
                            try await sendWarm()
                            let fresh = try await freshPolicies.prepareOwnerBatches(store: store, requests: [
                                .init(commands: [command(rooms[0])], token: firstToken, deadline: .now + .seconds(10))
                            ], now: Date.init)
                            let freshResults = try await store.executeIndependentRoomTurns(fresh.map { try $0.get() },
                                capacityProfile: profile, identifiers: .init(), now: Date.init)
                            guard case .sendOperation(.receipt(let freshReceipt))? = try freshResults[0].get().first,
                                  case .accepted = freshReceipt.outcome else { throw V2RoomWriteStoreError.corruptPersistenceState }
                            #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.messages WHERE room_id=\(bind: rooms[0].uuidValue!)").first(decoding: PolicyFactoryCount.self)?.value == 3)
                            #expect(await gate.released == false)
                            await gate.release()
                            let results = try await cold.value
                            guard case .failure = results[0] else { throw V2RoomWriteStoreError.corruptPersistenceState }
                        } catch { await gate.release(); _ = await cold.result; throw error }
                    }
                }
                try await freshPolicies.shutdown(); try await policies.shutdown(); await owners.shutdown()
            } catch { await gate.release(); try? await freshPolicies.shutdown(); try? await policies.shutdown(); await owners.shutdown(); throw error }
        }
    }

    @Test("policy owner preparation combines rooms while isolating permanent fingerprint conflicts and invalid token bindings")
    func policyPreparationCombinesRooms() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(), profile = try forwardImportTestProfile()
            try await sql.raw("UPDATE im_v2.shard_admission_pools SET valid_until=clock_timestamp()+interval '10 minutes'").run()
            var rooms: [RoomID] = []
            for recipient in [memberTwoUUID, memberThreeUUID] {
                let room = try await V2DirectRoomOperationTestFixture(database: database, capacityProfile: profile,
                    roomShardID: "room-a", roomID: .init(uuid: UUID()), now: { now }).openedIdentity(actorUserID: senderID,
                        operationID: .init(uuid: UUID()), targetUserID: .init(uuid: recipient),
                        firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
                rooms.append(room.roomID)
            }
            let router = PolicyFactoryRouter(), legacy = V2DirectAuthorizationCoordinator(controlDatabase: database, ownerDatabases: [:])
            let owners = PostgresV2PolicyOwnerDirectory(journal: .init(database: database),
                dispatcher: .init(database: database, projectionDelivery: SuccessfulProjectionDelivery(), legacyAuthorization: legacy),
                revoke: { try await router.revoke($0) })
            let policies = V2RoomPolicyAuthorizationService(roomDatabase: database, controlDatabase: database,
                policyOwners: owners, endpoint: "room-a", maximumRooms: 2)
            await router.install(policies)
            let store = PostgresV2MessageSendOperationStore(database: database,
                writes: PostgresV2RoomWriteStore(database: database,
                    strangerMessagePolicy: try .init(maximumMessagesPerWindow: 10, window: 86_400), contentReviewMode: .disabled)
                    .usingControlDatabase(database))
            let operation = ClientMessageID(uuid: UUID()), expiry = UInt64(now.timeIntervalSince1970 * 1000) + 60_000
            func command(_ room: RoomID, _ operation: ClientMessageID, _ text: String) throws -> V2MessageSendOperationCommand {
                try .init(command: .init(roomID: room, senderUserID: senderID, clientMessageID: operation,
                    text: text, limits: .init(maxUTF8Bytes: 64)), firstSubmissionDeadlineMilliseconds: expiry)
            }
            do {
                try await withRoomActivation(database: database, roomID: rooms[0]) { firstToken in
                    try await withRoomActivation(database: database, roomID: rooms[1]) { secondToken in
                        let first = try command(rooms[0], operation, "first room"), second = try command(rooms[1], operation, "second room")
                        let prepared = try await policies.prepareOwnerBatches(store: store, requests: [
                            .init(commands: [first], token: firstToken, deadline: .now + .seconds(5)),
                            .init(commands: [second], token: secondToken, deadline: .now + .seconds(5))
                        ], now: Date.init)
                        let accepted = try await store.executeIndependentRoomTurns(prepared.map { try $0.get() },
                            capacityProfile: profile, identifiers: .init(), now: Date.init)
                        for result in accepted {
                            guard case .sendOperation(.receipt(let receipt))? = try result.get().first,
                                  case .accepted = receipt.outcome else { throw V2RoomWriteStoreError.corruptPersistenceState }
                        }
                        let changed = try command(rooms[1], operation, "changed content")
                        let fresh = try command(rooms[1], .init(uuid: UUID()), "healthy neighbour")
                        let mixed = try await policies.prepareOwnerBatches(store: store, requests: [
                            .init(commands: [first], token: firstToken, deadline: .now + .seconds(5)),
                            .init(commands: [changed, fresh], token: secondToken, deadline: .now + .seconds(5)),
                            .init(commands: [first], token: secondToken, deadline: .now + .seconds(5))
                        ], now: Date.init)
                        guard case .failure(let error) = mixed[2], error as? V2RoomCallFailure == .notAccepted(.invalidRequest) else {
                            throw V2RoomWriteStoreError.corruptPersistenceState
                        }
                        let result = try await store.executeIndependentRoomTurns(mixed.prefix(2).map { try $0.get() },
                            capacityProfile: profile, identifiers: .init(), now: Date.init)
                        #expect(try result[0].get() == accepted[0].get())
                        let secondResults = try result[1].get()
                        #expect(secondResults[0] == .sendOperation(.fingerprintConflict))
                        guard case .sendOperation(.receipt(let receipt)) = secondResults[1], case .accepted = receipt.outcome else {
                            throw V2RoomWriteStoreError.corruptPersistenceState
                        }
                        #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.direct_authorization_intents").first(decoding: PolicyFactoryCount.self)?.value == 0)
                        #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.messages").first(decoding: PolicyFactoryCount.self)?.value == 3)
                    }
                }
                try await policies.shutdown(); await owners.shutdown(); await router.clear()
            } catch { try? await policies.shutdown(); await owners.shutdown(); await router.clear(); throw error }
        }
    }

    @Test("production room factory isolates group account policy from pair changes and retires authorization", arguments: [false, true])
    func policyAuthorizationFactoryAcceptance(group: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, controlSQL, ownerSQL, groupRoom in
            let profile = try forwardImportTestProfile(), now = Date()
            try await ownerSQL.raw("UPDATE im_v2.shard_admission_pools SET valid_until=clock_timestamp()+interval '10 minutes'").run()
            let roomID: RoomID
            if group { roomID = groupRoom }
            else {
            let room = try await V2DirectRoomOperationTestFixture(store: PostgresV2DirectMessagingStore(database: owner,
                identityReader: PostgresV2DirectRoomIdentityReader(database: control), projectionDelivery: SuccessfulProjectionDelivery()),
                capacityProfile: profile, roomShardID: "room-b", now: { now }).openedIdentity(actorUserID: senderID,
                    operationID: .init(uuid: UUID()), targetUserID: .init(uuid: memberTwoUUID),
                    firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
            roomID = room.roomID
            }
            try await controlSQL.raw("UPDATE im_v2.shard_admission_pools SET valid_until=clock_timestamp()+interval '10 minutes'").run()
            let exports = try await policyFactoryExports(database: control, target: roomID, profile: profile, now: now)
            let router = PolicyFactoryRouter()
            let legacy = V2DirectAuthorizationCoordinator(controlDatabase: control, ownerDatabases: [:])
            let policyOwners = PostgresV2PolicyOwnerDirectory(journal: .init(database: control),
                dispatcher: .init(database: control, projectionDelivery: SuccessfulProjectionDelivery(), legacyAuthorization: legacy),
                revoke: { try await router.revoke($0) })
            let coldAdmission = V2DatabaseWorkAdmissionController(policy: .init(maximumForegroundWriteInFlight: 1,
                maximumInteractiveReadInFlight: 1, maximumSyncInFlight: 1,
                maximumForegroundWriteQueued: 1, maximumInteractiveReadQueued: 1,
                maximumSyncQueued: 2, timeout: .seconds(2)))
            let coldMetrics = V2SendOperationBatchMetrics()
            let policies = V2RoomPolicyAuthorizationService(roomDatabase: owner, controlDatabase: control,
                policyOwners: policyOwners, endpoint: "room-b", maximumRooms: 1,
                controlPreparationAdmission: coldAdmission, sendOperationMetrics: coldMetrics)
            await router.install(policies)
            let writes = PostgresV2RoomWriteStore(database: owner,
                strangerMessagePolicy: try .init(maximumMessagesPerWindow: 10, window: 86_400), contentReviewMode: .disabled)
                .usingControlDatabase(control)
            let baseResources = try V2RoomServerOwnerResources(database: owner, writes: writes, membershipIdentities: V2PostgresMembershipIdentitySnapshotValidator(database: owner),
                invitationIdentities: PostgresV2GroupInvitationIdentityReader(database: owner),
                invitationSecretIssuer: .init(rawKey: Data(repeating: 0x73, count: 32)),
                receiptProjectionDelivery: SuccessfulProjectionDelivery(), capacityProfile: profile,
                messageLimits: .init(maxUTF8Bytes: 64), maximumEditBytes: 64,
                contentReviewMode: .disabled, queryBatchConfiguration: .init())
            let resources = try baseResources.usingPolicyAuthorizations(policies)
            #expect(throws: V2ActorContractError.invalidConfiguration("physical owner policy authorization aliases")) {
                try V2RoomServerActivationFactory(owners: ["room-b": resources, "room-alias": baseResources], safetyActorUserID: senderID)
            }
            let leases = try V2RoomServerLeaseStore(databases: ["room-b": owner])
            let factory = try V2RoomServerActivationFactory(owners: ["room-b": resources], safetyActorUserID: senderID).runtimeFactory()
            let configuration = try V2RoomRuntimeConfiguration()
            let host = V2RoomActivationHost<V2RoomRequest, V2RoomResponse>(identity: .init(hostID: .init(uuid: UUID()), incarnationID: UUID()),
                leaseStore: leases, configuration: configuration, budget: .init(configuration: configuration),
                classify: { $0.turnSchedulingClass }, factory: factory)
            await host.start()
            do {
                guard case .ready(let token) = try await host.activate(roomID: roomID,
                    owner: .init(shardID: "room-b", epoch: 0), deadline: .now + .seconds(10)) else {
                    throw V2RoomCallFailure.notAccepted(.notReady)
                }
                func request(_ text: String) throws -> V2RoomRequest {
                    .messaging(.sendOperation(try .init(command: .init(roomID: roomID, senderUserID: senderID,
                        clientMessageID: .init(uuid: UUID()), text: text, limits: .init(maxUTF8Bytes: 64)),
                        firstSubmissionDeadlineMilliseconds: UInt64(Date().timeIntervalSince1970 * 1000) + 60_000)))
                }
                let first = try request("factory policy accepted")
                let accepted = try await host.invoke(token: token, encodedRequest: JSONEncoder().encode(first), deadline: .now + .seconds(10))
                guard case .messaging(.sendOperation(.receipt(let receipt))) = accepted, case .accepted = receipt.outcome else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                let encodedForwards = try exports.map { value in
                    try JSONEncoder().encode(V2RoomRequest.forward(.importExport(V2ActorForwardExportWire(domain: value))))
                }
                #expect(try await ownerSQL.raw("SELECT command_window_used AS value FROM im_v2.room_admission WHERE room_id=\(bind: roomID.uuidValue!)").first(decoding: PolicyFactoryCount.self)?.value == 1)
                // Ordinary sends precharge the shared pool's entire small
                // window. Forwarding must consume that same cached budget.
                #expect(try await ownerSQL.raw("SELECT command_window_used AS value FROM im_v2.shard_admission_pools WHERE room_shard_id='room-b'").first(decoding: PolicyFactoryCount.self)?.value == 10)
                #expect(await coldAdmission.snapshot().sync.admittedRequests == 1)
                #expect(await coldAdmission.snapshot().syncInFlight == 0)
                let firstForward = try await v2WithAdmittedRoomDatabaseWork(coldAdmission, workClass: .sync,
                    callerDeadline: .now + .seconds(10)) {
                    #expect(await coldAdmission.snapshot().syncInFlight == 1)
                    // Occupy all control preparation capacity. This warm
                    // room must still forward using its registered snapshot.
                    return try await host.invoke(token: token, encodedRequest: encodedForwards[0], deadline: .now + .seconds(10))
                }
                guard case .forward(.imported(.accepted)) = firstForward else { throw PolicyFactoryForwardError.unexpectedForward(firstForward) }
                let social = PostgresV2SocialRelationshipStore(database: control, projectionDelivery: SuccessfulProjectionDelivery(),
                    authorizationCoordinator: legacy).usingPolicyOwners(policyOwners)
                let block = try await social.freezeSocialFixture(actorUserID: senderID, targetUserID: .init(uuid: memberTwoUUID),
                    operation: .userBlock(.init(uuid: UUID())), action: .userBlock(.block), now: Date())
                _ = try await social.submitSocialOperation(block, now: Date())
                if group {
                    let preferences = PostgresV2AccountPreferenceOperationStore(database: control,
                        projectionDelivery: SuccessfulProjectionDelivery(), authorizationCoordinator: legacy)
                        .usingPolicyOwners(policyOwners)
                    let preference = try await preferences.freezePreferenceFixture(owner: senderID,
                        operation: .strangerMessagePreference(.init(uuid: UUID())), value: .strangerMessage(.deny), now: Date())
                    _ = try await preferences.submit(preference, now: Date())
                    #expect(try await controlSQL.raw("SELECT revision AS value FROM im_v2.policy_authorization_scopes WHERE scope_key=\(bind: V2PolicyAuthorizationScope.account(senderUUID).key)").first(decoding: PolicyFactoryCount.self)?.value == 1)
                    #expect(try await controlSQL.raw("SELECT revision AS value FROM im_v2.policy_authorization_scopes WHERE scope_key=\(bind: V2PolicyAuthorizationScope.stranger(senderUUID).key)").first(decoding: PolicyFactoryCount.self)?.value == 2)
                    #expect(try await controlSQL.raw("SELECT count(*)::bigint AS value FROM im_v2.policy_authorization_holders WHERE room_id=\(bind: roomID.uuidValue!) AND NOT revoked").first(decoding: PolicyFactoryCount.self)?.value == 1)
                    let hidden = ["public_user_profiles", "special_accounts", "account_disables", "user_blocks",
                        "user_relationships", "user_stranger_message_preferences"]
                    for sql in [controlSQL, ownerSQL] {
                        for table in hidden {
                            try await sql.raw("ALTER TABLE im_v2.\(unsafeRaw: table) RENAME TO \(unsafeRaw: table + "_group_hidden")").run()
                        }
                    }
                    let warmRequest = try JSONEncoder().encode(request("group ignores pair block"))
                    let unaffected = try await v2WithAdmittedRoomDatabaseWork(coldAdmission, workClass: .sync,
                        callerDeadline: .now + .seconds(10)) {
                        #expect(await coldAdmission.snapshot().syncInFlight == 1)
                        return try await host.invoke(token: token, encodedRequest: warmRequest, deadline: .now + .seconds(10))
                    }
                    guard case .messaging(.sendOperation(.receipt(let value))) = unaffected,
                          case .accepted = value.outcome else { throw V2RoomWriteStoreError.corruptPersistenceState }
                    let groupForward = try await host.invoke(token: token, encodedRequest: encodedForwards[1], deadline: .now + .seconds(10))
                    guard case .forward(.imported(.accepted)) = groupForward else { throw PolicyFactoryForwardError.cachedImport }
                    #expect(try await controlSQL.raw("SELECT count(*)::bigint AS value FROM im_v2.policy_authorization_holders WHERE room_id=\(bind: roomID.uuidValue!) AND NOT revoked").first(decoding: PolicyFactoryCount.self)?.value == 1)
                    try await ownerSQL.raw("UPDATE im_v2.room_memberships SET left_revision=0 WHERE room_id=\(bind: roomID.uuidValue!) AND user_id=\(bind: senderUUID)").run()
                    let nonmember = try await host.invoke(token: token,
                        encodedRequest: JSONEncoder().encode(request("former member denied")), deadline: .now + .seconds(10))
                    guard case .messaging(.sendOperation(.receipt(let nonmemberReceipt))) = nonmember,
                          nonmemberReceipt.outcome == .rejected(.permissionDenied) else { throw V2RoomWriteStoreError.corruptPersistenceState }
                    try await ownerSQL.raw("UPDATE im_v2.room_memberships SET left_revision=NULL WHERE room_id=\(bind: roomID.uuidValue!) AND user_id=\(bind: senderUUID)").run()
                    try await ownerSQL.raw("""
                        INSERT INTO im_v2.room_member_mutes(room_id,user_id,mute_until,actor_user_id,operation_id,created_at)
                        VALUES (\(bind: roomID.uuidValue!),\(bind: senderUUID),clock_timestamp()+interval '1 minute',\(bind: memberTwoUUID),\(bind: UUID()),clock_timestamp())
                        """).run()
                    let muted = try await host.invoke(token: token,
                        encodedRequest: JSONEncoder().encode(request("muted member denied")), deadline: .now + .seconds(10))
                    guard case .messaging(.sendOperation(.receipt(let muteReceipt))) = muted,
                          muteReceipt.outcome == .rejected(.permissionDenied) else { throw V2RoomWriteStoreError.corruptPersistenceState }
                    try await ownerSQL.raw("DELETE FROM im_v2.room_member_mutes WHERE room_id=\(bind: roomID.uuidValue!)").run()
                    for sql in [controlSQL, ownerSQL] {
                        for table in hidden {
                            try await sql.raw("ALTER TABLE im_v2.\(unsafeRaw: table + "_group_hidden") RENAME TO \(unsafeRaw: table)").run()
                        }
                    }
                    let disable = try V2PostgresAccountDisableService(database: control, operatorPrincipal: "operator:test",
                        authorizationCoordinator: legacy).usingPolicyOwners(policyOwners)
                    _ = try await disable.disable(.init(userID: senderID, operationID: UUID(), reason: .policyEnforcement))
                }
                let rejectedForward = try await host.invoke(token: token, encodedRequest: encodedForwards[group ? 2 : 1], deadline: .now + .seconds(10))
                guard case .forward(.imported(.rejected(let code))) = rejectedForward,
                      code == (group ? "FORBIDDEN" : "DIRECT_MESSAGE_RESTRICTED") else {
                    throw PolicyFactoryForwardError.deniedImport
                }
                #expect(try await host.invoke(token: token, encodedRequest: encodedForwards[0], deadline: .now + .seconds(10)) == firstForward)
                let denied = try await host.invoke(token: token, encodedRequest: JSONEncoder().encode(request("factory policy denied")),
                    deadline: .now + .seconds(10))
                guard case .messaging(.sendOperation(.receipt(let denial))) = denied,
                      denial.outcome == .rejected(group ? .permissionDenied : .directPolicyDenied) else { throw V2RoomWriteStoreError.corruptPersistenceState }
                #expect(try await host.invoke(token: token, encodedRequest: JSONEncoder().encode(first), deadline: .now + .seconds(10)) == accepted)
                let combined = try #require(resources.sendOperationMetrics.sendOperationBatchMetricsSnapshot().sqlContinuations[.durableFenceCombined])
                #expect(combined.settledToResumedCount == (group ? 6 : 3))
                #expect(combined.resumedToDispatchCount == (group ? 6 : 3))
                #expect(combined.settledNotResumed == 0 && combined.resumedNotDispatched == 0)
                #expect(combined.noNextDispatch == 0)
                #expect(try await controlSQL.raw("SELECT count(*)::bigint AS value FROM im_v2.direct_authorization_intents").first(decoding: PolicyFactoryCount.self)?.value == 0)
                #expect(try await ownerSQL.raw("SELECT count(*)::bigint AS value FROM im_v2.direct_authorization_receipts").first(decoding: PolicyFactoryCount.self)?.value == 0)
                #expect(try await ownerSQL.raw("SELECT count(*)::bigint AS value FROM im_v2.messages WHERE room_id=\(bind: roomID.uuidValue!)").first(decoding: PolicyFactoryCount.self)?.value == (group ? 4 : 2))
                let coldDrained = await coldAdmission.snapshot()
                #expect(coldDrained.syncInFlight == 0 && coldDrained.syncQueued == 0)
                for stage in [V2SendOperationStage.policyOwnerState, .policySnapshotRegistration] {
                    let sample = try #require(coldMetrics.sendOperationBatchMetricsSnapshot().stages[stage])
                    #expect(sample.count == 2 && sample.inFlight == 0 && sample.totalMilliseconds > 0)
                }
                #expect(await host.stop(deadline: .now + .seconds(10)).completed)
                #expect(try await ownerSQL.raw("SELECT count(*)::bigint AS value FROM im_v2.room_policy_authorization_leases WHERE NOT revoked").first(decoding: PolicyFactoryCount.self)?.value == 0)
                await resources.shutdownDurableSendOperations()
                await leases.shutdownLifecycle(); await leases.shutdownRenewals()
                await policyOwners.shutdown(); await router.clear()
            } catch {
                _ = await host.stop(deadline: .now + .seconds(10))
                await resources.shutdownDurableSendOperations()
                await leases.shutdownLifecycle(); await leases.shutdownRenewals()
                await policyOwners.shutdown(); await router.clear(); throw error
            }
        }
    }
    func policyFactoryExports(database: any Database, target: RoomID, profile: V2CapacityProfile, now: Date) async throws -> [V2ForwardExport] {
        let sourceRoom = RoomID(uuid: roomUUID)
        let write = PostgresV2RoomWriteStore(database: database,
            strangerMessagePolicy: try .init(maximumMessagesPerWindow: 10, window: 86_400), contentReviewMode: .disabled)
        let command = try V2SendMessageCommand(roomID: sourceRoom, senderUserID: senderID,
            clientMessageID: .init(uuid: UUID()), text: "forward source", limits: .init(maxUTF8Bytes: 64))
        let identifiers = try V2AcceptanceIDFactory().make(at: now)
        let outcome = try await write.accept(command: command, capacityProfile: profile, identifiers: identifiers, now: now)
        guard case .accepted(let receipt) = outcome else { throw PolicyFactoryForwardError.sourceAccept }
        let reference = try V2ForwardMessageReference(roomID: sourceRoom, messageID: receipt.messageID, revision: .init(1))
        let sourceRoute = try V2RoomShardRoute(shardID: "room-a", epoch: 0)
        let targetRoute = try V2RoomShardRoute(shardID: "room-b", epoch: 0)
        return try await withRoomActivation(database: database, roomID: sourceRoom) { token in
            let exporter = try PostgresV2ForwardExportStore(database: database).usingActivationToken(token)
            var values: [V2ForwardExport] = []
            for _ in 0..<3 {
                let outcome = try await exporter.prepareForDelivery(actorUserID: senderID, operationID: .init(uuid: UUID()),
                    source: reference, sourceRoute: sourceRoute, targetRoomID: target, targetRoute: targetRoute, now: now)
                guard case .export(let value) = outcome else { throw V2ForwardExportError.corruptPersistenceState }
                values.append(value)
            }
            return values
        }
    }
}
private struct PolicyFactoryCount: Decodable { let value: Int64 }
private enum PolicyFactoryForwardError: Error {
    case sourceAccept, cachedImport, deniedImport
    case unexpectedForward(V2RoomResponse)
}
private actor PolicyFactoryRouter {
    private var service: V2RoomPolicyAuthorizationService?
    func install(_ service: V2RoomPolicyAuthorizationService) { self.service = service }
    func clear() { service = nil }
    func revoke(_ holder: V2PolicyAuthorizationHolder) async throws -> V2PolicyAuthorizationRevocationProof {
        guard let service else { throw V2PolicyAuthorizationLifecycleError.closed }
        return try await service.revoke(holder)
    }
}

private actor PolicyRemotePreparationGate {
    private(set) var entered = false
    private(set) var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}
