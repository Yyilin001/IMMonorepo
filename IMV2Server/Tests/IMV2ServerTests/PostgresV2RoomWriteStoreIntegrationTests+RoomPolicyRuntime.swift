import Foundation
import FluentKit
import IMV2Core
import IMV2ActorContracts
@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("leased room snapshots write real messages and a pair mutation invalidates the old permission", arguments: [false, true], ["scalar", "owned", "prepared", "preborrow"])
    func roomPolicyRuntimeMessageAcceptance(recipientHasReplied: Bool, mode: String) async throws {
        let durableBatch = mode != "scalar"
        let queuedPolicy = mode == "prepared" || mode == "preborrow"
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, controlSQL, ownerSQL, _ in
            let now = Date(), profile = try forwardImportTestProfile()
            // The durable path precharges a credit cohort; leave capacity for
            // the separate scalar transaction used by the COMMIT barrier.
            // This is fixture capacity, never production load-test tuning.
            try await ownerSQL.raw("UPDATE im_v2.shard_admission_pools SET valid_until=clock_timestamp()+interval '10 minutes',command_window_limit=1000").run()
            let direct = V2DirectRoomOperationTestFixture(store: PostgresV2DirectMessagingStore(database: owner,
                identityReader: PostgresV2DirectRoomIdentityReader(database: control), projectionDelivery: SuccessfulProjectionDelivery()),
                capacityProfile: profile, roomShardID: "room-b", now: { now })
            let room = try await direct.openedIdentity(actorUserID: senderID, operationID: .init(uuid: UUID()),
                targetUserID: .init(uuid: memberTwoUUID), firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
            if recipientHasReplied {
                try await controlSQL.raw("INSERT INTO im_v2.user_stranger_message_preferences(user_id,allows_stranger_messages,updated_at) VALUES (\(bind: memberTwoUUID),false,clock_timestamp())").run()
                try await ownerSQL.raw("""
                    UPDATE im_v2.direct_room_pairs SET
                        lower_has_replied=(lower_user_id=\(bind: memberTwoUUID)),
                        higher_has_replied=(higher_user_id=\(bind: memberTwoUUID))
                    WHERE room_id=\(bind: room.roomID.uuidValue!)
                    """).run()
            }
            try await withRoomActivation(database: owner, roomID: room.roomID, shardID: "room-b") { token in
                let router = RoomPolicyTestRouter()
                let legacy = V2DirectAuthorizationCoordinator(controlDatabase: control, ownerDatabases: [:])
                let directory = PostgresV2PolicyOwnerDirectory(journal: .init(database: control),
                    dispatcher: .init(database: control, projectionDelivery: SuccessfulProjectionDelivery(), legacyAuthorization: legacy),
                    revoke: { try await router.revoke($0) })
                let host = PostgresV2RoomPolicyAuthorizationDirectory(database: owner, endpoint: "room-b", maximumRooms: 1,
                    loader: { requested, pair, registration, activation in
                        await router.loaded()
                        let owners = try await directory.registrationOwners(scopes: [.account(pair.sender),
                            .account(pair.recipient), .pair(pair.sender, pair.recipient), .stranger(pair.recipient)])
                        return try await PostgresV2DirectPolicySnapshotStore(database: control).register(
                            pair: pair, owners: owners, registrationID: registration, roomID: requested.roomID.uuidValue!,
                            activationID: activation, roomOwnerEpoch: requested.owner.epoch, endpoint: "room-b", durationSeconds: 20)
                    })
                let registry = try await host.registry(token: token)
                await router.install(host)
                let runtime = try await registry.runtime(sender: senderUUID, token: token)
                #expect(try await registry.runtime(sender: senderUUID, token: token) === runtime)
                let reverse = try await registry.runtime(sender: memberTwoUUID, token: token)
                #expect(reverse !== runtime)
                #expect(await registry.pressure().directions == 2)
                do {
                    _ = try await registry.runtime(sender: UUID(), token: token)
                    Issue.record("An unrelated sender obtained a direction")
                } catch { #expect(error as? V2PolicyAuthorizationLifecycleError == .invalidTarget) }
                let foreignToken = V2RoomActivationToken(roomID: .init(uuid: UUID()), owner: token.owner,
                    activationEpoch: token.activationEpoch, host: token.host)
                do {
                    _ = try await registry.runtime(sender: senderUUID, token: foreignToken)
                    Issue.record("A foreign activation obtained a direction")
                } catch { #expect(error as? V2PolicyAuthorizationLifecycleError == .ownerChanged) }
                let base = PostgresV2RoomWriteStore(database: owner,
                    strangerMessagePolicy: try .init(maximumMessagesPerWindow: 10, window: 86_400),
                    contentReviewMode: durableBatch ? .disabled : .enabled)
                    .usingControlDatabase(control)
                    .usingActivationScope(try .init(tokens: [token]))
                var stage = "initial acceptance"
                do {
                    let metrics = V2SendOperationBatchMetrics()
                    let operations = PostgresV2MessageSendOperationStore(database: owner, writes: base, sendOperationMetrics: metrics)
                    let firstCommands = try (0..<2).map { index in
                        if queuedPolicy && index == 1 {
                            return try V2SendMessageCommand(roomID: room.roomID, senderUserID: .init(uuid: memberTwoUUID),
                                clientMessageID: .init(uuid: UUID()), text: "reverse leased policy", limits: .init(maxUTF8Bytes: 64))
                        }
                        return try roomPolicyTestCommand(roomID: room.roomID)
                    }
                    let initialLoads = queuedPolicy ? 2 : 1
                    let firstOperations = try firstCommands.map { try roomPolicyTestOperation($0) }
                    var waiting: V2PreparedMessageSendBatch?
                    if queuedPolicy {
                        let commands = firstOperations
                        let prepared = try await operations.prepareSendBatch(commands, token: token, policyDirectory: host,
                            deadline: .now + .seconds(5), now: Date.init)
                        #expect(await runtime.pressure().executions == 0)
                        let accepted = try await roomPolicyExecuteQueued(operations, prepared: prepared, runtime: runtime,
                            profile: profile, preborrow: mode == "preborrow", router: router)
                        try roomPolicyExpectAccepted(accepted[0].get(), count: 2)
                        let replay = try await roomPolicyExecuteQueued(operations, prepared: prepared, runtime: runtime,
                            profile: profile, preborrow: mode == "preborrow", router: router)
                        #expect(try replay[0].get() == accepted[0].get())
                        #expect(await runtime.pressure().executions == 0)
                        let queuedCommand = try roomPolicyTestCommand(roomID: room.roomID)
                        waiting = try await operations.prepareSendBatch([roomPolicyTestOperation(queuedCommand)], token: token,
                            policyDirectory: host, deadline: .now + .seconds(5), now: Date.init)
                        #expect(await runtime.pressure().executions == 0)
                        #expect(metrics.sendOperationBatchMetricsSnapshot().ownerCohortAcceptedCommands == 2)
                        #expect(metrics.sendOperationBatchMetricsSnapshot().ownerCohortReplayedCommands == 2)
                    } else if durableBatch {
                        try await runtime.executeBatch(commands: firstCommands, callerDeadline: .now + .seconds(5)) { execution in
                            let scoped = try operations.usingPolicyExecution(execution)
                            let commands = firstOperations
                            let prepared = try await scoped.prepareSendBatch(commands, token: token, now: Date.init)
                            let accepted = try await scoped.executeIndependentRoomTurns([prepared], capacityProfile: profile,
                                identifiers: .init(), now: Date.init)
                            try roomPolicyExpectAccepted(accepted[0].get(), count: 2)
                            let replay = try await scoped.executeIndependentRoomTurns([prepared], capacityProfile: profile,
                                identifiers: .init(), now: Date.init)
                            #expect(try replay[0].get() == accepted[0].get())
                        }
                        #expect(metrics.sendOperationBatchMetricsSnapshot().ownerCohortAcceptedCommands == 2)
                        #expect(metrics.sendOperationBatchMetricsSnapshot().ownerCohortReplayedCommands == 2)
                    } else {
                        for command in firstCommands {
                            let result = try await runtime.execute(command: command, callerDeadline: .now + .seconds(5)) { execution in
                                try await base.usingPolicyExecution(execution).accept(command: command, capacityProfile: profile,
                                    identifiers: V2AcceptanceIDFactory().make(at: Date()), now: Date())
                            }
                            guard case .accepted = result else { throw V2RoomWriteStoreError.corruptPersistenceState }
                        }
                    }
                    #expect(await router.loads == initialLoads)
                    #expect(try await controlSQL.raw("SELECT count(*)::bigint AS value FROM im_v2.direct_authorization_intents").first(decoding: RoomPolicyTestCount.self)?.value == 0)
                    #expect(try await ownerSQL.raw("SELECT count(*)::bigint AS value FROM im_v2.direct_authorization_receipts").first(decoding: RoomPolicyTestCount.self)?.value == 0)
                    stage = "hidden policy mirrors"
                    // A warmed leased send must not even reference local
                    // mirrors of account policy. These tables are deliberately
                    // absent during one real acceptance, then restored.
                    let mirrors = ["public_user_profiles", "account_disables", "user_direct_send_policy_versions",
                        "user_blocks", "user_relationships", "user_stranger_message_preferences", "special_accounts"]
                    for table in mirrors {
                        try await ownerSQL.raw("ALTER TABLE im_v2.\(unsafeRaw: table) RENAME TO \(unsafeRaw: table + "_hidden")").run()
                    }
                    do {
                        let command = try roomPolicyTestCommand(roomID: room.roomID)
                        if queuedPolicy {
                            let prepared = try await operations.prepareSendBatch([roomPolicyTestOperation(command)], token: token,
                                policyDirectory: host, deadline: .now + .seconds(5), now: Date.init)
                            #expect(await runtime.pressure().executions == 0)
                            let accepted = try await roomPolicyExecuteQueued(operations, prepared: prepared, runtime: runtime,
                                profile: profile, preborrow: mode == "preborrow", router: router)
                            try roomPolicyExpectAccepted(accepted[0].get(), count: 1)
                            #expect(metrics.sendOperationBatchMetricsSnapshot().ownerCohortAcceptedCommands == 3)
                        } else if durableBatch {
                            let accepted = try await runtime.execute(command: command, callerDeadline: .now + .seconds(5)) { execution in
                                let scoped = try operations.usingPolicyExecution(execution)
                                let prepared = try await scoped.prepareSendBatch([roomPolicyTestOperation(command)], token: token, now: Date.init)
                                return try await scoped.executeIndependentRoomTurns([prepared], capacityProfile: profile,
                                    identifiers: .init(), now: Date.init)
                            }
                            try roomPolicyExpectAccepted(accepted[0].get(), count: 1)
                            #expect(metrics.sendOperationBatchMetricsSnapshot().ownerCohortAcceptedCommands == 3)
                        } else {
                            let result = try await runtime.execute(command: command, callerDeadline: .now + .seconds(5)) { execution in
                                try await base.usingPolicyExecution(execution).accept(command: command, capacityProfile: profile,
                                    identifiers: V2AcceptanceIDFactory().make(at: Date()), now: Date())
                            }
                            guard case .accepted = result else { throw V2RoomWriteStoreError.corruptPersistenceState }
                        }
                    } catch {
                        for table in mirrors {
                            try await ownerSQL.raw("ALTER TABLE im_v2.\(unsafeRaw: table + "_hidden") RENAME TO \(unsafeRaw: table)").run()
                        }
                        throw error
                    }
                    for table in mirrors {
                        try await ownerSQL.raw("ALTER TABLE im_v2.\(unsafeRaw: table + "_hidden") RENAME TO \(unsafeRaw: table)").run()
                    }
                    #expect(try await ownerSQL.raw("SELECT count(*)::bigint AS value FROM im_v2.messages WHERE room_id=\(bind: room.roomID.uuidValue!)").first(decoding: RoomPolicyTestCount.self)?.value == 3)
                    #expect(try await ownerSQL.raw("SELECT count(*)::bigint AS value FROM im_v2.room_policy_authorization_leases").first(decoding: RoomPolicyTestCount.self)?.value == Int64(initialLoads))
                    #expect(try await controlSQL.raw("SELECT count(*)::bigint AS value FROM im_v2.policy_authorization_holders").first(decoding: RoomPolicyTestCount.self)?.value == Int64(initialLoads * 4))
                    let social = PostgresV2SocialRelationshipStore(database: control, projectionDelivery: SuccessfulProjectionDelivery(),
                        authorizationCoordinator: legacy).usingPolicyOwners(directory)
                    let block = try await social.freezeSocialFixture(actorUserID: senderID, targetUserID: .init(uuid: memberTwoUUID),
                        operation: .userBlock(.init(uuid: UUID())), action: .userBlock(.block), now: Date())
                    stage = "held message transaction"
                    // Hold a real message transaction after acceptance but
                    // before COMMIT. Cancellation must retain its execution;
                    // the mutation cannot commit until this SQL settles.
                    let barrier = RoomPolicyLoadBarrier()
                    let heldCommand = try roomPolicyTestCommand(roomID: room.roomID)
                    let held = Task {
                        try await runtime.execute(command: heldCommand, callerDeadline: .now + .seconds(5)) { execution in
                            try await owner.transaction { transaction in
                                let result = try await base.usingPolicyExecution(execution).usingWorkloadDatabase(transaction)
                                    .usingOperationTransaction().accept(command: heldCommand, capacityProfile: profile,
                                        identifiers: V2AcceptanceIDFactory().make(at: Date()), now: Date())
                                await barrier.holdFirstLoad()
                                return (result, execution)
                            }
                        }
                    }
                    let waitingDeadline = ContinuousClock.now + .seconds(5)
                    while !(await barrier.entered), .now < waitingDeadline { await Task.yield() }
                    guard await barrier.entered else {
                        await barrier.release(); _ = try await held.value
                        throw V2PolicyAuthorizationLifecycleError.corruptPersistence
                    }
                    let changing = Task { try await social.submitSocialOperation(block, now: Date()) }
                    do {
                        let deadline = ContinuousClock.now + .seconds(5)
                        while await runtime.pressure().accepting, .now < deadline { await Task.yield() }
                        #expect(await runtime.pressure().accepting == false)
                        #expect(await runtime.pressure().executions == 1)
                        #expect(await directory.pressure().roots == 1)
                        #expect(try await controlSQL.raw("SELECT count(*)::bigint AS value FROM im_v2.user_blocks").first(decoding: RoomPolicyTestCount.self)?.value == 0)
                        _ = try await directory.registrationOwners(scopes: [.account(UUID())])
                        held.cancel()
                        #expect(await runtime.pressure().executions == 1)
                        await barrier.release()
                        let (result, execution) = try await held.value
                        guard case .accepted = result else {
                            Issue.record("Held acceptance returned \(result)")
                            throw V2RoomWriteStoreError.corruptPersistenceState
                        }
                        _ = try await changing.value
                        await #expect(throws: V2RoomPolicyAuthorizationGate.Failure.invalidPermit) {
                            try await owner.transaction { transaction in
                                try await execution.requireActive(roomID: room.roomID.uuidValue!, senderID: senderUUID,
                                    clientMessageID: heldCommand.clientMessageID.uuidValue!, sql: try #require(transaction as? any SQLDatabase))
                            }
                        }
                    } catch {
                        await barrier.release(); _ = await held.result; _ = await changing.result; throw error
                    }
                    #expect(await runtime.pressure().accepting == false)
                    if let waiting {
                        let borrowed = await router.borrows
                        await #expect(throws: V2RoomPolicyAuthorizationGate.Failure.unavailable) {
                            try await roomPolicyExecuteQueued(operations, prepared: waiting, runtime: runtime,
                                profile: profile, preborrow: true, router: router)
                        }
                        #expect(await router.borrows == borrowed)
                        #expect(await runtime.pressure().executions == 0)
                        stage = "immutable accepted result replay"
                        // A permanent accepted result replays without acquiring
                        // policy again, even though the pair is now sealed/revoked.
                        let prior = try await operations.prepareSendBatch([firstOperations[0]], token: token,
                            policyDirectory: host, deadline: .now + .seconds(5), now: Date.init)
                        let replay = try await operations.executePreparedSendBatch(prior, capacityProfile: profile,
                            identifiers: .init(), now: Date.init)
                        try roomPolicyExpectAccepted(replay, count: 1)
                        #expect(await router.loads == initialLoads)
                    }
                    let command = try roomPolicyTestCommand(roomID: room.roomID)
                    stage = "post-block rejection"
                    if queuedPolicy {
                        let prepared = try await operations.prepareSendBatch([roomPolicyTestOperation(command)], token: token,
                            policyDirectory: host, deadline: .now + .seconds(5), now: Date.init)
                        #expect(await runtime.pressure().executions == 0)
                        let denied = try await operations.executePreparedSendBatch(prepared, capacityProfile: profile,
                            identifiers: .init(), now: Date.init)
                        guard denied.count == 1, case .sendOperation(.receipt(let receipt)) = denied[0],
                              receipt.outcome == .rejected(.directPolicyDenied) else {
                            throw V2RoomWriteStoreError.corruptPersistenceState
                        }
                    } else if durableBatch {
                        let denied = try await runtime.execute(command: command, callerDeadline: .now + .seconds(5)) { execution in
                            let scoped = try operations.usingPolicyExecution(execution)
                            return try await scoped.sendBatch([roomPolicyTestOperation(command)], token: token,
                                capacityProfile: profile, identifiers: .init(), now: Date.init)
                        }
                        guard denied.count == 1, case .sendOperation(.receipt(let receipt)) = denied[0],
                              receipt.outcome == .rejected(.directPolicyDenied) else {
                            throw V2RoomWriteStoreError.corruptPersistenceState
                        }
                        #expect(try await ownerSQL.raw("SELECT count(*)::bigint AS value FROM im_v2.message_send_completions WHERE room_id=\(bind: room.roomID.uuidValue!)").first(decoding: RoomPolicyTestCount.self)?.value == 4)
                    } else {
                        let denied = try await runtime.execute(command: command, callerDeadline: .now + .seconds(5)) { execution in
                            try await base.usingPolicyExecution(execution).accept(command: command, capacityProfile: profile,
                                identifiers: V2AcceptanceIDFactory().make(at: Date()), now: Date())
                        }
                        guard case .denied = denied else { throw V2RoomWriteStoreError.corruptPersistenceState }
                    }
                    #expect(await router.loads == initialLoads + 1)
                    #expect(try await ownerSQL.raw("SELECT count(*)::bigint AS value FROM im_v2.messages WHERE room_id=\(bind: room.roomID.uuidValue!)").first(decoding: RoomPolicyTestCount.self)?.value == 4)
                    let retiredHolder = V2PolicyAuthorizationHolder(registrationID: UUID(), roomID: room.roomID.uuidValue!,
                        activationID: UUID(), roomOwnerEpoch: token.owner.epoch, generation: 1,
                        endpoint: "room-b", validUntil: Date().addingTimeInterval(10))
                    #expect(try await registry.revoke(retiredHolder).holder == retiredHolder)
                    #expect(await runtime.pressure().accepting)
                    #expect(try await ownerSQL.raw("SELECT count(*)::bigint AS value FROM im_v2.room_policy_authorization_leases WHERE registration_id=\(bind: retiredHolder.registrationID) AND revoked").first(decoding: RoomPolicyTestCount.self)?.value == 1)
                    do {
                        try await PostgresV2RoomPolicyLeaseFence(database: owner).install(retiredHolder)
                        Issue.record("Retired holder was installed after registry fallback revocation")
                    } catch { #expect(error as? V2PolicyAuthorizationLifecycleError == .staleVersion) }
                    try await registry.shutdown()
                    try await registry.shutdown()
                    #expect(await runtime.pressure().closed)
                    #expect(await reverse.pressure().closed)
                    do {
                        _ = try await registry.runtime(sender: senderUUID, token: token)
                        Issue.record("Retired registry created a direction")
                    } catch { #expect(error as? V2PolicyAuthorizationLifecycleError == .closed) }
                    try await host.retire(token: token)
                    #expect(await host.pressure().rooms == 0)
                    let staleToken = V2RoomActivationToken(roomID: token.roomID, owner: token.owner,
                        activationEpoch: token.activationEpoch,
                        host: .init(hostID: token.host.hostID, incarnationID: UUID()))
                    await #expect(throws: V2RoomActivationLeaseError.activationChanged) {
                        try await host.registry(token: staleToken)
                    }
                    #expect(await host.pressure().rooms == 0)
                    #expect(try await host.revoke(retiredHolder).holder == retiredHolder)
                    try await host.shutdown()
                    await directory.shutdown(); await router.clear()
                } catch {
                    Issue.record("Runtime scenario failed during \(stage): \(error)")
                    try? await host.shutdown(); await directory.shutdown(); await router.clear(); throw error
                }
            }
        }
    }

    @Test("a revoke arriving before cold snapshot installation cannot resurrect its registration")
    func roomPolicyRuntimeDelayedColdLoad() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, _, _, room in
            try await withRoomActivation(database: owner, roomID: room, shardID: "room-b") { token in
                let router = RoomPolicyTestRouter(), barrier = RoomPolicyLoadBarrier()
                let legacy = V2DirectAuthorizationCoordinator(controlDatabase: control, ownerDatabases: [:])
                let directory = PostgresV2PolicyOwnerDirectory(journal: .init(database: control),
                    dispatcher: .init(database: control, projectionDelivery: SuccessfulProjectionDelivery(), legacyAuthorization: legacy),
                    revoke: { try await router.revoke($0) })
                let runtime = PostgresV2RoomPolicyAuthorization(activation: token,
                    pair: .init(sender: senderUUID, recipient: memberTwoUUID), endpoint: "room-b", fence: .init(database: owner),
                    loader: { registration, activation in
                        let owners = try await directory.registrationOwners(scopes: [.account(senderUUID),
                            .account(memberTwoUUID), .pair(senderUUID, memberTwoUUID), .stranger(memberTwoUUID)])
                        let snapshot = try await PostgresV2DirectPolicySnapshotStore(database: control).register(
                            pair: .init(sender: senderUUID, recipient: memberTwoUUID), owners: owners,
                            registrationID: registration, roomID: room.uuidValue!, activationID: activation,
                            roomOwnerEpoch: token.owner.epoch, endpoint: "room-b", durationSeconds: 20)
                        await barrier.holdFirstLoad()
                        return snapshot
                    })
                await router.install(runtime)
                let loadDeadline = ContinuousClock.now + .seconds(5)
                let warming = Task {
                    try await V2RoomSQLDeadline.withDeadline(loadDeadline) { try await runtime.warm() }
                }
                do {
                    let deadline = ContinuousClock.now + .seconds(5)
                    while !(await barrier.entered), .now < deadline { await Task.yield() }
                    try #require(await barrier.entered)
                    #expect(await barrier.deadline == loadDeadline)
                    let social = PostgresV2SocialRelationshipStore(database: control, projectionDelivery: SuccessfulProjectionDelivery(),
                        authorizationCoordinator: legacy).usingPolicyOwners(directory)
                    let block = try await social.freezeSocialFixture(actorUserID: senderID, targetUserID: .init(uuid: memberTwoUUID),
                        operation: .userBlock(.init(uuid: UUID())), action: .userBlock(.block), now: Date())
                    _ = try await social.submitSocialOperation(block, now: Date())
                    await barrier.release()
                    do { try await warming.value; Issue.record("Revoked cold load was installed") }
                    catch { #expect(error as? V2PolicyAuthorizationLifecycleError == .staleVersion) }
                    #expect(await runtime.pressure().accepting == false)
                    try await runtime.warm()
                    #expect(await runtime.pressure().accepting)
                    try await runtime.shutdown(); await directory.shutdown(); await router.clear()
                } catch {
                    await barrier.release(); _ = await warming.result
                    try? await runtime.shutdown(); await directory.shutdown(); await router.clear(); throw error
                }
            }
        }
    }
}

