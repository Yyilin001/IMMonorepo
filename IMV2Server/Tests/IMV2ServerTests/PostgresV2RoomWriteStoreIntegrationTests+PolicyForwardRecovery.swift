import Foundation
import FluentKit
import IMV2ActorContracts
import IMV2Core
@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("accepted imports release policy before finalization and recover without owners or strategy tables",
          arguments: ["direct", "group"], [false, true])
    func policyForwardAcceptedRecovery(kind: String, corrupt: Bool) async throws {
        let group = kind == "group"
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, controlSQL, ownerSQL, groupRoom in
            let now = Date(), profile = try forwardImportTestProfile(), limits = try V2MessageCommandLimits(maxUTF8Bytes: 64)
            for sql in [controlSQL, ownerSQL] {
                try await sql.raw("UPDATE im_v2.shard_admission_pools SET valid_until=clock_timestamp()+interval '10 minutes'").run()
            }
            let room: RoomID
            if group { room = groupRoom }
            else {
                let opened = try await V2DirectRoomOperationTestFixture(store: PostgresV2DirectMessagingStore(database: owner,
                    identityReader: PostgresV2DirectRoomIdentityReader(database: control), projectionDelivery: SuccessfulProjectionDelivery()),
                    capacityProfile: profile, roomShardID: "room-b", now: { now }).openedIdentity(actorUserID: senderID,
                        operationID: .init(uuid: UUID()), targetUserID: .init(uuid: memberTwoUUID),
                        firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
                room = opened.roomID
            }
            let exports = try await policyFactoryExports(database: control, target: room, profile: profile, now: now)
            let legacy = V2DirectAuthorizationCoordinator(controlDatabase: control, ownerDatabases: [:])
            let owners = PostgresV2PolicyOwnerDirectory(journal: .init(database: control),
                dispatcher: .init(database: control, projectionDelivery: SuccessfulProjectionDelivery(), legacyAuthorization: legacy))
            let policies = V2RoomPolicyAuthorizationService(roomDatabase: owner,
                policyOwners: owners, endpoint: "room-b", maximumRooms: 1)
            let write = PostgresV2RoomWriteStore(database: owner,
                strangerMessagePolicy: try .init(maximumMessagesPerWindow: 10, window: 86_400), contentReviewMode: .disabled)
                .usingControlDatabase(control).usingPolicyAuthorizations(policies)
            do {
                try await withRoomActivation(database: owner, roomID: room, shardID: "room-b") { token in
                    try await policyRecoveryRound(write: write, token: token, export: exports[0], owners: owners,
                        legacy: legacy, control: control, controlSQL: controlSQL, owner: owner, ownerSQL: ownerSQL,
                        profile: profile, limits: limits, corrupt: corrupt)
                }
                try await policies.shutdown(); await owners.shutdown()
            } catch { try? await policies.shutdown(); await owners.shutdown(); throw error }
        }
    }

    private func policyRecoveryRound(write: PostgresV2RoomWriteStore, token: V2RoomActivationToken, export: V2ForwardExport,
        owners: PostgresV2PolicyOwnerDirectory, legacy: V2DirectAuthorizationCoordinator,
        control: any Database, controlSQL: any SQLDatabase, owner: any Database, ownerSQL: any SQLDatabase,
        profile: V2CapacityProfile, limits: V2MessageCommandLimits, corrupt: Bool) async throws {
        try await ownerSQL.raw("""
            CREATE FUNCTION im_v2.test_hold_policy_forward_finalization() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
                IF NEW.state='completed' THEN
                    PERFORM pg_advisory_xact_lock(965551);
                    RAISE EXCEPTION 'injected finalization failure';
                END IF;
                RETURN NEW;
            END $$
            """).run()
        try await ownerSQL.raw("""
            CREATE TRIGGER test_hold_policy_forward_finalization BEFORE UPDATE ON im_v2.message_forward_inbox
            FOR EACH ROW EXECUTE FUNCTION im_v2.test_hold_policy_forward_finalization()
            """).run()
        let held = PolicyRecoveryHold(), finished = PolicyRecoveryFinished()
        let holding = Task {
            try await owner.transaction { transaction in
                let sql = try #require(transaction as? any SQLDatabase)
                try await sql.raw("SELECT pg_advisory_xact_lock(965551)").run()
                let pid = try #require(try await sql.raw("SELECT pg_backend_pid()::bigint AS value").first(decoding: PolicyRecoveryCount.self)).value
                await held.wait(pid: pid)
            }
        }
        var importing: Task<V2ForwardImportOutcome, any Error>?
        var mutation: Task<V2AccountDisableOutcome, any Error>?
        do {
            try await policyRecoveryObserve { await held.pid != nil }
            let pid = try #require(await held.pid)
            let task = Task {
                let now = Date()
                return try await write.importForwardExport(export, activationToken: token, capacityProfile: profile,
                    limits: limits, identifiers: V2AcceptanceIDFactory().make(at: now), now: now)
            }; importing = task
            try await policyRecoveryObserve {
                try await ownerSQL.raw("SELECT count(*)::bigint AS value FROM pg_stat_activity WHERE \(bind: pid)::integer=ANY(pg_blocking_pids(pid))").first(decoding: PolicyRecoveryCount.self)?.value ?? 0 > 0
            }
            #expect(try await PostgresV2ForwardInboxStore(database: owner).status(exportID: export.intent.exportID) == .pending(.finalization))
            let disable = try V2PostgresAccountDisableService(database: control, operatorPrincipal: "operator:test",
                authorizationCoordinator: legacy).usingPolicyOwners(owners)
            let changing = Task {
                let result = try await disable.disable(.init(userID: senderID, operationID: UUID(), reason: .policyEnforcement))
                await finished.mark(); return result
            }; mutation = changing
            // The accepting execution must have settled even though finalization
            // is provably blocked in an actual SQL transaction.
            try await policyRecoveryObserve { await finished.value }
            _ = try await changing.value
            #expect(try await ownerSQL.raw("SELECT count(*)::bigint AS value FROM im_v2.room_policy_authorization_leases WHERE NOT revoked").first(decoding: PolicyRecoveryCount.self)?.value == 0)
            await owners.shutdown()
            await held.release(); try await holding.value
            await #expect(throws: V2RoomTransactionOutcomeUnknown.self) { try await task.value }
            try await ownerSQL.raw("DROP TRIGGER test_hold_policy_forward_finalization ON im_v2.message_forward_inbox").run()
            try await ownerSQL.raw("DROP FUNCTION im_v2.test_hold_policy_forward_finalization()").run()
            let projectionCount = try await count("im_v2.user_state_event_outbox", on: ownerSQL)
            let holders = try await count("im_v2.policy_authorization_holders", on: controlSQL)
            let hidden = ["public_user_profiles", "special_accounts", "account_disables", "user_blocks",
                "user_relationships", "user_stranger_message_preferences"]
            for sql in [controlSQL, ownerSQL] {
                for table in hidden { try await sql.raw("ALTER TABLE im_v2.\(unsafeRaw: table) RENAME TO \(unsafeRaw: table + "_recovery_hidden")").run() }
            }
            if corrupt {
                // Explicit disposable-database corruption injection. Recovery
                // must report a missing immutable witness, never issue a send.
                try await ownerSQL.raw("DROP TRIGGER message_send_completions_immutable ON im_v2.message_send_completions").run()
                try await ownerSQL.raw("DELETE FROM im_v2.message_send_completions WHERE room_id=\(bind: export.intent.targetRoomID)").run()
                await #expect(throws: V2ForwardInboxError.corruptPersistenceState) {
                    try await owner.transaction { transaction in
                        try await V2RoomWriteForwardInboxPath(activationScope: .init(tokens: [token])).preflight(export: export, transaction: transaction)
                    }
                }
                #expect(try await PostgresV2ForwardInboxStore(database: owner).status(exportID: export.intent.exportID) == .pending(.finalization))
            } else {
                let now = Date()
                let recovered = try await write.importForwardExport(export, activationToken: token, capacityProfile: profile,
                    limits: .init(maxUTF8Bytes: 1), identifiers: V2AcceptanceIDFactory().make(at: now), now: now)
                guard case .accepted = recovered else { throw V2ForwardInboxError.corruptPersistenceState }
                #expect(try await write.importForwardExport(export, activationToken: token, capacityProfile: profile,
                    limits: .init(maxUTF8Bytes: 1), identifiers: V2AcceptanceIDFactory().make(at: now), now: now) == recovered)
            }
            #expect(try await count("im_v2.messages", on: ownerSQL) == 1)
            #expect(try await count("im_v2.user_state_event_outbox", on: ownerSQL) == projectionCount)
            #expect(try await count("im_v2.policy_authorization_holders", on: controlSQL) == holders)
        } catch {
            await held.release(); _ = await holding.result; _ = await importing?.result; _ = await mutation?.result
            throw error
        }
    }

    private func policyRecoveryObserve(_ check: @Sendable () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while .now < deadline { if try await check() { return }; await Task.yield() }
        throw V2PolicyAuthorizationLifecycleError.notDrained
    }
}
private struct PolicyRecoveryCount: Decodable { let value: Int64 }
private actor PolicyRecoveryHold {
    private(set) var pid: Int64?
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait(pid: Int64) async { self.pid = pid; if !released { await withCheckedContinuation { waiter = $0 } } }
    func release() { released = true; waiter?.resume(); waiter = nil }
}
private actor PolicyRecoveryFinished {
    private(set) var value = false
    func mark() { value = true }
}
