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
    @Test("committed policy mutations refresh warm production rooms from memory and preserve unrelated rooms",
          arguments: ["block", "remove", "stranger", "disable"])
    func warmRoomPolicyMutationIsolation(kind: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard, messageSessionDefaults: true) { control, owner, controlSQL, ownerSQL, _ in
            let now = Date(), profile = try forwardImportTestProfile()
            try await ownerSQL.raw("UPDATE im_v2.shard_admission_pools SET valid_until=clock_timestamp()+interval '10 minutes'").run()
            if kind == "remove" {
                try await controlSQL.raw("""
                    INSERT INTO im_v2.user_relationships
                    VALUES (LEAST(\(bind: senderUUID)::uuid,\(bind: memberTwoUUID)::uuid),
                        GREATEST(\(bind: senderUUID)::uuid,\(bind: memberTwoUUID)::uuid),
                        'accepted',\(bind: senderUUID),clock_timestamp())
                    """).run()
            }
            var rooms: [RoomID] = []
            for recipient in [memberTwoUUID, memberThreeUUID] {
                let opened = try await V2DirectRoomOperationTestFixture(store: PostgresV2DirectMessagingStore(database: owner,
                    identityReader: PostgresV2DirectRoomIdentityReader(database: control), projectionDelivery: SuccessfulProjectionDelivery()),
                    capacityProfile: profile, roomShardID: "room-b", now: { now }).openedIdentity(actorUserID: senderID,
                        operationID: .init(uuid: UUID()), targetUserID: .init(uuid: recipient),
                        firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
                rooms.append(opened.roomID)
            }
            let coldMetrics = V2SendOperationBatchMetrics()
            let owners = PostgresV2PolicyOwnerDirectory(journal: .init(database: control,
                stateMetrics: coldMetrics),
                dispatcher: .init(database: control, projectionDelivery: SuccessfulProjectionDelivery()))
            let policies = V2RoomPolicyAuthorizationService(roomDatabase: owner,
                policyOwners: owners, endpoint: "room-b", maximumRooms: 2,
                sendOperationMetrics: coldMetrics)
            let social = PostgresV2SocialRelationshipStore(database: control, projectionDelivery: SuccessfulProjectionDelivery(), policyOwners: owners)
            let preferences = PostgresV2AccountPreferenceOperationStore(database: control,
                projectionDelivery: SuccessfulProjectionDelivery(), policyOwners: owners)
            let deniedPreference = try await preferences.freezePreferenceFixture(owner: .init(uuid: memberTwoUUID),
                operation: .strangerMessagePreference(.init(uuid: UUID())), value: .strangerMessage(.deny), now: now)
            if kind == "remove" {
                // Friends do not depend on stranger settings. After removal the
                // newly required dependency is already in its owning memory.
                _ = try await preferences.submit(deniedPreference, now: now)
            }
            let writes = PostgresV2RoomWriteStore(database: owner,
                strangerMessagePolicy: try .init(maximumMessagesPerWindow: 10, window: 86_400), contentReviewMode: .disabled)
                .usingControlDatabase(control)
            let sendDatabase = try V2EventLoopBalancedDatabase(databases: [owner],
                loanPolicy: .init(maximumConnections: 2, reservedRenewalConnections: 0,
                    maximumQueued: 32, maximumWait: .seconds(10)), sessionTimeouts: .default)
            let initializationReader = try V2EventLoopBalancedDatabase(databases: [owner],
                loanPolicy: .init(maximumConnections: 1, reservedRenewalConnections: 0,
                    maximumQueued: 32, maximumWait: .seconds(10)))
            let resources = try V2RoomServerOwnerResources(database: initializationReader, sendDatabase: sendDatabase, writes: writes,
                membershipIdentities: V2PostgresMembershipIdentitySnapshotValidator(database: owner),
                invitationIdentities: PostgresV2GroupInvitationIdentityReader(database: owner),
                invitationSecretIssuer: .init(rawKey: Data(repeating: 0x73, count: 32)),
                receiptProjectionDelivery: SuccessfulProjectionDelivery(), capacityProfile: profile,
                messageLimits: .init(maxUTF8Bytes: 64), maximumEditBytes: 64,
                contentReviewMode: .disabled, queryBatchConfiguration: .init()).usingPolicyAuthorizations(policies)
            let identity = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
            try await withNativePlacementTestControl(host: identity, shardID: "room-b") { placementControl in
                let placement = try await placementControl.register(identity, shard: "room-b")
                let configuration = try V2RoomRuntimeConfiguration()
                let host = V2RoomActivationHost<V2RoomRequest, V2RoomResponse>(
                    identity: identity, placement: placement,
                    configuration: configuration, budget: .init(configuration: configuration), classify: { $0.turnSchedulingClass },
                    factory: try V2RoomServerActivationFactory(owners: ["room-b": resources], safetyActorUserID: senderID).runtimeFactory())
                await host.start()
                let hidden = ["public_user_profiles", "special_accounts", "account_disables", "user_blocks",
                    "user_relationships", "user_stranger_message_preferences"]
                var renamed: [(owner: Bool, table: String)] = []
                var mutationTask: Task<Void, any Error>?
                let policySQLGate = WarmMutationSQLGate()
                var holdingPolicySQL: Task<Void, any Error>?
                var policyTriggerInstalled = false
                var stage = "initial policy change"
                do {
                    var tokens: [V2RoomActivationToken] = []
                    for room in rooms {
                        guard case .ready(let token) = try await host.activate(roomID: room,
                            owner: .init(shardID: "room-b", epoch: 0), deadline: .now + .seconds(10)) else {
                            throw V2RoomCallFailure.notAccepted(.notReady)
                        }
                        tokens.append(token)
                        let response = try await warmMutationColdSendWithHeldWrites(reader: initializationReader, writer: sendDatabase) {
                            try await host.invoke(token: token,
                                request: warmMutationRequest(room: room, text: "before change"), deadline: .now + .seconds(10))
                        }
                        try warmMutationAccepted(response)
                    }
                    #expect(coldMetrics.sendOperationBatchMetricsSnapshot().stages[.policyOwnerState]?.count == 2)
                    try await V2PostgresSessionReadiness.verify(database: sendDatabase, timeouts: .default)
                    let initialProfileEvents = try await ownerSQL.raw("""
                        SELECT count(*)::bigint AS value FROM im_v2.user_state_event_outbox
                        WHERE source_room_id=\(bind: rooms[0].uuidValue!) AND user_id=\(bind: memberTwoUUID)
                          AND projection_kind='direct_room_profile'
                        """).first(decoding: WarmMutationCount.self)?.value
                    #expect(initialProfileEvents == 1)
                    // Hold the actual policy commit, not a room revocation
                    // that this boundary intentionally never performs.
                    try await controlSQL.raw("""
                        CREATE FUNCTION im_v2.test_hold_warm_policy_commit() RETURNS trigger LANGUAGE plpgsql AS $$
                        BEGIN PERFORM pg_advisory_xact_lock(966997); RETURN NEW; END $$
                        """).run()
                    try await controlSQL.raw("CREATE TRIGGER test_hold_warm_policy_commit BEFORE INSERT ON im_v2.policy_authorization_outbox FOR EACH ROW EXECUTE FUNCTION im_v2.test_hold_warm_policy_commit()").run()
                    policyTriggerInstalled = true
                    holdingPolicySQL = Task {
                        try await control.transaction { transaction in
                            let sql = try #require(transaction as? any SQLDatabase)
                            try await sql.raw("SELECT pg_advisory_xact_lock(966997)").run()
                            let pid = try #require(try await sql.raw("SELECT pg_backend_pid()::bigint AS value").first(decoding: WarmMutationCount.self)).value
                            await policySQLGate.hold(pid)
                        }
                    }
                    try await warmMutationObserve { await policySQLGate.pid != nil }
                    let changing = Task {
                        switch kind {
                        case "block", "remove":
                            let command = try await social.freezeSocialFixture(actorUserID: senderID, targetUserID: .init(uuid: memberTwoUUID),
                                operation: kind == "block" ? .userBlock(.init(uuid: UUID())) : .relationship(.init(uuid: UUID())),
                                action: kind == "block" ? .userBlock(.block) : .relationship(.remove), now: Date())
                            _ = try await social.submitSocialOperation(command)
                        case "stranger": _ = try await preferences.submit(deniedPreference, now: Date())
                        default:
                            _ = try await V2PostgresAccountDisableService(operatorPrincipal: "operator:test", policyOwners: owners)
                                .disable(.init(userID: .init(uuid: memberTwoUUID), operationID: UUID(), reason: .policyEnforcement))
                        }
                    }
                    mutationTask = changing
                    let pid = try #require(await policySQLGate.pid)
                    try await warmMutationObserve {
                        try await controlSQL.raw("SELECT count(*)::bigint AS value FROM pg_stat_activity WHERE \(bind: pid)::integer=ANY(pg_blocking_pids(pid))").first(decoding: WarmMutationCount.self)?.value ?? 0 > 0
                    }
                    #expect(await owners.pressure().roots == 1)
                    // The mutation has not committed. This same room still
                    // authorizes against its last committed memory snapshot.
                    let beforeSend = coldMetrics.sendOperationBatchMetricsSnapshot()
                    let factsBefore = try #require(beforeSend.stages[.policyOwnerStateFacts]).count
                    let transactionsBefore = try #require(beforeSend.stages[.policyOwnerStateTransaction]).count
                    #expect(factsBefore > 0 && transactionsBefore > 0)
                    let warmRequest = try warmMutationRequest(room: rooms[0], text: "before policy commit")
                    try warmMutationAccepted(try await host.invoke(token: tokens[0],
                        request: warmRequest, deadline: .now + .seconds(10)))
                    if kind == "remove" {
                        let implicitCount = resources.sendOperationMetrics.sendOperationBatchMetricsSnapshot().stages[.ownerSingleStatement]?.count ?? 0
                        #expect(implicitCount == 1)
                        // The identical client operation replays without a second write.
                        try warmMutationAccepted(try await host.invoke(token: tokens[0],
                            request: warmRequest, deadline: .now + .seconds(10)))
                        #expect(resources.sendOperationMetrics.sendOperationBatchMetricsSnapshot().stages[.ownerSingleStatement]?.count ?? 0 == implicitCount)
                    }
                    #expect(await owners.pressure().roots == 1)
                    #expect(coldMetrics.sendOperationBatchMetricsSnapshot().stages[.policyOwnerStateFacts]?.count ?? 0 == factsBefore)
                    #expect(coldMetrics.sendOperationBatchMetricsSnapshot().stages[.policyOwnerStateTransaction]?.count ?? 0 == transactionsBefore)
                    // An unrelated room must progress while the policy transaction is held.
                    try warmMutationAccepted(try await host.invoke(token: tokens[1],
                        request: warmMutationRequest(room: rooms[1], text: "during related change"),
                        deadline: .now + .seconds(10)))
                    await policySQLGate.release()
                    if let holdingPolicySQL { try await holdingPolicySQL.value }
                    holdingPolicySQL = nil
                    try await changing.value
                    mutationTask = nil
                    if policyTriggerInstalled {
                        try await controlSQL.raw("DROP TRIGGER test_hold_warm_policy_commit ON im_v2.policy_authorization_outbox").run()
                        try await controlSQL.raw("DROP FUNCTION im_v2.test_hold_warm_policy_commit()").run()
                        policyTriggerInstalled = false
                    }
                    // From this point any fallback to policy fact SQL must fail.
                    // Version/receipt/fence tables remain available for durability.
                    for (isOwner, sql) in [(false, controlSQL), (true, ownerSQL)] {
                        for table in hidden {
                            try await sql.raw("ALTER TABLE im_v2.\(unsafeRaw: table) RENAME TO \(unsafeRaw: table + "_warm_mutation_hidden")").run()
                            renamed.append((isOwner, table))
                        }
                    }
                    let denied = try await host.invoke(token: tokens[0],
                        request: warmMutationRequest(room: rooms[0], text: "after change"), deadline: .now + .seconds(10))
                    guard case .messaging(.sendOperation(.receipt(let receipt))) = denied else {
                        throw V2RoomWriteStoreError.corruptPersistenceState
                    }
                    #expect(receipt.outcome == .rejected(.directPolicyDenied))
                    try warmMutationAccepted(try await host.invoke(token: tokens[1],
                        request: warmMutationRequest(room: rooms[1], text: "unrelated room"), deadline: .now + .seconds(10)))
                    // Warm sends sample current policy while reusing cached facts;
                    // room registration and owner SQL remain absent.
                    let policySample = try #require(coldMetrics.sendOperationBatchMetricsSnapshot().stages[.policyOwnerState])
                    #expect(policySample.count == 6 && policySample.inFlight == 0)
                    #expect(sendDatabase.loanMetricsSnapshot().classes[.ordinary]?.inFlight == 0)
                    #expect(try await ownerSQL.raw("SELECT count(*)::bigint AS value FROM im_v2.messages WHERE room_id=\(bind: rooms[0].uuidValue!)").first(decoding: WarmMutationCount.self)?.value == 2)
                    #expect(try await ownerSQL.raw("SELECT count(*)::bigint AS value FROM im_v2.messages WHERE room_id=\(bind: rooms[1].uuidValue!)").first(decoding: WarmMutationCount.self)?.value == 3)
                    for (isOwner, table) in renamed {
                        let sql = isOwner ? ownerSQL : controlSQL
                        try await sql.raw("ALTER TABLE im_v2.\(unsafeRaw: table + "_warm_mutation_hidden") RENAME TO \(unsafeRaw: table)").run()
                    }
                    renamed.removeAll()
                    if kind != "disable" {
                        stage = "restoring policy mutation"
                        // Exercise the inverse transition on the same activation:
                        // a previously denied snapshot must not remain sticky.
                        switch kind {
                        case "block":
                            let command = try await social.freezeSocialFixture(actorUserID: senderID,
                                targetUserID: .init(uuid: memberTwoUUID), operation: .userBlock(.init(uuid: UUID())),
                                action: .userBlock(.unblock), now: Date())
                            _ = try await social.submitSocialOperation(command)
                        case "remove":
                            let request = try await social.freezeSocialFixture(actorUserID: senderID,
                                targetUserID: .init(uuid: memberTwoUUID), operation: .relationship(.init(uuid: UUID())),
                                action: .relationship(.request), now: Date())
                            _ = try await social.submitSocialOperation(request)
                            let accept = try await social.freezeSocialFixture(actorUserID: .init(uuid: memberTwoUUID),
                                targetUserID: senderID, operation: .relationship(.init(uuid: UUID())),
                                action: .relationship(.accept), now: Date())
                            _ = try await social.submitSocialOperation(accept)
                        default:
                            let command = try await preferences.freezePreferenceFixture(owner: .init(uuid: memberTwoUUID),
                                operation: .strangerMessagePreference(.init(uuid: UUID())),
                                value: .strangerMessage(.allow), now: Date())
                            _ = try await preferences.submit(command, now: Date())
                        }
                        for (isOwner, sql) in [(false, controlSQL), (true, ownerSQL)] {
                            for table in hidden {
                                try await sql.raw("ALTER TABLE im_v2.\(unsafeRaw: table) RENAME TO \(unsafeRaw: table + "_warm_mutation_hidden")").run()
                                renamed.append((isOwner, table))
                            }
                        }
                        stage = "sending with restored policy"
                        try warmMutationAccepted(try await host.invoke(token: tokens[0],
                            request: warmMutationRequest(room: rooms[0], text: "permission restored"),
                            deadline: .now + .seconds(10)))
                        try warmMutationAccepted(try await host.invoke(token: tokens[1],
                            request: warmMutationRequest(room: rooms[1], text: "unrelated after restoration"),
                            deadline: .now + .seconds(10)))
                        let sample = try #require(coldMetrics.sendOperationBatchMetricsSnapshot().stages[.policyOwnerState])
                        #expect(sample.count == 8 && sample.inFlight == 0)
                        #expect(try await ownerSQL.raw("SELECT count(*)::bigint AS value FROM im_v2.messages WHERE room_id=\(bind: rooms[0].uuidValue!)").first(decoding: WarmMutationCount.self)?.value == 3)
                        #expect(try await ownerSQL.raw("SELECT count(*)::bigint AS value FROM im_v2.messages WHERE room_id=\(bind: rooms[1].uuidValue!)").first(decoding: WarmMutationCount.self)?.value == 4)
                        #expect(try await ownerSQL.raw("""
                            SELECT count(*)::bigint AS value FROM im_v2.user_state_event_outbox
                            WHERE source_room_id=\(bind: rooms[0].uuidValue!) AND user_id=\(bind: memberTwoUUID)
                              AND projection_kind='direct_room_profile'
                            """).first(decoding: WarmMutationCount.self)?.value == initialProfileEvents)
                        let restoredCapabilityEvents = try await ownerSQL.raw("""
                            SELECT count(*)::bigint AS value FROM im_v2.user_state_event_outbox
                            WHERE source_room_id=\(bind: rooms[0].uuidValue!) AND user_id=\(bind: senderUUID)
                              AND projection_kind='direct_sending_capability' AND payload->>'can_send'='true'
                            """).first(decoding: WarmMutationCount.self)?.value
                        #expect(restoredCapabilityEvents == 2)
                        let restrictedCapabilityEvents = try await ownerSQL.raw("""
                            SELECT count(*)::bigint AS value FROM im_v2.user_state_event_outbox
                            WHERE source_room_id=\(bind: rooms[0].uuidValue!) AND user_id=\(bind: senderUUID)
                              AND projection_kind='direct_sending_capability' AND payload->>'can_send'='false'
                            """).first(decoding: WarmMutationCount.self)?.value
                        #expect(restrictedCapabilityEvents == 1)
                        // Restriction hints downgrade the sender's presentation.
                        // A later accepted send publishes the restored capability.
                        for (isOwner, table) in renamed {
                            let sql = isOwner ? ownerSQL : controlSQL
                            try await sql.raw("ALTER TABLE im_v2.\(unsafeRaw: table + "_warm_mutation_hidden") RENAME TO \(unsafeRaw: table)").run()
                        }
                        renamed.removeAll()
                    }
                    stage = "shutdown"
                    let drained = await host.stop(deadline: .now + .seconds(10))
                    #expect(drained.completed)
                    let proof = try #require(drained.proof)
                    try await placement.retireAfterDrain(proof, shards: ["room-b"])
                    await resources.shutdownDurableSendOperations()
                    try await policies.shutdown(); await owners.shutdown()
                } catch {
                    Issue.record("Warm policy scenario failed during \(stage)")
                    await policySQLGate.release()
                    if let holdingPolicySQL { _ = await holdingPolicySQL.result }
                    if let mutationTask { _ = await mutationTask.result }
                    if policyTriggerInstalled {
                        try? await controlSQL.raw("DROP TRIGGER test_hold_warm_policy_commit ON im_v2.policy_authorization_outbox").run()
                        try? await controlSQL.raw("DROP FUNCTION im_v2.test_hold_warm_policy_commit()").run()
                    }
                    for (isOwner, table) in renamed {
                        let sql = isOwner ? ownerSQL : controlSQL
                        try? await sql.raw("ALTER TABLE im_v2.\(unsafeRaw: table + "_warm_mutation_hidden") RENAME TO \(unsafeRaw: table)").run()
                    }
                    let drained = await host.stop(deadline: .now + .seconds(10))
                    if let proof = drained.proof { try? await placement.retireAfterDrain(proof, shards: ["room-b"]) }
                    await resources.shutdownDurableSendOperations()
                    try? await policies.shutdown(); await owners.shutdown()
                    throw error
                }
            }
        }
    }
}

private struct WarmMutationCount: Decodable { let value: Int64 }
private func warmMutationColdSendWithHeldWrites(reader: V2EventLoopBalancedDatabase,
    writer: V2EventLoopBalancedDatabase,
    send: @escaping @Sendable () async throws -> V2RoomResponse) async throws -> V2RoomResponse {
    let before = reader.loanMetricsSnapshot().observations[.roomSendInitialization]?.actualHeldCount ?? 0
    let gates = [WarmMutationSQLGate(), WarmMutationSQLGate()]
    let held = gates.map { gate in Task {
        try await writer.withConnection { connection in
            connection.eventLoop.makeFutureWithTask { await gate.hold(0) }
        }.get()
    } }
    var sending: Task<V2RoomResponse, any Error>?
    do {
        for gate in gates { try await warmMutationObserve { await gate.pid != nil } }
        let task = Task { try await send() }; sending = task
        // Activation has already installed the room state. Cold policy loading
        // must finish while write slots are occupied; persistence alone queues.
        try await warmMutationObserve {
            writer.loanMetricsSnapshot().classes[.ordinary]?.queued == 1
        }
        #expect(reader.loanMetricsSnapshot().classes[.activation]?.granted ?? 0 > 0)
        #expect(reader.loanMetricsSnapshot().observations[.roomSendInitialization]?.actualHeldCount ?? 0 == before)
        #expect(writer.loanMetricsSnapshot().classes[.ordinary]?.inFlight == 2)
        #expect(writer.loanMetricsSnapshot().observations[.roomSendInitialization]?.actualHeldCount ?? 0 == 0)
        for gate in gates { await gate.release() }
        for task in held { try await task.value }
        return try await task.value
    } catch {
        for gate in gates { await gate.release() }
        sending?.cancel()
        for task in held { _ = await task.result }
        if let sending { _ = await sending.result }
        throw error
    }
}
private actor WarmMutationSQLGate {
    private(set) var pid: Int64?
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func hold(_ pid: Int64) async {
        self.pid = pid
        guard !released else { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}
private func warmMutationObserve(_ check: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while .now < deadline {
        if try await check() { return }
        await Task.yield()
    }
    try #require(try await check())
}
private func warmMutationRequest(room: RoomID, text: String) throws -> V2RoomRequest {
    try V2RoomRequest.messaging(.sendOperation(.init(command: .init(roomID: room,
        senderUserID: senderID, clientMessageID: .init(uuid: UUID()), text: text, limits: .init(maxUTF8Bytes: 64)),
        firstSubmissionDeadlineMilliseconds: UInt64(Date().timeIntervalSince1970 * 1000) + 60_000)))
}
private func warmMutationAccepted(_ response: V2RoomResponse) throws {
    guard case .messaging(.sendOperation(.receipt(let receipt))) = response, case .accepted = receipt.outcome else {
        throw V2RoomWriteStoreError.corruptPersistenceState
    }
}