private func roomPolicyTestCommand(roomID: RoomID) throws -> V2SendMessageCommand {
    try .init(roomID: roomID, senderUserID: senderID, clientMessageID: .init(uuid: UUID()),
        text: "leased policy", limits: .init(maxUTF8Bytes: 64))
}
private struct RoomPolicyTestCount: Decodable { let value: Int64 }
private actor RoomPolicyTestRouter {
    private var runtime: PostgresV2RoomPolicyAuthorization?
    private var registry: PostgresV2RoomPolicyAuthorizationRegistry?
    private var host: PostgresV2RoomPolicyAuthorizationDirectory?
    private(set) var loads = 0
    private(set) var borrows = 0
    func borrowed() { borrows += 1 }
    func loaded() { loads += 1 }
    func install(_ runtime: PostgresV2RoomPolicyAuthorization) { self.runtime = runtime }
    func install(_ registry: PostgresV2RoomPolicyAuthorizationRegistry) { self.registry = registry }
    func install(_ host: PostgresV2RoomPolicyAuthorizationDirectory) { self.host = host }
    func clear() { runtime = nil; registry = nil; host = nil }
    func revoke(_ holder: V2PolicyAuthorizationHolder) async throws -> V2PolicyAuthorizationRevocationProof {
        if let host { return try await host.revoke(holder) }
        if let registry { return try await registry.revoke(holder) }
        guard let runtime else { throw V2PolicyAuthorizationLifecycleError.closed }
        return try await runtime.revoke(holder)
    }
}
private actor RoomPolicyLoadBarrier {
    private(set) var entered = false
    private(set) var deadline: ContinuousClock.Instant?
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func holdFirstLoad() async {
        guard !released else { return }
        entered = true
        deadline = V2RoomSQLDeadline.current
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

private func roomPolicyTestOperation(_ command: V2SendMessageCommand) throws -> V2MessageSendOperationCommand {
    try .init(command: command, firstSubmissionDeadlineMilliseconds: UInt64(Date().timeIntervalSince1970 * 1000) + 60_000)
}
private func roomPolicyExpectAccepted(_ values: [V2RoomMessagingResult], count: Int) throws {
    try #require(values.count == count)
    for value in values {
        guard case .sendOperation(.receipt(let receipt)) = value, case .accepted = receipt.outcome else {
            Issue.record("Expected accepted durable result, received \(value)")
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
    }
}

private func roomPolicyExecuteQueued(_ operations: PostgresV2MessageSendOperationStore,
    prepared: V2PreparedMessageSendBatch, runtime: PostgresV2RoomPolicyAuthorization,
    profile: V2CapacityProfile, preborrow: Bool, router: RoomPolicyTestRouter) async throws
    -> [Result<[V2RoomMessagingResult], any Error>] {
    if preborrow {
        return try await operations.executeIndependentRoomTurnsPreborrowing([prepared], capacityProfile: profile,
            identifiers: .init(), now: Date.init, control: .init(connectionAcquired: {
                #expect(await runtime.pressure().executions == 1)
                await router.borrowed()
            }, beforeFirstBegin: {
                #expect(await runtime.pressure().executions == 0)
            }, interrupted: { _ in }))
    }
    return try await operations.executeIndependentRoomTurns([prepared], capacityProfile: profile,
        identifiers: .init(), now: Date.init)
}
