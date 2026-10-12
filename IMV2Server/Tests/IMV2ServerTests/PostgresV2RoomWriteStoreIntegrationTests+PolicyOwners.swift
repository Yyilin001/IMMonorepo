import Foundation
import FluentKit
import IMV2Core
import IMV2ActorContracts
@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
@testable import IMV2ServerInfrastructure
import SQLKit
import PostgresNIO
import Testing
import Synchronization
import NIOCore

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("current policy preserves room-local reply permission when stranger messages are disabled",
          arguments: [false, true], ["scalar", "prepared", "preborrow"])
    func currentPolicyStrangerReplyPermission(recipientHasReplied: Bool, mode: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, controlSQL, ownerSQL, _ in
            let now = Date(), profile = try forwardImportTestProfile()
            try await ownerSQL.raw("UPDATE im_v2.shard_admission_pools SET valid_until=clock_timestamp()+interval '10 minutes',command_window_limit=1000").run()
            let room = try await V2DirectRoomOperationTestFixture(store: PostgresV2DirectMessagingStore(database: owner,
                identityReader: PostgresV2DirectRoomIdentityReader(database: control), projectionDelivery: SuccessfulProjectionDelivery()),
                capacityProfile: profile, roomShardID: "room-b", now: { now }).openedIdentity(actorUserID: senderID,
                    operationID: .init(uuid: UUID()), targetUserID: .init(uuid: memberTwoUUID),
                    firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
            try await controlSQL.raw("INSERT INTO im_v2.user_stranger_message_preferences VALUES (\(bind: memberTwoUUID),false,clock_timestamp())").run()
            if recipientHasReplied {
                try await ownerSQL.raw("UPDATE im_v2.direct_room_pairs SET lower_has_replied=(lower_user_id=\(bind: memberTwoUUID)),higher_has_replied=(higher_user_id=\(bind: memberTwoUUID)) WHERE room_id=\(bind: room.roomID.uuidValue!)").run()
            }
            let directory = PostgresV2PolicyOwnerDirectory(journal: .init(database: control),
                dispatcher: .init(database: control, projectionDelivery: SuccessfulProjectionDelivery()))
            let policies = V2RoomPolicyAuthorizationService(roomDatabase: owner,
                policyOwners: directory, endpoint: "room-b", maximumRooms: 1)
            let host = PostgresV2RoomPolicyAuthorizationDirectory(database: owner, endpoint: "room-b-scalar", maximumRooms: 1,
                currentLoader: { _, sender, recipient, _ in
                    let recipient = try #require(recipient)
                    let states = try await directory.registrationSnapshots(scopes: [.account(sender), .account(recipient),
                        .pair(sender, recipient), .stranger(recipient)])
                    return try .direct(pair: .init(sender: sender, recipient: recipient), snapshots: states)
                })
            let tables = ["public_user_profiles", "account_disables", "special_accounts", "user_blocks", "user_relationships", "user_stranger_message_preferences"]
            let hidden = Mutex<[String]>([])
            do {
                try await withRoomActivation(database: owner, roomID: room.roomID, shardID: "room-b") { token in
                    let runtime = try await host.registry(token: token).runtime(sender: senderUUID, token: token)
                    let base = PostgresV2RoomWriteStore(database: owner, contentReviewMode: .disabled)
                        .usingControlDatabase(control).usingActivationScope(try .init(tokens: [token]))
                    let metrics = V2SendOperationBatchMetrics()
                    let store = PostgresV2MessageSendOperationStore(database: owner, writes: base.usingPolicyAuthorizations(policies), sendOperationMetrics: metrics)
                    @Sendable func send() async throws {
                        let command = try V2SendMessageCommand(roomID: room.roomID, senderUserID: senderID,
                            clientMessageID: .init(uuid: UUID()), text: "reply permission", limits: .init(maxUTF8Bytes: 64))
                        if mode == "scalar" {
                            do {
                                let result = try await runtime.execute(command: command, callerDeadline: .now + .seconds(5)) { execution in
                                    try await base.usingPolicyExecution(execution).accept(command: command, capacityProfile: profile,
                                        identifiers: V2AcceptanceIDFactory().make(at: Date()), now: Date())
                                }
                                guard case .accepted = result else { throw V2RoomWriteStoreError.corruptPersistenceState }
                                #expect(recipientHasReplied)
                            } catch V2SendOperationResponseError.directPolicyDenied {
                                #expect(!recipientHasReplied)
                            }
                        } else {
                            let operation = try V2MessageSendOperationCommand(command: command,
                                firstSubmissionDeadlineMilliseconds: UInt64(Date().timeIntervalSince1970 * 1000) + 60_000)
                            let prepared = try await policies.prepareOwnerBatches(store: store,
                                requests: [.init(commands: [operation], token: token, deadline: .now + .seconds(5))], now: Date.init)
                            let results: [Result<[V2RoomMessagingResult], any Error>]
                            if mode == "preborrow" {
                                results = try await store.executeIndependentRoomTurnsPreborrowing(prepared.map { try $0.get() },
                                    capacityProfile: profile, identifiers: .init(), now: Date.init,
                                    control: .init(connectionAcquired: {}, beforeFirstBegin: {}, interrupted: { _ in }))
                            } else {
                                results = try await store.executeIndependentRoomTurns(prepared.map { try $0.get() },
                                    capacityProfile: profile, identifiers: .init(), now: Date.init)
                            }
                            guard case .sendOperation(.receipt(let receipt))? = try results[0].get().first else {
                                throw V2RoomWriteStoreError.corruptPersistenceState
                            }
                            if recipientHasReplied {
                                guard case .accepted = receipt.outcome else { throw V2RoomWriteStoreError.corruptPersistenceState }
                            } else { #expect(receipt.outcome == .rejected(.directPolicyDenied)) }
                        }
                    }
                    try await send()
                    for table in tables {
                        try await controlSQL.raw("ALTER TABLE im_v2.\(unsafeRaw: table) RENAME TO \(unsafeRaw: table + "_reply_hidden")").run()
                        hidden.withLock { $0.append(table) }
                    }
                    if recipientHasReplied && mode != "scalar" {
                        let ownerTables = ["direct_room_pairs", "shard_admission_pools"]
                        for table in ownerTables {
                            try await ownerSQL.raw("ALTER TABLE im_v2.\(unsafeRaw: table) RENAME TO \(unsafeRaw: table + "_established_hidden")").run()
                        }
                        do { try await send() }
                        catch {
                            for table in ownerTables.reversed() {
                                try? await ownerSQL.raw("ALTER TABLE im_v2.\(unsafeRaw: table + "_established_hidden") RENAME TO \(unsafeRaw: table)").run()
                            }
                            throw error
                        }
                        for table in ownerTables.reversed() {
                            try await ownerSQL.raw("ALTER TABLE im_v2.\(unsafeRaw: table + "_established_hidden") RENAME TO \(unsafeRaw: table)").run()
                        }
                        let stages = metrics.sendOperationBatchMetricsSnapshot().stages
                        #expect(stages[.ownerPreflight]?.count ?? 0 == 0)
                        #expect(stages[.ownerRuntimeState]?.count == 2)
                    } else { try await send() }
                    #expect(try await ownerSQL.raw("SELECT count(*)::bigint AS value FROM im_v2.messages WHERE room_id=\(bind: room.roomID.uuidValue!)").first(decoding: PolicyDomainCount.self)?.value == (recipientHasReplied ? 2 : 0))
                    for table in hidden.withLock { $0 }.reversed() {
                        try await controlSQL.raw("ALTER TABLE im_v2.\(unsafeRaw: table + "_reply_hidden") RENAME TO \(unsafeRaw: table)").run()
                    }
                    hidden.withLock { $0 = [] }
                }
                try await host.shutdown(); try await policies.shutdown(); await directory.shutdown()
            } catch {
                for table in hidden.withLock { $0 }.reversed() {
                    try? await controlSQL.raw("ALTER TABLE im_v2.\(unsafeRaw: table + "_reply_hidden") RENAME TO \(unsafeRaw: table)").run()
                }
                try? await host.shutdown(); try? await policies.shutdown(); await directory.shutdown()
                throw error
            }
        }
    }

    @Test("current group authorization loads only sender state and rejects a committed sender disable from memory")
    func currentGroupPolicySenderState() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let profile = try forwardImportTestProfile()
            try await sql.raw("UPDATE im_v2.shard_admission_pools SET valid_until=clock_timestamp()+interval '10 minutes',command_window_limit=1000").run()
            let directory = PostgresV2PolicyOwnerDirectory(journal: .init(database: database),
                dispatcher: .init(database: database, projectionDelivery: SuccessfulProjectionDelivery()))
            let policies = V2RoomPolicyAuthorizationService(roomDatabase: database,
                policyOwners: directory, endpoint: "room-a", maximumRooms: 1)
            let store = PostgresV2MessageSendOperationStore(database: database,
                writes: PostgresV2RoomWriteStore(database: database, contentReviewMode: .disabled)
                    .usingControlDatabase(database).usingPolicyAuthorizations(policies))
            let hidden = Mutex(false)
            do {
                try await withRoomActivation(database: database, roomID: roomID) { token in
                    @Sendable func command() throws -> V2MessageSendOperationCommand {
                        try .init(command: .init(roomID: roomID, senderUserID: senderID, clientMessageID: .init(uuid: UUID()),
                            text: "current group", limits: .init(maxUTF8Bytes: 64)),
                            firstSubmissionDeadlineMilliseconds: UInt64(Date().timeIntervalSince1970 * 1000) + 60_000)
                    }
                    let prepared = try await policies.prepareOwnerBatches(store: store,
                        requests: [.init(commands: [command()], token: token, deadline: .now + .seconds(5))], now: Date.init)
                    let result = try await store.executeIndependentRoomTurns(prepared.map { try $0.get() },
                        capacityProfile: profile, identifiers: .init(), now: Date.init)
                    guard case .sendOperation(.receipt(let receipt))? = try result[0].get().first, case .accepted = receipt.outcome else {
                        throw V2RoomWriteStoreError.corruptPersistenceState
                    }
                    #expect(try await directory.cachedSnapshots(scopes: [.account(senderUUID)])?.count == 1)
                    #expect(try await directory.cachedSnapshots(scopes: [.account(memberTwoUUID)]) == nil)
                    let disable = V2DurablePolicyMutation.disable(.init(command: try .init(userID: senderID,
                        operationID: UUID(), reason: .policyEnforcement), operatorPrincipal: "current-group-test"))
                    _ = try await directory.changeExecution(disable)
                    try await sql.raw("ALTER TABLE im_v2.public_user_profiles RENAME TO current_group_hidden_profiles").run()
                    hidden.withLock { $0 = true }
                    let denied = try await policies.prepareOwnerBatches(store: store,
                        requests: [.init(commands: [command()], token: token, deadline: .now + .seconds(5))], now: Date.init)
                    let deniedResult = try await store.executeIndependentRoomTurns(denied.map { try $0.get() },
                        capacityProfile: profile, identifiers: .init(), now: Date.init)
                    guard case .sendOperation(.receipt(let rejection))? = try deniedResult[0].get().first else {
                        throw V2RoomWriteStoreError.corruptPersistenceState
                    }
                    #expect(rejection.outcome == .rejected(.permissionDenied))
                    #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM pg_catalog.pg_class WHERE oid=to_regclass('im_v2.policy_authorization_holders')").first(decoding: PolicyDomainCount.self)?.value == 0)
                    try await sql.raw("ALTER TABLE im_v2.current_group_hidden_profiles RENAME TO public_user_profiles").run()
                    hidden.withLock { $0 = false }
                }
                try await policies.shutdown(); await directory.shutdown()
            } catch {
                if hidden.withLock({ $0 }) { try? await sql.raw("ALTER TABLE im_v2.current_group_hidden_profiles RENAME TO public_user_profiles").run() }
                try? await policies.shutdown(); await directory.shutdown()
                throw error
            }
        }
    }

    @Test("current policy service prepares real sends without registrations, replays receipts after block and restores sending from memory",
          arguments: [(false, false, false), (false, false, true), (false, true, false), (false, true, true),
                      (true, false, false), (true, false, true), (true, true, false), (true, true, true)])
    func currentPolicyServiceSendAndReplay(preborrow: Bool, directPipeline: Bool, friends: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, controlSQL, ownerSQL, _ in
            let now = Date(), profile = try forwardImportTestProfile(), metrics = V2SendOperationBatchMetrics()
            try await ownerSQL.raw("UPDATE im_v2.shard_admission_pools SET valid_until=clock_timestamp()+interval '10 minutes',command_window_limit=1000").run()
            let room = try await V2DirectRoomOperationTestFixture(store: PostgresV2DirectMessagingStore(database: owner,
                identityReader: PostgresV2DirectRoomIdentityReader(database: control), projectionDelivery: SuccessfulProjectionDelivery()),
                capacityProfile: profile, roomShardID: "room-b", now: { now }).openedIdentity(actorUserID: senderID,
                    operationID: .init(uuid: UUID()), targetUserID: .init(uuid: memberTwoUUID),
                    firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
            if friends {
                try await controlSQL.raw("INSERT INTO im_v2.user_relationships VALUES (LEAST(\(bind: senderUUID)::uuid,\(bind: memberTwoUUID)::uuid),GREATEST(\(bind: senderUUID)::uuid,\(bind: memberTwoUUID)::uuid),'accepted',\(bind: senderUUID),clock_timestamp())").run()
            }
            // Command capacity is unrelated to message validity, including cold initialization.
            try await ownerSQL.raw("UPDATE im_v2.room_admission SET command_window_used=command_window_limit WHERE room_id=\(bind: room.roomID.uuidValue!)").run()
            try await ownerSQL.raw("UPDATE im_v2.shard_admission_pools SET command_window_used=command_window_limit,valid_until=clock_timestamp()-interval '1 minute'").run()

            let directory = PostgresV2PolicyOwnerDirectory(journal: .init(database: control, stateMetrics: metrics),
                dispatcher: .init(database: control, projectionDelivery: SuccessfulProjectionDelivery()))
            let policies = V2RoomPolicyAuthorizationService(roomDatabase: owner,
                policyOwners: directory, endpoint: "room-b", maximumRooms: 1,
                sendOperationMetrics: metrics)
            let writes = PostgresV2RoomWriteStore(database: owner,
                strangerMessagePolicy: try .init(maximumMessagesPerWindow: 10, window: 86_400), contentReviewMode: .disabled)
                .usingControlDatabase(control).usingPolicyAuthorizations(policies)
            let store = PostgresV2MessageSendOperationStore(database: owner, writes: writes, sendOperationMetrics: metrics)
            let social = PostgresV2SocialRelationshipStore(database: control, projectionDelivery: SuccessfulProjectionDelivery(), policyOwners: directory)
            try await ownerSQL.raw("CREATE TABLE im_v2.merged_owner_statement_counts (table_name text NOT NULL, combined boolean NOT NULL)").run()
            try await ownerSQL.raw("""
                CREATE FUNCTION im_v2.count_merged_owner_statement() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN
                    INSERT INTO im_v2.merged_owner_statement_counts VALUES
                        (TG_TABLE_NAME,position('imv2_plain_direct_append' in current_query())>0);
                    RETURN NULL;
                END $$
                """).run()
            for table in ["messages", "message_send_completions"] {
                try await ownerSQL.raw("CREATE TRIGGER count_merged_owner_statement AFTER INSERT ON im_v2.\(unsafeRaw: table) FOR EACH STATEMENT EXECUTE FUNCTION im_v2.count_merged_owner_statement()").run()
            }
            let tables = ["public_user_profiles", "account_disables", "special_accounts", "user_blocks", "user_relationships", "user_stranger_message_preferences"]
            let hidden = Mutex<[String]>([])
            do {
                try await withRoomActivation(database: owner, roomID: room.roomID, shardID: "room-b") { token in
                    @Sendable func command() throws -> V2MessageSendOperationCommand {
                        try .init(command: .init(roomID: room.roomID, senderUserID: senderID,
                            clientMessageID: .init(uuid: UUID()), text: "current service", limits: .init(maxUTF8Bytes: 64)),
                            firstSubmissionDeadlineMilliseconds: UInt64(Date().timeIntervalSince1970 * 1000) + 60_000)
                    }
                    @Sendable func prepare(_ commands: [V2MessageSendOperationCommand]) async throws -> V2PreparedMessageSendBatch {
                        let request = V2MessageSendPreparationRequest(commands: commands,
                            token: token, deadline: .now + .seconds(5))
                        if directPipeline {
                            return try await policies.prepareOwnerBatches(store: store,
                                requests: [request], now: Date.init)[0].get()
                        }
                        let result = try await store.readOwnerPreparationInputs([request], now: Date.init)
                        let input = try #require(result.first).get()
                        #expect(input.request.commands == commands && input.request.token == token)
                        #expect(input.request.deadline <= request.deadline)
                        let unrelatedStore = PostgresV2MessageSendOperationStore(database: owner, writes: writes)
                        await #expect(throws: V2RoomCallFailure.notAccepted(.invalidRequest)) {
                            try await policies.prepareOwnerPolicyInput(store: unrelatedStore, input: input)
                        }
                        let policiesBefore = metrics.sendOperationBatchMetricsSnapshot().stages[.policyOwnerState]?.count ?? 0
                        await #expect(throws: V2RoomCallFailure.notAccepted(.deadlineExceeded)) {
                            try await V2RoomSQLDeadline.withDeadline(.now - .milliseconds(1)) {
                                try await policies.prepareOwnerPolicyInput(store: store, input: input)
                            }
                        }
                        #expect(metrics.sendOperationBatchMetricsSnapshot().stages[.policyOwnerState]?.count ?? 0 == policiesBefore)
                        let prepared = try await policies.prepareOwnerPolicyInput(store: store, input: input)
                        #expect(prepared.originalDeadline <= input.request.deadline)
                        return prepared
                    }
                    @Sendable func execute(_ prepared: V2PreparedMessageSendBatch, requireSQL: Bool = false) async throws -> [V2RoomMessagingResult] {
                        if preborrow && directPipeline && requireSQL {
                            // Follow the production physical-loan -> policy detached
                            // execution -> pinned transaction path, not a direct loan.
                            let transactions = Mutex(0)
                            let checked = store.observingOwnerTransactions { _, _, _ in
                                // The fixture owns one physical EventLoop. This
                                // callback runs after a real SQL Future resumes,
                                // inside the policy execution task.
                                #expect(owner.eventLoop.inEventLoop)
                                transactions.withLock { $0 += 1 }
                            }
                            let (value, finalize) = try await checked.withScheduledSendConnection(
                                deadline: V2RoomSQLDeadline.current ?? (.now + .seconds(5))) { connection in
                                let value = try await connection.execute(prepared, profile, .init(), Date.init)
                                #expect(owner.eventLoop.inEventLoop)
                                return (value, connection.finalize)
                            }
                            await finalize()
                            #expect(transactions.withLock { $0 } > 0)
                            return value
                        }
                        let result: [Result<[V2RoomMessagingResult], any Error>]
                        if preborrow {
                            result = try await store.executeIndependentRoomTurnsPreborrowing([prepared], capacityProfile: profile,
                                identifiers: .init(), now: Date.init,
                                control: .init(connectionAcquired: {}, beforeFirstBegin: {}, interrupted: { _ in }))
                        } else if friends && !directPipeline {
                            return try await store.executePreparedSendBatch(prepared, capacityProfile: profile,
                                identifiers: .init(), now: Date.init)
                        } else {
                            result = try await store.executeIndependentRoomTurns([prepared], capacityProfile: profile,
                                identifiers: .init(), now: Date.init)
                        }
                        return try #require(result.first).get()
                    }
                    let first = try command(), second = try command()
                    struct MergedReceiptCount: Decodable { let value: Int64 }
                    let firstPrepared = try await prepare([first, second])
                    let racingPrepared = try await prepare([first, second])
                    let accepted = try await execute(firstPrepared, requireSQL: true)
                    let mergedStages = metrics.sendOperationBatchMetricsSnapshot().stages
                    #expect(mergedStages[.ownerPreflight]?.count ?? 0 == (friends ? 0 : 1))
                    #expect(mergedStages[.ownerRuntimeState]?.count ?? 0 == (friends ? 1 : 0))
                    #expect(mergedStages[.ownerReceiptRead]?.count ?? 0 == 0)
                    #expect(try await ownerSQL.raw("SELECT count(*)::bigint AS value FROM im_v2.message_send_completions").first(decoding: MergedReceiptCount.self)?.value == 2)
                    #expect(try await ownerSQL.raw("SELECT count(*)::bigint AS value FROM im_v2.merged_owner_statement_counts").first(decoding: MergedReceiptCount.self)?.value == 2)
                    #expect(try await ownerSQL.raw("SELECT count(*)::bigint AS value FROM im_v2.merged_owner_statement_counts WHERE NOT combined").first(decoding: MergedReceiptCount.self)?.value == 0)
                    // A handle prepared before the first commit must recheck
                    // the durable result without allocating another sequence.
                    #expect(try await execute(racingPrepared) == accepted)
                    let bodiesBeforeReplay = metrics.sendOperationBatchMetricsSnapshot().stages[.ownerBody]?.count
                    #expect(try await execute(prepare([first, second])) == accepted)
                    #expect(metrics.sendOperationBatchMetricsSnapshot().stages[.ownerBody]?.count == bodiesBeforeReplay)
                    #expect(accepted.count == 2)
                    if directPipeline {
                        // Direct preparation must not use a logical cold-request queue.
                        #expect(metrics.sendOperationBatchMetricsSnapshot().stages[.policyOwnerMemoryProbe]?.count == 2)
                    }
                    for value in accepted {
                        guard case .sendOperation(.receipt(let receipt)) = value, case .accepted = receipt.outcome else {
                            throw V2RoomWriteStoreError.corruptPersistenceState
                        }
                    }
                    // A fully warm preparation must work while every table
                    // formerly joined by readBudgetSnapshot is unavailable.
                    // Simulate the response being lost after COMMIT. A new
                    // query has no dependency on the old actor or activation table.
                    let resultQuery = try V2MessageSendOperationRecoveryRequest(identity: first.identity,
                        fingerprint: first.fingerprint, domainFingerprint: first.command.fingerprint)
                    let missing = try command()
                    let absentQuery = try V2MessageSendOperationRecoveryRequest(identity: missing.identity,
                        fingerprint: missing.fingerprint, domainFingerprint: missing.command.fingerprint)
                    let missingPrepared = try await prepare([missing])
                    let runtimeTables = friends ? ["room_memberships", "room_member_mutes", "direct_room_pairs", "shard_admission_pools", "room_admission"] : []
                    var runtimeHidden: [String] = []
                    do {
                        for table in runtimeTables {
                            try await ownerSQL.raw("ALTER TABLE im_v2.\(unsafeRaw: table) RENAME TO \(unsafeRaw: table + "_runtime_hidden")").run()
                            runtimeHidden.append(table)
                        }
                        #expect(try await PostgresV2MessageSendOperationStore.queryRecovery(resultQuery, database: owner)
                            == { if case .sendOperation(let result) = accepted[0] { return result }; return .unresolved }())
                        #expect(try await PostgresV2MessageSendOperationStore.queryRecovery(absentQuery, database: owner) == .unresolved)
                        // A fresh ordinary send also needs no durable activation
                        // read. This result was unresolved immediately before it.
                        let later = try await execute(missingPrepared)
                        guard case .sendOperation(.receipt(let lateReceipt)) = later[0], case .accepted = lateReceipt.outcome else {
                            throw V2RoomWriteStoreError.corruptPersistenceState
                        }
                        #expect(try await PostgresV2MessageSendOperationStore.queryRecovery(absentQuery, database: owner) == .receipt(lateReceipt))
                        for table in runtimeHidden.reversed() {
                            try await ownerSQL.raw("ALTER TABLE im_v2.\(unsafeRaw: table + "_runtime_hidden") RENAME TO \(unsafeRaw: table)").run()
                        }
                        runtimeHidden.removeAll()
                    } catch {
                        for table in runtimeHidden.reversed() {
                            try? await ownerSQL.raw("ALTER TABLE im_v2.\(unsafeRaw: table + "_runtime_hidden") RENAME TO \(unsafeRaw: table)").run()
                        }
                        throw error
                    }
                    let warmPreparationTables = ["rooms", "direct_room_pairs", "shard_admission_pools", "message_send_completions"]
                    var warmHidden: [String] = []
                    do {
                        for table in warmPreparationTables {
                            try await ownerSQL.raw("ALTER TABLE im_v2.\(unsafeRaw: table) RENAME TO \(unsafeRaw: table + "_preparation_hidden")").run()
                            warmHidden.append(table)
                        }
                        _ = try await prepare([command()])
                        for table in warmHidden.reversed() {
                            try await ownerSQL.raw("ALTER TABLE im_v2.\(unsafeRaw: table + "_preparation_hidden") RENAME TO \(unsafeRaw: table)").run()
                        }
                        warmHidden.removeAll()
                    } catch {
                        for table in warmHidden.reversed() {
                            try? await ownerSQL.raw("ALTER TABLE im_v2.\(unsafeRaw: table + "_preparation_hidden") RENAME TO \(unsafeRaw: table)").run()
                        }
                        throw error
                    }
                    if friends {
                        let drifted = try command(), driftPrepared = try await prepare([drifted])
                        try await ownerSQL.raw("UPDATE im_v2.room_admission SET command_window_used=0 WHERE room_id=\(bind: room.roomID.uuidValue!)").run()
                        let countBefore = try #require(try await ownerSQL.raw("SELECT command_window_used::bigint AS value FROM im_v2.room_admission WHERE room_id=\(bind: room.roomID.uuidValue!)").first(decoding: MergedReceiptCount.self)).value
                        let driftResult = try await execute(driftPrepared)
                        guard case .sendOperation(.receipt(let driftReceipt)) = driftResult[0], case .accepted = driftReceipt.outcome else {
                            throw V2RoomWriteStoreError.corruptPersistenceState
                        }
                        #expect(try await ownerSQL.raw("SELECT command_window_used::bigint AS value FROM im_v2.room_admission WHERE room_id=\(bind: room.roomID.uuidValue!)").first(decoding: MergedReceiptCount.self)?.value == countBefore)
                    }
                    let concurrentCommand = try command()
                    let leftPrepared = try await prepare([concurrentCommand])
                    let rightPrepared = try await prepare([concurrentCommand])
                    async let leftResult = execute(leftPrepared)
                    async let rightResult = execute(rightPrepared)
                    let concurrentResults = try await (leftResult, rightResult)
                    #expect(concurrentResults.0 == concurrentResults.1)
                    guard case .sendOperation(.receipt(let concurrentReceipt))? = concurrentResults.0.first,
                          case .accepted = concurrentReceipt.outcome else { throw V2RoomWriteStoreError.corruptPersistenceState }
                    #expect(try await ownerSQL.raw("SELECT count(*)::bigint AS value FROM im_v2.messages WHERE room_id=\(bind: room.roomID.uuidValue!) AND client_message_id=\(bind: concurrentCommand.command.clientMessageID.uuidValue!)").first(decoding: MergedReceiptCount.self)?.value == 1)
                    let block = try await social.freezeSocialFixture(actorUserID: senderID, targetUserID: .init(uuid: memberTwoUUID),
                        operation: .userBlock(.init(uuid: UUID())), action: .userBlock(.block), now: Date())
                    _ = try await social.submitSocialOperation(block)
                    let blockedCommand = try command()
                    let blockedResult = try await execute(prepare([blockedCommand]))
                    guard case .sendOperation(.receipt(let denied))? = blockedResult.first else {
                        throw V2RoomWriteStoreError.corruptPersistenceState
                    }
                    #expect(denied.outcome == .rejected(.directPolicyDenied))
                    let rejectionQuery = try V2MessageSendOperationRecoveryRequest(identity: blockedCommand.identity,
                        fingerprint: blockedCommand.fingerprint, domainFingerprint: blockedCommand.command.fingerprint)
                    #expect(try await PostgresV2MessageSendOperationStore.queryRecovery(rejectionQuery, database: owner) == .unresolved)
                    #expect(try await retiredDirectDenialTableIsAbsent(on: ownerSQL))
                    #expect(try await execute(prepare([first, second])) == accepted)
                    let unblock = try await social.freezeSocialFixture(actorUserID: senderID, targetUserID: .init(uuid: memberTwoUUID),
                        operation: .userBlock(.init(uuid: UUID())), action: .userBlock(.unblock), now: Date())
                    _ = try await social.submitSocialOperation(unblock)
                    // Rejections leave neither a durable result nor a replay
                    // cache entry. The same identity now uses the new policy.
                    let retriedBlocked = try await execute(prepare([blockedCommand]))
                    guard case .sendOperation(.receipt(let retried))? = retriedBlocked.first,
                          case .accepted = retried.outcome else { throw V2RoomWriteStoreError.corruptPersistenceState }
                    // A new store recovers both original and retried success.
                    let restarted = PostgresV2MessageSendOperationStore(database: owner, writes: writes)
                    for (repeated, expected) in [(first, Array(accepted.prefix(1))), (blockedCommand, retriedBlocked)] {
                        let request = V2MessageSendPreparationRequest(commands: [repeated], token: token,
                            deadline: .now + .seconds(5))
                        let freshPrepared = try await policies.prepareOwnerBatches(store: restarted, requests: [request], now: Date.init)[0].get()
                        let recovered = try await restarted.executeIndependentRoomTurns([freshPrepared], capacityProfile: profile,
                            identifiers: .init(), now: Date.init)[0].get()
                        #expect(recovered == expected)
                    }
                    let stateReads = metrics.sendOperationBatchMetricsSnapshot().stages[.policyOwnerStateFacts]?.count
                    for table in tables {
                        try await controlSQL.raw("ALTER TABLE im_v2.\(unsafeRaw: table) RENAME TO \(unsafeRaw: table + "_current_service_hidden")").run()
                        hidden.withLock { $0.append(table) }
                    }
                    let restored = try await execute(prepare([command()]))
                    guard case .sendOperation(.receipt(let receipt))? = restored.first, case .accepted = receipt.outcome else {
                        throw V2RoomWriteStoreError.corruptPersistenceState
                    }
                    // A completed identity with a changed payload must skip
                    // fresh policy preparation and retain its durable conflict,
                    // even with all control fact tables unavailable.
                    let conflict = try V2MessageSendOperationCommand(command: .init(roomID: room.roomID,
                        senderUserID: senderID, clientMessageID: first.command.clientMessageID,
                        text: "changed committed identity", limits: .init(maxUTF8Bytes: 64)),
                        firstSubmissionDeadlineMilliseconds: first.firstSubmissionDeadlineMilliseconds)
                    let policyPreparationsBefore = metrics.sendOperationBatchMetricsSnapshot().stages[.policyOwnerState]?.count ?? 0
                    let conflictResult = try await execute(prepare([conflict]))
                    #expect(conflictResult == [.sendOperation(.fingerprintConflict)])
                    #expect(metrics.sendOperationBatchMetricsSnapshot().stages[.policyOwnerState]?.count ?? 0 == policyPreparationsBefore)
                    #expect(metrics.sendOperationBatchMetricsSnapshot().stages[.policyOwnerStateFacts]?.count == stateReads)
                    #expect(try await controlSQL.raw("SELECT count(*)::bigint AS value FROM pg_catalog.pg_class WHERE oid=to_regclass('im_v2.policy_authorization_holders')").first(decoding: PolicyDomainCount.self)?.value == 0)
                    #expect(try await ownerSQL.raw("SELECT count(*)::bigint AS value FROM pg_catalog.pg_class WHERE oid=to_regclass('im_v2.room_policy_authorization_leases')").first(decoding: PolicyDomainCount.self)?.value == 0)
                    let failedCommand = try command()
                    let sequenceBefore = try await ownerSQL.raw("SELECT room_sequence AS value FROM im_v2.rooms WHERE room_id=\(bind: room.roomID.uuidValue!)").first(decoding: MergedReceiptCount.self)?.value
                    try await ownerSQL.raw("""
                        CREATE FUNCTION im_v2.merged_receipt_failure() RETURNS trigger LANGUAGE plpgsql AS $$
                        BEGIN
                            IF NEW.client_message_id='\(unsafeRaw: failedCommand.command.clientMessageID.rawValue)'::uuid THEN
                                RAISE EXCEPTION 'injected merged receipt failure' USING ERRCODE='23514';
                            END IF;
                            RETURN NEW;
                        END $$
                        """).run()
                    try await ownerSQL.raw("CREATE TRIGGER merged_receipt_failure BEFORE INSERT ON im_v2.message_send_completions FOR EACH ROW EXECUTE FUNCTION im_v2.merged_receipt_failure()").run()
                    do {
                        let failureResults = try await execute(prepare([failedCommand]))
                        for result in failureResults {
                            guard case .sendOperation(.deferred) = result else {
                                Issue.record("Injected receipt failure must not return a committed result")
                                continue
                            }
                        }
                    } catch { /* A propagated database failure also leaves no committed result. */ }
                    for table in ["messages", "message_send_completions"] {
                        let column = "client_message_id"
                        #expect(try await ownerSQL.raw("SELECT count(*)::bigint AS value FROM im_v2.\(unsafeRaw: table) WHERE room_id=\(bind: room.roomID.uuidValue!) AND \(unsafeRaw: column)=\(bind: failedCommand.command.clientMessageID.uuidValue!)").first(decoding: MergedReceiptCount.self)?.value == 0)
                    }
                    #expect(try await ownerSQL.raw("SELECT room_sequence AS value FROM im_v2.rooms WHERE room_id=\(bind: room.roomID.uuidValue!)").first(decoding: MergedReceiptCount.self)?.value == sequenceBefore)
                    try await ownerSQL.raw("DROP TRIGGER merged_receipt_failure ON im_v2.message_send_completions").run()
                    try await ownerSQL.raw("DROP FUNCTION im_v2.merged_receipt_failure()").run()
                    // A retry after the fault is removed commits normally.
                    let retry = try await execute(prepare([failedCommand]))
                    guard case .sendOperation(.receipt(let retried))? = retry.first,
                          case .accepted = retried.outcome else { throw V2RoomWriteStoreError.corruptPersistenceState }
                    if friends && directPipeline && preborrow {
                        let uncertain = try command(), uncertainPrepared = try await prepare([uncertain])
                        try await ownerSQL.raw("""
                            CREATE FUNCTION im_v2.runtime_state_commit_wait() RETURNS trigger LANGUAGE plpgsql AS $$
                            BEGIN PERFORM pg_sleep(1); RETURN NEW; END $$
                            """).run()
                        try await ownerSQL.raw("CREATE CONSTRAINT TRIGGER runtime_state_commit_wait AFTER INSERT ON im_v2.messages DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION im_v2.runtime_state_commit_wait()").run()
                        do {
                            _ = try await V2RoomSQLDeadline.withDeadline(.now + .milliseconds(150)) {
                                try await execute(uncertainPrepared)
                            }
                            Issue.record("deferred COMMIT must preserve uncertainty")
                        } catch { #expect(error is V2RoomTransactionOutcomeUnknown) }
                        // DDL joins the server's actual transaction settlement.
                        try await ownerSQL.raw("DROP TRIGGER runtime_state_commit_wait ON im_v2.messages").run()
                        try await ownerSQL.raw("DROP FUNCTION im_v2.runtime_state_commit_wait()").run()
                        let persisted = try #require(try await ownerSQL.raw("SELECT room_sequence AS value FROM im_v2.rooms WHERE room_id=\(bind: room.roomID.uuidValue!)").first(decoding: MergedReceiptCount.self)).value
                        let resumed = try await execute(prepare([command()]))
                        guard case .sendOperation(.receipt(let resumedReceipt)) = resumed[0], case .accepted(let resumedAcceptance) = resumedReceipt.outcome else {
                            throw V2RoomWriteStoreError.corruptPersistenceState
                        }
                        #expect(resumedAcceptance.roomSequence == UInt64(persisted+1))
                        let recovery = try V2MessageSendOperationRecoveryRequest(identity: uncertain.identity,
                            fingerprint: uncertain.fingerprint, domainFingerprint: uncertain.command.fingerprint)
                        let recovered = try await PostgresV2MessageSendOperationStore.queryRecovery(recovery, database: owner)
                        if case .receipt(let receipt) = recovered {
                            let identity = try uncertain.identity
                            #expect(receipt.identity == identity)
                        } else { #expect(recovered == .unresolved) }
                    }
                    for table in hidden.withLock { $0 }.reversed() {
                        try await controlSQL.raw("ALTER TABLE im_v2.\(unsafeRaw: table + "_current_service_hidden") RENAME TO \(unsafeRaw: table)").run()
                    }
                    hidden.withLock { $0 = [] }
                }
                try await policies.shutdown(); await directory.shutdown()
            } catch {
                for table in hidden.withLock { $0 }.reversed() {
                    try? await controlSQL.raw("ALTER TABLE im_v2.\(unsafeRaw: table + "_current_service_hidden") RENAME TO \(unsafeRaw: table)").run()
                }
                try? await policies.shutdown(); await directory.shutdown()
                throw error
            }
        }
    }

    @Test("stranger preference uses policy owner commit time and preserves original replay and conflicts")
    func currentStrangerPreferenceUsesOwnerCommitTime() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let owners = PostgresV2PolicyOwnerDirectory(journal: .init(database: database),
                dispatcher: .init(database: database, projectionDelivery: SuccessfulProjectionDelivery()))
            let store = PostgresV2AccountPreferenceOperationStore(database: database,
                projectionDelivery: SuccessfulProjectionDelivery(), policyOwners: owners)
            let command = try await store.freezePreferenceFixture(owner: senderID,
                operation: .strangerMessagePreference(.init(uuid: UUID())), value: .strangerMessage(.deny), now: Date())
            let before = UInt64(Date().timeIntervalSince1970 * 1000)
            let result = try await store.submit(command, now: Date(timeIntervalSince1970: .nan))
            let after = UInt64(Date().timeIntervalSince1970 * 1000)
            guard case .receipt(let receipt) = result, case .applied(.strangerMessage(.deny), 1) = receipt.outcome else {
                throw V2AccountPreferenceValidationError.invalidReceipt
            }
            #expect(receipt.validates(command: command))
            #expect(before <= receipt.resolvedAtMilliseconds && receipt.resolvedAtMilliseconds <= after)
            let saved = try #require(try await sql.raw("""
                SELECT floor(extract(epoch FROM updated_at)*1000)::bigint AS value
                FROM im_v2.user_stranger_message_preferences WHERE user_id=\(bind: senderUUID)
                """).first(decoding: PolicyDomainCount.self))
            #expect(UInt64(saved.value) == receipt.resolvedAtMilliseconds)
            for seconds in [Double.nan, .infinity, -.infinity, 1_750_000_000] {
                #expect(try await store.submit(command, now: Date(timeIntervalSince1970: seconds)) == result)
            }
            let changed = try V2AccountPreferenceCommand(identity: command.identity, value: .strangerMessage(.allow),
                expectedRevision: command.expectedRevision,
                firstSubmissionDeadlineMilliseconds: command.firstSubmissionDeadlineMilliseconds)
            #expect(try await store.submit(changed, now: Date()) == .fingerprintConflict)
            #expect(try await count("im_v2.account_preference_receipts", on: sql) == 1)
            await owners.shutdown()
        }
    }

    @Test("room write refuses unscoped messages before entering SQL authorization", arguments: [false, true])
    func currentRoomWriteRequiresPolicyExecution(controlBound: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, _, sql, room in
            let raw = PostgresV2RoomWriteStore(database: owner, contentReviewMode: .disabled)
            let write = controlBound ? raw.usingControlDatabase(control) : raw
            let command = try V2SendMessageCommand(roomID: room, senderUserID: senderID,
                clientMessageID: .init(uuid: UUID()), text: "unscoped message", limits: .init(maxUTF8Bytes: 64))
            let profile = try forwardImportTestProfile(), now = Date()
            let identifiers = try V2AcceptanceIDFactory().make(at: now)
            await #expect(throws: V2ActorContractError.invalidConfiguration("message policy execution required")) {
                try await write.accept(command: command, capacityProfile: profile, identifiers: identifiers, now: now)
            }
            for table in ["messages"] {
                #expect(try await count("im_v2." + table, on: sql) == 0)
            }
        }
    }

    @Test("account disable through policy owner preserves rollback and committed replay")
    func currentAccountDisableRequiresPolicyOwner() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let command = try V2AccountDisableCommand(userID: senderID, operationID: UUID(), reason: .policyEnforcement)
            #expect(try await count("im_v2.account_disables", on: sql) == 0)
            let owners = PostgresV2PolicyOwnerDirectory(journal: .init(database: database),
                dispatcher: .init(database: database, projectionDelivery: SuccessfulProjectionDelivery()))
            let service = try V2PostgresAccountDisableService(operatorPrincipal: "policy-disable-test", policyOwners: owners)
            try await sql.raw("CREATE FUNCTION im_v2.fail_current_disable() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'injected disable failure'; END $$").run()
            try await sql.raw("CREATE TRIGGER fail_current_disable BEFORE INSERT ON im_v2.public_profile_update_outbox FOR EACH ROW EXECUTE FUNCTION im_v2.fail_current_disable()").run()
            await #expect(throws: (any Error).self) { try await service.disable(command) }
            #expect(try await count("im_v2.account_disables", on: sql) == 0)
            #expect(try await count("im_v2.user_direct_send_policy_versions", on: sql) == 0)
            try await sql.raw("DROP TRIGGER fail_current_disable ON im_v2.public_profile_update_outbox").run()
            try await sql.raw("DROP FUNCTION im_v2.fail_current_disable()").run()
            let before = Date()
            guard case .disabled(let committedAt) = try await service.disable(command) else {
                Issue.record("Policy owner must commit disable after rollback")
                await owners.shutdown()
                return
            }
            #expect(committedAt >= before.addingTimeInterval(-0.001) && committedAt <= Date())
            for _ in 0..<3 {
                #expect(try await service.disable(command) == .idempotent(disabledAt: committedAt))
            }
            let other = try V2AccountDisableCommand(userID: senderID, operationID: UUID(), reason: .userRequested)
            #expect(try await service.disable(other) == .alreadyDisabled(disabledAt: committedAt))
            #expect(try await count("im_v2.account_disables", on: sql) == 1)
            #expect(try await count("im_v2.public_profile_update_outbox", on: sql) == 1)
            #expect(try await count("im_v2.public_user_profiles WHERE state='suspended'", on: sql) == 1)
            try await assertRetiredDirectAuthorizationSchemaAbsent(on: sql)
            await owners.shutdown()
        }
    }

    @Test("social mutations require policy owners and replay their committed result without legacy authorization", arguments: [false, true])
    func currentSocialOperationRequiresPolicyOwner(block: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let owners = PostgresV2PolicyOwnerDirectory(journal: .init(database: database),
                dispatcher: .init(database: database, projectionDelivery: SuccessfulProjectionDelivery()))
            let store = PostgresV2SocialRelationshipStore(database: database,
                projectionDelivery: SuccessfulProjectionDelivery(), policyOwners: owners)
            let command = try await store.freezeSocialFixture(actorUserID: senderID,
                targetUserID: .init(uuid: memberTwoUUID),
                operation: block ? .userBlock(.init(uuid: UUID())) : .relationship(.init(uuid: UUID())),
                action: block ? .userBlock(.block) : .relationship(.request), now: Date())
            for table in ["user_relationships", "user_blocks", "social_operation_receipts"] {
                #expect(try await count("im_v2." + table, on: sql) == 0)
            }
            let beforeCommit = Date()
            let result = try await store.submitSocialOperation(command)
            let afterCommit = Date()
            guard case .receipt(let receipt) = result, case .applied = receipt.outcome else {
                Issue.record("Current policy owner must commit social mutation")
                await owners.shutdown()
                return
            }
            #expect(receipt.validates(command: command))
            let beforeMilliseconds = UInt64(try v2GatewayMilliseconds(beforeCommit))
            let afterMilliseconds = UInt64(try v2GatewayMilliseconds(afterCommit))
            #expect(receipt.resolvedAtMilliseconds >= beforeMilliseconds &&
                    receipt.resolvedAtMilliseconds <= afterMilliseconds)
            let persisted = try #require(try await sql.raw("SELECT (receipt->>'resolvedAtMilliseconds')::bigint AS value FROM im_v2.social_operation_receipts WHERE actor_user_id = \(bind: senderUUID) AND operation_id = \(bind: UUID(uuidString: command.identity.operation.rawOperationID)!)").first(decoding: CountRow.self))
            #expect(persisted.value == Int64(receipt.resolvedAtMilliseconds))
            for _ in 0..<4 {
                #expect(try await store.submitSocialOperation(command) == result)
            }
            #expect(try await count("im_v2.social_operation_receipts", on: sql) == 1)
            #expect(try await count("im_v2." + (block ? "user_blocks" : "user_relationships"), on: sql) == 1)
            try await assertRetiredDirectAuthorizationSchemaAbsent(on: sql)
            await owners.shutdown()
        }
    }

    @Test("local preference persistence rejects stranger policy mutations before writing")
    func currentStrangerPreferenceRequiresPolicyOwner() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let store = V2PostgresAccountPreferencePersistence(database: database,
                projectionDelivery: SuccessfulProjectionDelivery())
            let command = try await store.freezePreferenceFixture(owner: senderID,
                operation: .strangerMessagePreference(.init(uuid: UUID())), value: .strangerMessage(.deny), now: Date())
            await #expect(throws: V2AccountPreferenceValidationError.invalidCommand) {
                try await store.submit(command, now: Date())
            }
            #expect(try await count("im_v2.user_stranger_message_preferences", on: sql) == 0)
            #expect(try await count("im_v2.account_preference_receipts", on: sql) == 0)
        }
    }

    @Test("current policy mutations finish while an authorized message waits for COMMIT and new authorization uses updated memory",
          arguments: ["block", "remove", "stranger", "disable"])
    func currentPolicyMutationDoesNotWaitForRoom(kind: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, controlSQL, ownerSQL, _ in
            let now = Date(), profile = try forwardImportTestProfile()
            try await ownerSQL.raw("UPDATE im_v2.shard_admission_pools SET valid_until=clock_timestamp()+interval '10 minutes'").run()
            let direct = V2DirectRoomOperationTestFixture(store: PostgresV2DirectMessagingStore(database: owner,
                identityReader: PostgresV2DirectRoomIdentityReader(database: control), projectionDelivery: SuccessfulProjectionDelivery()),
                capacityProfile: profile, roomShardID: "room-b", now: { now })
            let room = try await direct.openedIdentity(actorUserID: senderID, operationID: .init(uuid: UUID()),
                targetUserID: .init(uuid: memberTwoUUID), firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
            if kind == "block" || kind == "remove" {
                try await controlSQL.raw("INSERT INTO im_v2.user_relationships VALUES (LEAST(\(bind: senderUUID)::uuid,\(bind: memberTwoUUID)::uuid),GREATEST(\(bind: senderUUID)::uuid,\(bind: memberTwoUUID)::uuid),'accepted',\(bind: senderUUID),clock_timestamp())").run()
            }
            if kind == "remove" {
                try await controlSQL.raw("INSERT INTO im_v2.user_stranger_message_preferences VALUES (\(bind: memberTwoUUID),false,clock_timestamp())").run()
            }
            let journal = PostgresV2PolicyAuthorizationJournal(database: control)
            let directory = PostgresV2PolicyOwnerDirectory(journal: journal,
                dispatcher: .init(database: control, projectionDelivery: SuccessfulProjectionDelivery()))
            // Warm the potential non-friend branch too. Hiding fact tables
            // after the mutation then proves the new decision is memory-only.
            _ = try await directory.registrationSnapshots(scopes: [.account(senderUUID), .account(memberTwoUUID),
                .pair(senderUUID, memberTwoUUID), .stranger(memberTwoUUID)])
            let mutation = try await policyDomainCommand(kind: kind, database: control)
            try await withRoomActivation(database: owner, roomID: room.roomID, shardID: "room-b") { token in
                let host = PostgresV2RoomPolicyAuthorizationDirectory(database: owner, endpoint: "room-b", maximumRooms: 1,
                    currentLoader: { _, sender, recipient, _ in
                        let recipient = try #require(recipient)
                        let scopes: [V2PolicyAuthorizationScope] = [.account(sender), .account(recipient), .pair(sender, recipient)]
                        var states = try await directory.registrationSnapshots(scopes: scopes)
                        let relationship = try #require(states.first { $0.scope.key == V2PolicyAuthorizationScope.pair(sender, recipient).key })
                        guard case .pair(let social) = relationship.facts else { throw V2PolicyAuthorizationLifecycleError.invalidTarget }
                        if !social.isFriend { states += try await directory.registrationSnapshots(scopes: [.stranger(recipient)]) }
                        return try .direct(pair: .init(sender: sender, recipient: recipient), snapshots: states)
                    })
                let runtime = try await host.registry(token: token).runtime(sender: senderUUID, token: token)
                let command = try V2SendMessageCommand(roomID: room.roomID, senderUserID: senderID,
                    clientMessageID: .init(uuid: UUID()), text: "current policy", limits: .init(maxUTF8Bytes: 64))
                let base = PostgresV2RoomWriteStore(database: owner, contentReviewMode: .disabled)
                    .usingControlDatabase(control).usingActivationScope(try .init(tokens: [token]))
                let barrier = CurrentPolicyMessageBarrier()
                let held = Task {
                    try await runtime.execute(command: command, callerDeadline: .now + .seconds(10)) { execution in
                        try await owner.transaction { transaction in
                            let result = try await base.usingPolicyExecution(execution).usingWorkloadDatabase(transaction)
                                .usingOperationTransaction().accept(command: command, capacityProfile: profile,
                                    identifiers: V2AcceptanceIDFactory().make(at: Date()), now: Date())
                            await barrier.hold()
                            return (result, execution)
                        }
                    }
                }
                let tables = ["public_user_profiles", "account_disables", "special_accounts", "user_blocks", "user_relationships", "user_stranger_message_preferences"]
                let hidden = Mutex<[String]>([])
                do {
                    let deadline = ContinuousClock.now + .seconds(5)
                    while !(await barrier.entered), .now < deadline { await Task.yield() }
                    #expect(await barrier.entered)
                    try await assertRetiredDirectAuthorizationSchemaAbsent(on: controlSQL)
                    // This call must finish with the actual message SQL still
                    // held. A room-draining implementation times out here.
                    _ = try await directory.changeExecution(mutation)
                    #expect(await runtime.pressure().executions == 1)
                    #expect(await barrier.entered)
                    #expect(await !barrier.released)
                    for table in tables {
                        try await controlSQL.raw("ALTER TABLE im_v2.\(unsafeRaw: table) RENAME TO \(unsafeRaw: table + "_current_hidden")").run()
                        hidden.withLock { $0.append(table) }
                    }
                    let next = try V2SendMessageCommand(roomID: room.roomID, senderUserID: senderID,
                        clientMessageID: .init(uuid: UUID()), text: "new authorization", limits: .init(maxUTF8Bytes: 64))
                    let nextPrepared = try await runtime.prepareBatch(commands: [next], callerDeadline: .now + .seconds(5))
                    let updatedStates = try #require(try await directory.cachedSnapshots(scopes: [
                        .account(senderUUID), .account(memberTwoUUID), .pair(senderUUID, memberTwoUUID), .stranger(memberTwoUUID)]))
                    let pairState = try #require(updatedStates.first { $0.scope.key == V2PolicyAuthorizationScope.pair(senderUUID, memberTwoUUID).key })
                    guard case .pair(let pairFacts) = pairState.facts else { throw V2PolicyAuthorizationLifecycleError.invalidTarget }
                    let requiredStates = pairFacts.isFriend ? updatedStates.filter { $0.scope != .stranger(memberTwoUUID) } : updatedStates
                    let updatedPolicy = try #require(try V2CurrentRoomPolicySnapshot.direct(
                        pair: .init(sender: senderUUID, recipient: memberTwoUUID), snapshots: requiredStates).policy)
                    switch kind {
                    case "block": #expect(updatedPolicy.blocked)
                    case "disable": #expect(!updatedPolicy.recipient.isActive)
                    default: #expect(!updatedPolicy.isFriend && !updatedPolicy.allowsStrangers)
                    }
                    #expect(try await controlSQL.raw("SELECT count(*)::bigint AS value FROM pg_catalog.pg_class WHERE oid=to_regclass('im_v2.policy_authorization_holders')").first(decoding: PolicyDomainCount.self)?.value == 0)
                    #expect(try await controlSQL.raw("SELECT count(*)::bigint AS value FROM pg_catalog.pg_class WHERE oid=to_regclass('im_v2.policy_authorization_revocations')").first(decoding: PolicyDomainCount.self)?.value == 0)
                    #expect(try await ownerSQL.raw("SELECT count(*)::bigint AS value FROM pg_catalog.pg_class WHERE oid=to_regclass('im_v2.room_policy_authorization_leases')").first(decoding: PolicyDomainCount.self)?.value == 0)
                    await barrier.release()
                    let (accepted, expiredExecution) = try await held.value
                    guard case .accepted = accepted else { throw V2RoomWriteStoreError.corruptPersistenceState }
                    #expect(await runtime.pressure().executions == 0)
                    await #expect(throws: V2SendOperationResponseError.directPolicyDenied) {
                        try await runtime.executePreparedBatch(nextPrepared) { execution in
                            try await base.usingPolicyExecution(execution).accept(command: next, capacityProfile: profile,
                                identifiers: V2AcceptanceIDFactory().make(at: Date()), now: Date())
                        }
                    }
                    await #expect(throws: V2RoomPolicyExecutionFailure.invalidPermit) {
                        try await owner.transaction { transaction in
                            try await expiredExecution.requireActive(roomID: room.roomID.uuidValue!, senderID: senderUUID,
                                clientMessageID: command.clientMessageID.uuidValue!, sql: try #require(transaction as? any SQLDatabase))
                        }
                    }
                    for table in hidden.withLock { $0 }.reversed() {
                        try await controlSQL.raw("ALTER TABLE im_v2.\(unsafeRaw: table + "_current_hidden") RENAME TO \(unsafeRaw: table)").run()
                    }
                    hidden.withLock { $0 = [] }
                    try await host.shutdown()
                } catch {
                    await barrier.release(); _ = await held.result
                    for table in hidden.withLock { $0 }.reversed() {
                        try? await controlSQL.raw("ALTER TABLE im_v2.\(unsafeRaw: table + "_current_hidden") RENAME TO \(unsafeRaw: table)").run()
                    }
                    try? await host.shutdown(); await directory.shutdown()
                    throw error
                }
            }
            await directory.shutdown()
        }
    }

    @Test("policy mutations publish transaction facts only after actual COMMIT and never reload after success",
          arguments: [false, true])
    func policyMutationCommittedMemoryPublication(failCommit: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, _, sql, _, _ in
            let journal = PostgresV2PolicyAuthorizationJournal(database: control)
            let scope = V2PolicyAuthorizationScope.account(senderUUID)
            let owner = PostgresV2PolicyOwner(journal: journal, scope: scope,
                snapshot: { context, change in
                    let facts = try await journal.mutationFacts(scope: scope, context: context, change: change)
                    if !failCommit {
                        let connection = try #require(context.transaction as? any SQLDatabase)
                        try await connection.raw("ALTER TABLE im_v2.public_user_profiles RENAME TO policy_commit_hidden_profiles").run()
                    }
                    return facts
                },
                apply: { context, _ in
                    let connection = try #require(context.transaction as? any SQLDatabase)
                    try await connection.raw("UPDATE im_v2.public_user_profiles SET state='suspended' WHERE user_id=\(bind: senderUUID)").run()
                    return Data([1])
                })
            let cache = V2NodePolicyStateCache()
            let initial = try await journal.readSnapshot(scope: scope)
            try await cache.install(initial)
            let hidden = Mutex(false)
            var trigger = false
            do {
                if failCommit {
                    try await sql.raw("""
                        CREATE FUNCTION im_v2.policy_commit_test_failure() RETURNS trigger LANGUAGE plpgsql AS
                        'BEGIN RAISE EXCEPTION ''policy commit test failure''; END'
                        """).run()
                    try await sql.raw("""
                        CREATE CONSTRAINT TRIGGER policy_commit_test_failure AFTER UPDATE ON im_v2.public_user_profiles
                        DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION im_v2.policy_commit_test_failure()
                        """).run()
                    trigger = true
                    // The deferred trigger runs at COMMIT, after the state
                    // callback has captured the transaction's suspended facts.
                    await #expect(throws: (any Error).self) {
                        try await owner.changeExecution(operationKey: "commit-memory", fingerprint: Data(repeating: 3, count: 32), commandJSON: "{}")
                    }
                    #expect(await owner.pressure().roots == 0)
                    #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.public_user_profiles WHERE user_id=\(bind: senderUUID) AND state='active'").first(decoding: PolicyDomainCount.self)?.value == 1)
                    #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.policy_authorization_scopes WHERE scope_key=\(bind: scope.key) AND revision=\(bind: initial.version) AND pending_change_key='commit-memory'").first(decoding: PolicyDomainCount.self)?.value == 0)
                    #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.policy_authorization_outbox WHERE operation_key='commit-memory'").first(decoding: PolicyDomainCount.self)?.value == 0)
                    // A failed COMMIT rolls back the whole operation;
                    // it leaves no prepared change or authorization seal.
                    #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.policy_authorization_changes WHERE operation_key='commit-memory'").first(decoding: PolicyDomainCount.self)?.value == 0)
                    #expect(try await cache.cachedSnapshots(scopes: [scope])?.first == initial)
                    try await sql.raw("DROP TRIGGER policy_commit_test_failure ON im_v2.public_user_profiles").run()
                    try await sql.raw("DROP FUNCTION im_v2.policy_commit_test_failure()").run()
                    trigger = false
                }
                let execution = try await owner.changeExecution(operationKey: "commit-memory", fingerprint: Data(repeating: 3, count: 32), commandJSON: "{}")
                hidden.withLock { $0 = !failCommit }
                #expect(execution.receipt == Data([1]) && !execution.replayed)
                #expect(execution.state?.version == initial.version + 1)
                if failCommit {
                    try await sql.raw("ALTER TABLE im_v2.public_user_profiles RENAME TO policy_commit_hidden_profiles").run()
                    hidden.withLock { $0 = true }
                }
                let committed = try #require(execution.state)
                try await cache.install(committed)
                let updated = try #require(try await cache.cachedSnapshots(scopes: [scope])?.first)
                guard case .account(let facts) = updated.facts else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
                #expect(!facts.isActive && updated.version == initial.version + 1)
                #expect(updated == committed)
                // Facts remain hidden: replay must preserve the current
                // committed memory state without another cold SQL read.
                let replay = try await owner.changeExecution(operationKey: "commit-memory",
                    fingerprint: Data(repeating: 3, count: 32), commandJSON: "{}")
                #expect(replay.replayed && replay.receipt == execution.receipt && replay.state == nil)
                #expect(try await cache.cachedSnapshots(scopes: [scope])?.first == updated)
                try await sql.raw("ALTER TABLE im_v2.policy_commit_hidden_profiles RENAME TO public_user_profiles").run()
                hidden.withLock { $0 = false }
                await owner.shutdown(); await cache.shutdown()
            } catch {
                if hidden.withLock({ $0 }) { try? await sql.raw("ALTER TABLE im_v2.policy_commit_hidden_profiles RENAME TO public_user_profiles").run() }
                if trigger {
                    try? await sql.raw("DROP TRIGGER policy_commit_test_failure ON im_v2.public_user_profiles").run()
                    try? await sql.raw("DROP FUNCTION im_v2.policy_commit_test_failure()").run()
                }
                await owner.shutdown(); await cache.shutdown()
                throw error
            }
        }
    }

    private func policyDomainCommand(kind: String, database: any Database) async throws -> V2DurablePolicyMutation {
        let recipient = UserID(uuid: memberTwoUUID)
        switch kind {
        case "block", "remove":
            let store = V2PostgresSocialRelationshipPersistence(database: database, projectionDelivery: SuccessfulProjectionDelivery())
            return .social(try await store.freezeSocialFixture(actorUserID: senderID, targetUserID: recipient,
                operation: kind == "block" ? .userBlock(.init(uuid: UUID())) : .relationship(.init(uuid: UUID())),
                action: kind == "block" ? .userBlock(.block) : .relationship(.remove), now: Date()))
        case "stranger":
            let store = V2PostgresAccountPreferencePersistence(database: database,
                projectionDelivery: SuccessfulProjectionDelivery())
            return .strangerPreference(try await store.freezePreferenceFixture(owner: recipient,
                operation: .strangerMessagePreference(.init(uuid: UUID())), value: .strangerMessage(.deny), now: Date()))
        default:
            return .disable(.init(command: try .init(userID: recipient, operationID: UUID(), reason: .policyEnforcement),
                operatorPrincipal: "policy-domain-test"))
        }
    }

    private func policyDomainEffect(kind: String, sql: any SQLDatabase) async throws -> Int64 {
        let query: SQLQueryString
        switch kind {
        case "block": query = "SELECT count(*)::bigint AS value FROM im_v2.user_blocks WHERE blocker_user_id=\(bind: senderUUID) AND blocked_user_id=\(bind: memberTwoUUID)"
        case "remove": query = "SELECT (1-count(*))::bigint AS value FROM im_v2.user_relationships"
        case "stranger": query = "SELECT count(*)::bigint AS value FROM im_v2.user_stranger_message_preferences WHERE user_id=\(bind: memberTwoUUID) AND NOT allows_stranger_messages"
        default: query = "SELECT count(*)::bigint AS value FROM im_v2.account_disables WHERE user_id=\(bind: memberTwoUUID)"
        }
        return try #require(try await sql.raw(query).first(decoding: PolicyDomainCount.self)).value
    }
}

private struct PolicyDomainCount: Decodable { let value: Int64 }
private actor CurrentPolicyMessageBarrier {
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
private actor PolicyFriendMutationProgress {
    private(set) var done = false
    func completed() { done = true }
}
private func policyFriendObserve(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !(try await predicate()) {
        guard ContinuousClock.now < deadline else { throw V2PolicyAuthorizationLifecycleError.notDrained }
        await Task.yield()
    }
}
