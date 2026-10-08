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
    @Test("cold current-state ownership preserves renewal, takeover and epoch exhaustion rules",
          arguments: ["new", "same", "takeover", "foreign", "max-current", "max-expired"])
    func currentPolicyColdClaimAuthority(mode: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, _, sql, _, _ in
            let journal = PostgresV2PolicyAuthorizationJournal(database: control, roomDrainRequired: false)
            let scope = V2PolicyAuthorizationScope.account(senderUUID), ownerID = UUID()
            let previousID = (mode == "takeover" || mode == "foreign") ? UUID() : ownerID
            if mode != "new" {
                _ = try await journal.acquireOwner(scope: scope, ownerID: previousID, durationSeconds: 30)
                if mode.hasPrefix("max-") {
                    try await sql.raw("UPDATE im_v2.policy_authorization_scopes SET owner_epoch=\(bind: Int64.max) WHERE scope_key=\(bind: scope.key)").run()
                }
                if mode == "takeover" || mode == "max-expired" {
                    try await sql.raw("UPDATE im_v2.policy_authorization_scopes SET owner_valid_until=clock_timestamp()-interval '1 second' WHERE scope_key=\(bind: scope.key)").run()
                }
            }
            if mode == "foreign" || mode == "max-expired" {
                await #expect(throws: mode == "foreign" ? V2PolicyAuthorizationLifecycleError.ownerChanged : .invalidRequest) {
                    try await journal.acquireOwnerState(scope: scope, ownerID: ownerID, durationSeconds: 30)
                }
                #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.policy_authorization_scopes WHERE scope_key=\(bind: scope.key) AND owner_id=\(bind: previousID)").first(decoding: PolicyDomainCount.self)?.value == 1)
            } else {
                let state = try await journal.acquireOwnerState(scope: scope, ownerID: ownerID, durationSeconds: 30)
                let epoch: Int64 = mode == "max-current" ? .max : (mode == "takeover" ? 2 : 1)
                #expect(state.owner.ownerID == ownerID && state.owner.epoch == epoch && state.deadline > .now)
                guard case .account(let facts) = state.facts else {
                    throw V2PolicyAuthorizationLifecycleError.corruptPersistence
                }
                #expect(facts.isActive && facts.userID == senderUUID)
            }
        }
    }

    @Test("cold conflict claims use a new expiry after the actual scope row wait",
          arguments: [false, true])
    func currentPolicyColdClaimScopeWait(foreign: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, _, sql, _, _ in
            let journal = PostgresV2PolicyAuthorizationJournal(database: control, roomDrainRequired: false)
            let scope = V2PolicyAuthorizationScope.account(senderUUID), ownerID = UUID()
            let previous = try await journal.acquireOwner(scope: scope,
                ownerID: foreign ? UUID() : ownerID, durationSeconds: 30)
            let gate = PolicyStateSQLGate()
            let blocker = Task {
                try await control.transaction { transaction in
                    let sql = try #require(transaction as? any SQLDatabase)
                    try await sql.raw("UPDATE im_v2.policy_authorization_scopes SET owner_valid_until=clock_timestamp()+interval '0.2 seconds' WHERE scope_key=\(bind: scope.key)").run()
                    let pid = try #require(try await sql.raw("SELECT pg_backend_pid()::bigint AS value").first(decoding: PolicyDomainCount.self)).value
                    await gate.hold(pid: pid)
                }
            }
            var loading: Task<V2PolicyOwnerState, any Error>?
            do {
                try await policyFriendObserve { await gate.pid != nil }
                let pid = try #require(await gate.pid)
                let task = Task { try await journal.acquireOwnerState(scope: scope, ownerID: ownerID, durationSeconds: 1) }
                loading = task
                try await policyFriendObserve {
                    try await sql.raw("SELECT count(*)::bigint AS value FROM pg_stat_activity WHERE \(bind: pid)::integer=ANY(pg_blocking_pids(pid))").first(decoding: PolicyDomainCount.self)?.value ?? 0 == 1
                }
                // Longer than both the previous lease and the INSERT proposal.
                // Reusing EXCLUDED.owner_valid_until would return expired state.
                try await Task.sleep(for: .milliseconds(1_100))
                await gate.release()
                try await blocker.value
                let state = try await task.value
                #expect(state.owner.ownerID == ownerID && state.owner.epoch == previous.epoch + 1)
                #expect(state.owner.revision == previous.revision && state.deadline > .now)
            } catch {
                await gate.release()
                _ = await blocker.result
                _ = await loading?.result
                throw error
            }
        }
    }

    @Test("a first cold load stays cached while a no-effect policy lookup is suspended",
          arguments: [false, true])
    func currentPolicyColdLoadDuringLookupRetainsMemory(replay: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, _, sql, _, _ in
            let coldResult = PolicyColdResultGate()
            let journal = PostgresV2PolicyAuthorizationJournal(database:
                try PolicyColdResultDatabase(underlying: control, gate: coldResult), roomDrainRequired: false)
            let scope = V2PolicyAuthorizationScope.account(senderUUID), ownerID = UUID()
            let fingerprint = Data(repeating: 8, count: 32)
            if replay {
                _ = try await journal.changeCurrentPolicy(scope: scope, ownerID: ownerID, durationSeconds: 30,
                    operationKey: "cold-lookup-replay", fingerprint: fingerprint, commandJSON: "{}",
                    apply: { _, _ in Data([1]) })
            }
            let owner = PostgresV2PolicyOwner(journal: journal, scope: scope, ownerID: ownerID,
                revoke: { _ in throw V2PolicyAuthorizationLifecycleError.invalidTarget },
                apply: { _, _ in
                    Issue.record("A replay or empty recovery must not apply policy effects")
                    throw V2PolicyAuthorizationLifecycleError.invalidRequest
                })
            let gate = PolicyStateSQLGate()
            let held = Task {
                try await control.transaction { transaction in
                    let sql = try #require(transaction as? any SQLDatabase)
                    try await sql.raw("LOCK TABLE im_v2.policy_authorization_changes IN ACCESS EXCLUSIVE MODE").run()
                    let pid = try #require(try await sql.raw("SELECT pg_backend_pid()::bigint AS value").first(decoding: PolicyDomainCount.self)).value
                    await gate.hold(pid: pid)
                }
            }
            var lookup: Task<Void, any Error>?
            var hidden = false
            let loading = Task { try await owner.registrationState() }
            do {
                try await policyFriendObserve { await gate.pid != nil }
                try await policyFriendObserve { coldResult.captured != nil }
                let pid = try #require(await gate.pid)
                lookup = Task {
                    if replay {
                        let result = try await owner.changeExecution(operationKey: "cold-lookup-replay",
                            fingerprint: fingerprint, commandJSON: "{}")
                        #expect(result.replayed && result.receipt == Data([1]))
                    } else { try await owner.recover() }
                }
                try await policyFriendObserve {
                    try await sql.raw("SELECT count(*)::bigint AS value FROM pg_stat_activity WHERE \(bind: pid)::integer=ANY(pg_blocking_pids(pid))").first(decoding: PolicyDomainCount.self)?.value ?? 0 == 1
                }
                #expect(await owner.pressure().roots == 2)
                coldResult.release()
                let loaded = try await loading.value
                #expect(await owner.pressure().roots == 1)
                let cachedDuringLookup = try await owner.cachedRegistrationState()
                #expect(cachedDuringLookup?.owner == loaded.owner && cachedDuringLookup?.facts == loaded.facts)
                try await sql.raw("ALTER TABLE im_v2.public_user_profiles RENAME TO lookup_cold_hidden_profiles").run()
                hidden = true
                await gate.release()
                try await held.value
                try await lookup?.value
                let cachedAfterLookup = try await owner.cachedRegistrationState()
                #expect(cachedAfterLookup?.owner == loaded.owner && cachedAfterLookup?.facts == loaded.facts)
                let reused = try await owner.registrationState()
                #expect(reused.owner == loaded.owner && reused.facts == loaded.facts && reused.deadline == loaded.deadline)
                #expect(await owner.pressure().roots == 0)
                try await sql.raw("ALTER TABLE im_v2.lookup_cold_hidden_profiles RENAME TO public_user_profiles").run()
                hidden = false
                await owner.shutdown()
            } catch {
                coldResult.release()
                await gate.release()
                _ = await loading.result
                _ = await held.result
                _ = await lookup?.result
                if hidden { try? await sql.raw("ALTER TABLE im_v2.lookup_cold_hidden_profiles RENAME TO public_user_profiles").run() }
                await owner.shutdown()
                throw error
            }
        }
    }

    @Test("a cold result captured before mutation cannot return old facts after the mutation commits",
          arguments: [false, true])
    func currentPolicyMutationSupersedesCapturedColdResult(cancelCaller: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, _, sql, _, _ in
            let gate = PolicyColdResultGate()
            let database = try PolicyColdResultDatabase(underlying: control, gate: gate)
            let journal = PostgresV2PolicyAuthorizationJournal(database: database, roomDrainRequired: false)
            let scope = V2PolicyAuthorizationScope.account(senderUUID)
            let owner = PostgresV2PolicyOwner(journal: journal, scope: scope,
                snapshot: { context, change in
                    try await journal.mutationFacts(scope: scope, context: context, change: change)
                }, revoke: { _ in throw V2PolicyAuthorizationLifecycleError.invalidTarget },
                apply: { context, _ in
                    let sql = try #require(context.transaction as? any SQLDatabase)
                    try await sql.raw("UPDATE im_v2.public_user_profiles SET state='suspended' WHERE user_id=\(bind: senderUUID)").run()
                    return Data([1])
                })
            let loading = Task { try await owner.registrationState() }
            var hidden = false
            do {
                try await policyFriendObserve { gate.captured != nil }
                let old = try #require(gate.captured)
                guard case .account(let oldFacts) = old.facts else {
                    throw V2PolicyAuthorizationLifecycleError.corruptPersistence
                }
                #expect(oldFacts.isActive)
                #expect(await owner.pressure().roots == 1)
                // The gate delays only delivery of a completed real database
                // transaction. NOWAIT proves its scope lock was released.
                try await control.transaction { transaction in
                    let sql = try #require(transaction as? any SQLDatabase)
                    _ = try await sql.raw("SELECT scope_key FROM im_v2.policy_authorization_scopes WHERE scope_key=\(bind: scope.key) FOR UPDATE NOWAIT").all()
                }
                if cancelCaller { loading.cancel() }
                let execution = try await owner.changeExecution(operationKey: "supersede-captured-cold",
                    fingerprint: Data(repeating: 7, count: 32), commandJSON: "{}")
                let published = try #require(execution.state)
                guard case .account(let newFacts) = published.facts else {
                    throw V2PolicyAuthorizationLifecycleError.corruptPersistence
                }
                #expect(!newFacts.isActive && published.owner.revision == old.owner.revision + 1)
                #expect(await owner.pressure().roots == 1)
                try await sql.raw("ALTER TABLE im_v2.public_user_profiles RENAME TO captured_cold_hidden_profiles").run()
                hidden = true
                let immediate = try await owner.registrationState()
                #expect(immediate.owner == published.owner && immediate.facts == published.facts)
                gate.release()
                let resolved = try await loading.value
                #expect(resolved.owner == published.owner && resolved.facts == published.facts
                    && resolved.deadline == published.deadline)
                let retained = try await owner.registrationState()
                #expect(retained.owner == published.owner && retained.facts == published.facts)
                #expect(await owner.pressure().roots == 0)
                try await sql.raw("ALTER TABLE im_v2.captured_cold_hidden_profiles RENAME TO public_user_profiles").run()
                hidden = false
                await owner.shutdown()
            } catch {
                gate.release()
                _ = await loading.result
                if hidden { try? await sql.raw("ALTER TABLE im_v2.captured_cold_hidden_profiles RENAME TO public_user_profiles").run() }
                await owner.shutdown()
                throw error
            }
        }
    }

    @Test("a superseded cold load cannot grant state after mutation failure or shutdown",
          arguments: [false, true])
    func currentPolicySupersededColdLoadWithoutCurrentState(close: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, _, sql, _, _ in
            let admission = V2DatabaseWorkAdmissionController(policy: .init(maximumForegroundWriteInFlight: 1,
                maximumInteractiveReadInFlight: 1, maximumSyncInFlight: 1,
                maximumForegroundWriteQueued: 1, maximumInteractiveReadQueued: 1,
                maximumSyncQueued: 2, timeout: .seconds(10)))
            let owner = PostgresV2PolicyOwner(journal: .init(database: control,
                stateReadAdmission: admission, roomDrainRequired: false), scope: .account(senderUUID),
                revoke: { _ in throw V2PolicyAuthorizationLifecycleError.invalidTarget },
                apply: { context, _ in
                    let sql = try #require(context.transaction as? any SQLDatabase)
                    try await sql.raw("UPDATE im_v2.public_user_profiles SET state='suspended' WHERE user_id=\(bind: senderUUID)").run()
                    throw V2PolicyAuthorizationLifecycleError.invalidRequest
                })
            guard case .admitted = await admission.acquire(.sync, callerDeadline: .now + .seconds(10)) else {
                throw V2PolicyAuthorizationLifecycleError.busy
            }
            var admissionHeld = true
            var closing: Task<Void, Never>?
            let loading = Task { try await owner.registrationState() }
            do {
                try await policyFriendObserve { await admission.snapshot().value(for: .sync).queued == 1 }
                await #expect(throws: V2PolicyAuthorizationLifecycleError.invalidRequest) {
                    try await owner.changeExecution(operationKey: "failed-supersede-cold",
                        fingerprint: Data(repeating: 6, count: 32), commandJSON: "{}")
                }
                #expect(try await owner.cachedRegistrationState() == nil)
                #expect(await owner.pressure().roots == 1)
                if close {
                    closing = Task { await owner.shutdown() }
                    try await policyFriendObserve { await owner.pressure().closed }
                    #expect(await owner.pressure().roots == 1)
                    #expect(await admission.snapshot().value(for: .sync).queued == 1)
                }
                await admission.release(.sync)
                admissionHeld = false
                await #expect(throws: close ? V2PolicyAuthorizationLifecycleError.closed : .busy) {
                    try await loading.value
                }
                await closing?.value
                #expect(await owner.pressure().roots == 0)
                let settled = await admission.snapshot().value(for: .sync)
                #expect(settled.inFlight == 0 && settled.queued == 0)
                #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.public_user_profiles WHERE user_id=\(bind: senderUUID) AND state='active'").first(decoding: PolicyDomainCount.self)?.value == 1)
                if !close {
                    let reloaded = try await owner.registrationState()
                    guard case .account(let facts) = reloaded.facts else {
                        throw V2PolicyAuthorizationLifecycleError.corruptPersistence
                    }
                    #expect(facts.isActive)
                }
                await owner.shutdown()
            } catch {
                if admissionHeld { await admission.release(.sync) }
                _ = await loading.result
                await closing?.value
                await owner.shutdown()
                throw error
            }
        }
    }

    @Test("a superseded cold load returns the committed current state even when its old fact read fails",
          arguments: [false, true])
    func currentPolicyMutationSupersedesColdLoad(hideFacts: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, _, sql, _, _ in
            let admission = V2DatabaseWorkAdmissionController(policy: .init(maximumForegroundWriteInFlight: 1,
                maximumInteractiveReadInFlight: 1, maximumSyncInFlight: 1,
                maximumForegroundWriteQueued: 1, maximumInteractiveReadQueued: 1,
                maximumSyncQueued: 2, timeout: .seconds(10)))
            let metrics = V2SendOperationBatchMetrics()
            let journal = PostgresV2PolicyAuthorizationJournal(database: control,
                stateReadAdmission: admission, stateMetrics: metrics, roomDrainRequired: false)
            let scope = V2PolicyAuthorizationScope.account(senderUUID)
            let owner = PostgresV2PolicyOwner(journal: journal, scope: scope,
                snapshot: { context, change in
                    try await journal.mutationFacts(scope: scope, context: context, change: change)
                }, revoke: { _ in throw V2PolicyAuthorizationLifecycleError.invalidTarget },
                apply: { context, _ in
                    let sql = try #require(context.transaction as? any SQLDatabase)
                    try await sql.raw("UPDATE im_v2.public_user_profiles SET state='suspended' WHERE user_id=\(bind: senderUUID)").run()
                    return Data([1])
                })
            guard case .admitted = await admission.acquire(.sync, callerDeadline: .now + .seconds(10)) else {
                throw V2PolicyAuthorizationLifecycleError.busy
            }
            var admissionHeld = true, hidden = false
            let loading = Task { try await owner.registrationState() }
            do {
                try await policyFriendObserve { await admission.snapshot().value(for: .sync).queued == 1 }
                #expect(await owner.pressure().roots == 1)
                #expect(metrics.sendOperationBatchMetricsSnapshot().stages[.policyOwnerStateTransaction]?.count ?? 0 == 0)
                let execution = try await owner.changeExecution(operationKey: "supersede-cold",
                    fingerprint: Data(repeating: 5, count: 32), commandJSON: "{}")
                let published = try #require(execution.state)
                guard case .account(let facts) = published.facts else {
                    throw V2PolicyAuthorizationLifecycleError.corruptPersistence
                }
                #expect(!facts.isActive)
                if hideFacts {
                    try await sql.raw("ALTER TABLE im_v2.public_user_profiles RENAME TO superseded_cold_hidden_profiles").run()
                    hidden = true
                }
                let immediate = try await owner.registrationState()
                #expect(immediate.owner == published.owner && immediate.facts == published.facts)
                // The obsolete load still owns its actual admission wait. A
                // current memory reader does not join that old generation.
                #expect(await admission.snapshot().value(for: .sync).queued == 1)
                await admission.release(.sync)
                admissionHeld = false
                let resolved = try await loading.value
                #expect(resolved.owner == published.owner && resolved.facts == published.facts
                    && resolved.deadline == published.deadline)
                let retained = try await owner.registrationState()
                #expect(retained.owner == published.owner && retained.facts == published.facts)
                #expect(await owner.pressure().roots == 0)
                let settled = await admission.snapshot().value(for: .sync)
                #expect(settled.inFlight == 0 && settled.queued == 0)
                if hidden {
                    try await sql.raw("ALTER TABLE im_v2.superseded_cold_hidden_profiles RENAME TO public_user_profiles").run()
                    hidden = false
                }
                await owner.shutdown()
            } catch {
                if admissionHeld { await admission.release(.sync) }
                _ = await loading.result
                if hidden { try? await sql.raw("ALTER TABLE im_v2.superseded_cold_hidden_profiles RENAME TO public_user_profiles").run() }
                await owner.shutdown()
                throw error
            }
        }
    }

    @Test("current policy recovery lookup preserves committed memory when empty or failed", arguments: [false, true])
    func currentPolicyEmptyRecoveryPreservesMemory(failLookup: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, _, sql, _, _ in
            let metrics = V2SendOperationBatchMetrics()
            let owner = PostgresV2PolicyOwner(journal: .init(database: control,
                stateMetrics: metrics, roomDrainRequired: false), scope: .account(senderUUID),
                revoke: { _ in throw V2PolicyAuthorizationLifecycleError.invalidTarget },
                apply: { _, _ in
                    Issue.record("An empty or failed recovery lookup must not apply policy effects")
                    throw V2PolicyAuthorizationLifecycleError.invalidRequest
                })
            let gate = PolicyStateSQLGate()
            var held: Task<Void, any Error>?
            var recovering: Task<Void, any Error>?
            var renamed = false
            do {
                let original = try await owner.registrationState()
                let factsBefore = try #require(metrics.sendOperationBatchMetricsSnapshot().stages[.policyOwnerStateFacts]).count
                if failLookup {
                    try await sql.raw("ALTER TABLE im_v2.policy_authorization_changes RENAME TO policy_recovery_lookup_hidden").run()
                    renamed = true
                    do { try await owner.recover(); Issue.record("Missing journal table must fail lookup") }
                    catch { /* Read failure does not imply uncertain mutation effects. */ }
                } else {
                    held = Task {
                        try await control.transaction { transaction in
                            let lockedSQL = try #require(transaction as? any SQLDatabase)
                            try await lockedSQL.raw("LOCK TABLE im_v2.policy_authorization_changes IN ACCESS EXCLUSIVE MODE").run()
                            let pid = try #require(try await lockedSQL.raw("SELECT pg_backend_pid()::bigint AS value")
                                .first(decoding: PolicyDomainCount.self)).value
                            await gate.hold(pid: pid)
                        }
                    }
                    try await policyFriendObserve { await gate.pid != nil }
                    recovering = Task { try await owner.recover() }
                    let pid = try #require(await gate.pid)
                    try await policyFriendObserve {
                        try await sql.raw("SELECT count(*)::bigint AS value FROM pg_stat_activity WHERE \(bind: pid)::integer=ANY(pg_blocking_pids(pid))")
                            .first(decoding: PolicyDomainCount.self)?.value ?? 0 > 0
                    }
                    #expect(await owner.pressure().roots == 1)
                    let during = try await owner.cachedRegistrationState()
                    #expect(during?.owner.revision == original.owner.revision)
                    #expect(during?.facts == original.facts)
                    await gate.release(); try await held!.value; try await recovering!.value
                }
                let after = try await owner.cachedRegistrationState()
                #expect(after?.owner.revision == original.owner.revision)
                #expect(after?.facts == original.facts)
                #expect(metrics.sendOperationBatchMetricsSnapshot().stages[.policyOwnerStateFacts]?.count == factsBefore)
                #expect(await owner.pressure().roots == 0)
                if renamed {
                    try await sql.raw("ALTER TABLE im_v2.policy_recovery_lookup_hidden RENAME TO policy_authorization_changes").run()
                    renamed = false
                }
                await owner.shutdown()
            } catch {
                await gate.release()
                if let held { _ = await held.result }
                if let recovering { _ = await recovering.result }
                if renamed { try? await sql.raw("ALTER TABLE im_v2.policy_recovery_lookup_hidden RENAME TO policy_authorization_changes").run() }
                await owner.shutdown(); throw error
            }
        }
    }

    @Test("current policy recovery still clears memory after discovering a real pending legacy change")
    func currentPolicyPendingRecoverySealsMemory() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, _, _, _, _ in
            let journal = PostgresV2PolicyAuthorizationJournal(database: control, roomDrainRequired: false)
            let owner = PostgresV2PolicyOwner(journal: journal, scope: .account(senderUUID),
                revoke: { _ in throw V2PolicyAuthorizationLifecycleError.invalidTarget },
                apply: { _, _ in
                    Issue.record("Current policy must not silently adopt a pending legacy command")
                    throw V2PolicyAuthorizationLifecycleError.invalidRequest
                })
            do {
                let original = try await owner.registrationState()
                let legacy = PostgresV2PolicyAuthorizationJournal(database: control)
                _ = try await legacy.beginChange(owner: original.owner, operationKey: "pending-recovery-seal",
                    fingerprint: Data(repeating: 1, count: 32), commandJSON: "{}")
                await #expect(throws: V2PolicyAuthorizationLifecycleError.busy) { try await owner.recover() }
                #expect(try await owner.cachedRegistrationState() == nil)
                #expect(try await journal.pendingChanges().count == 1)
                #expect(await owner.pressure().roots == 0)
                await owner.shutdown()
            } catch { await owner.shutdown(); throw error }
        }
    }

    @Test("account cold state locks profile before special rows and reads committed facts after either row wait",
          arguments: ["profile", "special"])
    func accountPolicyColdRowLocksPreserveCommittedFacts(rowKind: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, _, sql, _, _ in
            if rowKind == "special" {
                try await sql.raw("""
                    INSERT INTO im_v2.special_accounts
                        (account_user_id,stable_key,account_kind,status,allows_customer_messages,
                         allows_service_messages,created_at,updated_at)
                    VALUES (\(bind: senderUUID),'cold_policy_support','customer_support','active',
                        true,true,clock_timestamp(),clock_timestamp())
                    """).run()
            }
            let gate = PolicyStateSQLGate()
            let holder = Task {
                try await control.transaction { transaction in
                    let lockedSQL = try #require(transaction as? any SQLDatabase)
                    if rowKind == "special" {
                        try await lockedSQL.raw("UPDATE im_v2.special_accounts SET status='paused',allows_customer_messages=false,allows_service_messages=false WHERE account_user_id=\(bind: senderUUID)").run()
                    } else {
                        try await lockedSQL.raw("UPDATE im_v2.public_user_profiles SET state='suspended' WHERE user_id=\(bind: senderUUID)").run()
                    }
                    let pid = try #require(try await lockedSQL.raw("SELECT pg_backend_pid()::bigint AS value")
                        .first(decoding: PolicyDomainCount.self)).value
                    await gate.hold(pid: pid)
                }
            }
            var loading: Task<V2PolicyOwnerState, any Error>?
            do {
                try await policyFriendObserve { await gate.pid != nil }
                let journal = PostgresV2PolicyAuthorizationJournal(database: control, roomDrainRequired: false)
                let load = Task { try await journal.acquireOwnerState(scope: .account(senderUUID),
                    ownerID: UUID(), durationSeconds: 30) }
                loading = load
                let pid = try #require(await gate.pid)
                try await policyFriendObserve {
                    try await sql.raw("SELECT count(*)::bigint AS value FROM pg_stat_activity WHERE \(bind: pid)::integer=ANY(pg_blocking_pids(pid))")
                        .first(decoding: PolicyDomainCount.self)?.value ?? 0 > 0
                }
                if rowKind == "special" {
                    // The cold reader is held by the special row. Its earlier
                    // profile lock must already prevent an unrelated writer.
                    do {
                        _ = try await sql.raw("SELECT user_id FROM im_v2.public_user_profiles WHERE user_id=\(bind: senderUUID) FOR UPDATE NOWAIT").all()
                        Issue.record("Special-row wait must retain the preceding profile lock")
                    } catch let error as PSQLError {
                        #expect(error.serverInfo?[.sqlState] == "55P03")
                    } catch let error as PostgresError {
                        guard case .server(let message) = error else { throw error }
                        #expect(message.fields[.sqlState] == "55P03")
                    }
                }
                await gate.release(); try await holder.value
                let state = try await load.value
                guard case .account(let facts) = state.facts else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
                if rowKind == "special" {
                    #expect(facts.isActive && facts.specialKind == "customer_support")
                    #expect(facts.specialStatus == "paused")
                    #expect(facts.allowsServiceMessages == false && facts.allowsCustomerMessages == false)
                } else {
                    #expect(!facts.isActive && facts.specialKind == nil)
                }
                #expect(state.deadline > .now)
            } catch {
                await gate.release(); _ = await holder.result
                if let loading { _ = await loading.result }
                throw error
            }
        }
    }

    @Test("policy Owner shutdown retains a real SQL operation until settlement")
    func policyRegisteredDemandSQLSettlement() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, _, sql, _, _ in
            let owners = PostgresV2PolicyOwnerDirectory(journal: .init(database: control, roomDrainRequired: false),
                dispatcher: .init(database: control, projectionDelivery: SuccessfulProjectionDelivery(),
                    legacyAuthorization: .init(controlDatabase: control, ownerDatabases: [:])),
                revoke: { _ in throw V2PolicyAuthorizationLifecycleError.invalidTarget })
            let gate = PolicyStateSQLGate(), settled = Mutex(false)
            let blocker = Task {
                try await control.transaction { transaction in
                    let connection = try #require(transaction as? any SQLDatabase)
                    _ = try await connection.raw("SELECT user_id FROM im_v2.public_user_profiles WHERE user_id=\(bind: senderUUID) FOR UPDATE").all()
                    let pid = try #require(try await connection.raw("SELECT pg_backend_pid()::bigint AS value").first(decoding: PolicyDomainCount.self)).value
                    await gate.hold(pid: pid)
                }
            }
            var loading: Task<[V2PolicyOwnerState], any Error>?
            do {
                try await policyFriendObserve { await gate.pid != nil }
                let load = Task { try await owners.registrationStates(scopes: [.account(senderUUID)]) }
                loading = load
                let pid = try #require(await gate.pid)
                try await policyFriendObserve {
                    try await sql.raw("SELECT count(*)::bigint AS value FROM pg_stat_activity WHERE \(bind: pid)::integer=ANY(pg_blocking_pids(pid))").first(decoding: PolicyDomainCount.self)?.value ?? 0 > 0
                }
                let closing = Task { await owners.shutdown(); settled.withLock { $0 = true } }
                try await Task.sleep(for: .milliseconds(20))
                #expect(!settled.withLock { $0 })
                await gate.release(); try await blocker.value
                _ = await load.result; await closing.value
                #expect(settled.withLock { $0 })
            } catch {
                await gate.release(); _ = await blocker.result; _ = await loading?.result
                await owners.shutdown(); throw error
            }
        }
    }

    @Test("a failed permanent-result lookup preserves committed memory without starting a policy mutation",
          arguments: [false, true])
    func policyResultLookupFailurePreservesMemory(usesCurrentState: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, _, sql, _, _ in
            let journal = PostgresV2PolicyAuthorizationJournal(database: control,
                roomDrainRequired: !usesCurrentState)
            let owner = PostgresV2PolicyOwner(journal: journal, scope: .account(senderUUID),
                revoke: { _ in
                    Issue.record("Result lookup must not start revocation")
                    throw V2PolicyAuthorizationLifecycleError.invalidTarget
                }, apply: { _, _ in
                    Issue.record("Result lookup must not apply policy facts")
                    return Data([1])
                })
            let initial = try await owner.registrationState()
            try await sql.raw("ALTER TABLE im_v2.policy_authorization_changes RENAME TO policy_lookup_hidden_changes").run()
            do {
                await #expect(throws: (any Error).self) {
                    try await owner.changeExecution(operationKey: "lookup-failure",
                        fingerprint: Data(repeating: 7, count: 32), commandJSON: "{}")
                }
                let cached = try #require(try await owner.cachedRegistrationState())
                #expect(cached.owner == initial.owner && cached.facts == initial.facts)
                #expect(cached.deadline == initial.deadline)
                #expect(await owner.pressure().roots == 0)
                try await sql.raw("ALTER TABLE im_v2.policy_lookup_hidden_changes RENAME TO policy_authorization_changes").run()
                #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.policy_authorization_changes").first(decoding: PolicyDomainCount.self)?.value == 0)
                await owner.shutdown()
            } catch {
                try? await sql.raw("ALTER TABLE im_v2.policy_lookup_hidden_changes RENAME TO policy_authorization_changes").run()
                await owner.shutdown()
                throw error
            }
        }
    }

    @Test("compact policy facts survive object eviction, mutation and expiry without fact SQL", arguments: [false, true])
    func currentPolicyRetainedFactsAcrossEviction(failFirstCommit: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, _, sql, _, _ in
            let metrics = V2SendOperationBatchMetrics()
            let journal = PostgresV2PolicyAuthorizationJournal(database: control, stateMetrics: metrics, roomDrainRequired: false)
            let directory = PostgresV2PolicyOwnerDirectory(journal: journal,
                dispatcher: .init(database: control, projectionDelivery: SuccessfulProjectionDelivery(),
                    legacyAuthorization: .init(controlDatabase: control, ownerDatabases: [:])),
                maximumOwners: 1, maximumRetainedStates: 4, maximumRetainedStateBytes: 2_048,
                memoryMetrics: metrics, leaseSeconds: 1,
                revoke: { _ in throw V2PolicyAuthorizationLifecycleError.invalidTarget })
            let scopes: [V2PolicyAuthorizationScope] = [.account(senderUUID), .account(memberTwoUUID),
                .pair(senderUUID, memberTwoUUID), .stranger(memberTwoUUID)]
            let tables = ["public_user_profiles", "account_disables", "special_accounts", "user_blocks", "user_relationships", "user_stranger_message_preferences"]
            var hidden: [String] = []
            var trigger = false
            do {
                let before = try await directory.registrationStates(scopes: scopes)
                #expect(before.count == 4)
                #expect(await directory.pressure().owners == 1)
                #expect(await directory.pressure().retainedStates == 3)
                let mutation = try await policyDomainCommand(kind: "block", database: control)
                if failFirstCommit {
                    try await sql.raw("""
                        CREATE FUNCTION im_v2.retained_policy_commit_failure() RETURNS trigger LANGUAGE plpgsql AS
                        'BEGIN RAISE EXCEPTION ''retained policy commit failure''; END'
                        """).run()
                    try await sql.raw("""
                        CREATE CONSTRAINT TRIGGER retained_policy_commit_failure AFTER INSERT ON im_v2.policy_authorization_outbox
                        DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION im_v2.retained_policy_commit_failure()
                        """).run()
                    trigger = true
                    await #expect(throws: (any Error).self) { try await directory.change(mutation) }
                    #expect(try await directory.cachedRegistrationStates(scopes: [.pair(senderUUID, memberTwoUUID)]) == nil)
                    let unchanged = try #require(try await directory.registrationStates(scopes: [.pair(senderUUID, memberTwoUUID)]).first)
                    guard case .pair(let original) = unchanged.facts else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
                    #expect(!original.blocked)
                    try await sql.raw("DROP TRIGGER retained_policy_commit_failure ON im_v2.policy_authorization_outbox").run()
                    try await sql.raw("DROP FUNCTION im_v2.retained_policy_commit_failure()").run()
                    trigger = false
                }
                _ = try await directory.change(mutation)
                // The mutated pair becomes dormant again before lookup.
                _ = try await directory.registrationOwners(scopes: [.account(senderUUID)])
                // Both participant orders refer to the same retained pair.
                _ = try await directory.registrationOwners(scopes: [.pair(memberTwoUUID, senderUUID)])
                _ = try await directory.registrationOwners(scopes: [.account(senderUUID)])
                let reads = metrics.sendOperationBatchMetricsSnapshot().stages[.policyOwnerStateFacts]?.count
                for table in tables {
                    try await sql.raw("ALTER TABLE im_v2.\(unsafeRaw: table) RENAME TO \(unsafeRaw: "retained_hidden_" + table)").run()
                    hidden.append(table)
                }
                // Lease expiry must renew authority, retaining exact facts.
                try await Task.sleep(for: .milliseconds(1_200))
                let after = try await directory.registrationStates(scopes: scopes)
                let pair = try #require(after.first { $0.owner.scope == .pair(senderUUID, memberTwoUUID) })
                guard case .pair(let facts) = pair.facts else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
                #expect(facts.blocked)
                #expect(pair.owner.revision == before.first { $0.owner.scope == pair.owner.scope }!.owner.revision + 1)
                #expect(after.allSatisfy { $0.deadline > .now })
                #expect(metrics.sendOperationBatchMetricsSnapshot().stages[.policyOwnerStateFacts]?.count == reads)
                let events = metrics.sendOperationBatchMetricsSnapshot().policyMemoryEvents
                #expect(events[.ownerEvicted, default: 0] > 0 && events[.ownerRestored, default: 0] > 0)
                #expect(events[.factsEvicted, default: 0] == 0)
                #expect(await directory.pressure().retainedBytes <= 2_048)
                for table in hidden.reversed() {
                    try await sql.raw("ALTER TABLE im_v2.\(unsafeRaw: "retained_hidden_" + table) RENAME TO \(unsafeRaw: table)").run()
                }
                hidden.removeAll()
                await directory.shutdown()
                #expect(await directory.pressure().retainedStates == 0)
                #expect(await directory.pressure().retainedBytes == 0)
            } catch {
                for table in hidden.reversed() {
                    try? await sql.raw("ALTER TABLE im_v2.\(unsafeRaw: "retained_hidden_" + table) RENAME TO \(unsafeRaw: table)").run()
                }
                if trigger {
                    try? await sql.raw("DROP TRIGGER retained_policy_commit_failure ON im_v2.policy_authorization_outbox").run()
                    try? await sql.raw("DROP FUNCTION im_v2.retained_policy_commit_failure()").run()
                }
                await directory.shutdown(); throw error
            }
        }
    }

    @Test("a mutation that commits after lease expiry retains committed memory facts through receipt replay and fenced renewal")
    func currentPolicyCommittedFactsAfterLeaseExpiry() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let metrics = V2SendOperationBatchMetrics()
            let journal = PostgresV2PolicyAuthorizationJournal(database: database, stateMetrics: metrics, roomDrainRequired: false)
            let scope = V2PolicyAuthorizationScope.account(senderUUID)
            let owner = PostgresV2PolicyOwner(journal: journal, scope: scope, leaseSeconds: 1,
                snapshot: { context, change in
                    let facts = try await journal.mutationFacts(scope: scope, context: context, change: change)
                    let sql = try #require(context.transaction as? any SQLDatabase)
                    try await sql.raw("ALTER TABLE im_v2.public_user_profiles RENAME TO expired_commit_hidden_profiles").run()
                    // The journal sampled this one-second lease before the
                    // mutation. Let real time expire it inside the actual SQL
                    // transaction, after capturing final committed facts.
                    try await Task.sleep(for: .milliseconds(1_200))
                    return facts
                }, revoke: { _ in
                    Issue.record("Current policy must not revoke rooms")
                    throw V2PolicyAuthorizationLifecycleError.invalidTarget
                }, apply: { context, _ in
                    let sql = try #require(context.transaction as? any SQLDatabase)
                    try await sql.raw("UPDATE im_v2.public_user_profiles SET state='suspended' WHERE user_id=\(bind: senderUUID)").run()
                    return Data([1])
                })
            var hidden = false
            do {
                let initial = try await owner.registrationState()
                let execution = try await owner.changeExecution(operationKey: "expired-commit-facts",
                    fingerprint: Data(repeating: 7, count: 32), commandJSON: "{}")
                hidden = true
                let committed = try #require(execution.state)
                #expect(committed.owner.revision == initial.owner.revision + 1)
                #expect(committed.deadline <= .now)
                guard case .account(let facts) = committed.facts else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
                #expect(!facts.isActive)
                #expect(try await owner.cachedRegistrationState() == nil)
                let reads = metrics.sendOperationBatchMetricsSnapshot().stages[.policyOwnerStateFacts]?.count
                let replay = try await owner.changeExecution(operationKey: "expired-commit-facts",
                    fingerprint: Data(repeating: 7, count: 32), commandJSON: "{}")
                #expect(replay.replayed && replay.state == nil && replay.receipt == execution.receipt)
                #expect(try await owner.cachedRegistrationState() == nil)
                // The fact table remains absent. Renewal must validate the
                // owner/revision tuple and retain the committed inactive fact.
                let renewed = try await owner.registrationState()
                #expect(renewed.facts == committed.facts)
                #expect(renewed.owner.revision == committed.owner.revision && renewed.owner.epoch > committed.owner.epoch)
                #expect(renewed.deadline > .now)
                #expect(metrics.sendOperationBatchMetricsSnapshot().stages[.policyOwnerStateFacts]?.count == reads)
                try await sql.raw("ALTER TABLE im_v2.expired_commit_hidden_profiles RENAME TO public_user_profiles").run()
                hidden = false
                await owner.shutdown()
            } catch {
                if hidden { try? await sql.raw("ALTER TABLE im_v2.expired_commit_hidden_profiles RENAME TO public_user_profiles").run() }
                await owner.shutdown()
                throw error
            }
        }
    }

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
            let directory = PostgresV2PolicyOwnerDirectory(journal: .init(database: control, roomDrainRequired: false),
                dispatcher: .init(database: control, projectionDelivery: SuccessfulProjectionDelivery(),
                    legacyAuthorization: .init(controlDatabase: control, ownerDatabases: [:])),
                revoke: { _ in throw V2PolicyAuthorizationLifecycleError.invalidTarget })
            let policies = V2RoomPolicyAuthorizationService(roomDatabase: owner, controlDatabase: control,
                policyOwners: directory, endpoint: "room-b", maximumRooms: 1, usesCurrentState: true)
            let host = PostgresV2RoomPolicyAuthorizationDirectory(database: owner, endpoint: "room-b-scalar", maximumRooms: 1,
                currentLoader: { _, sender, recipient, _ in
                    let recipient = try #require(recipient)
                    let states = try await directory.registrationStates(scopes: [.account(sender), .account(recipient),
                        .pair(sender, recipient), .stranger(recipient)])
                    return try .direct(pair: .init(sender: sender, recipient: recipient), states: states)
                }, loader: { _, _, _, _ in throw V2PolicyAuthorizationLifecycleError.invalidRequest })
            let tables = ["public_user_profiles", "account_disables", "special_accounts", "user_blocks", "user_relationships", "user_stranger_message_preferences"]
            var hidden: [String] = []
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
                            let result = try await runtime.execute(command: command, callerDeadline: .now + .seconds(5)) { execution in
                                try await base.usingPolicyExecution(execution).accept(command: command, capacityProfile: profile,
                                    identifiers: V2AcceptanceIDFactory().make(at: Date()), now: Date())
                            }
                            switch result {
                            case .accepted: #expect(recipientHasReplied)
                            case .denied: #expect(!recipientHasReplied)
                            default: throw V2RoomWriteStoreError.corruptPersistenceState
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
                        hidden.append(table)
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
                    for table in hidden.reversed() {
                        try await controlSQL.raw("ALTER TABLE im_v2.\(unsafeRaw: table + "_reply_hidden") RENAME TO \(unsafeRaw: table)").run()
                    }
                    hidden = []
                }
                try await host.shutdown(); try await policies.shutdown(); await directory.shutdown()
            } catch {
                for table in hidden.reversed() {
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
            let directory = PostgresV2PolicyOwnerDirectory(journal: .init(database: database, roomDrainRequired: false),
                dispatcher: .init(database: database, projectionDelivery: SuccessfulProjectionDelivery(),
                    legacyAuthorization: .init(controlDatabase: database, ownerDatabases: [:])),
                revoke: { _ in Issue.record("Group account changes must not revoke rooms"); throw V2PolicyAuthorizationLifecycleError.invalidTarget })
            let policies = V2RoomPolicyAuthorizationService(roomDatabase: database, controlDatabase: database,
                policyOwners: directory, endpoint: "room-a", maximumRooms: 1, usesCurrentState: true)
            let store = PostgresV2MessageSendOperationStore(database: database,
                writes: PostgresV2RoomWriteStore(database: database, contentReviewMode: .disabled)
                    .usingControlDatabase(database).usingPolicyAuthorizations(policies))
            var hidden = false
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
                    #expect(await directory.pressure().owners == 1)
                    let disable = V2DurablePolicyMutation.disable(.init(command: try .init(userID: senderID,
                        operationID: UUID(), reason: .policyEnforcement), operatorPrincipal: "current-group-test"))
                    _ = try await directory.changeExecution(disable)
                    try await sql.raw("ALTER TABLE im_v2.public_user_profiles RENAME TO current_group_hidden_profiles").run()
                    hidden = true
                    let denied = try await policies.prepareOwnerBatches(store: store,
                        requests: [.init(commands: [command()], token: token, deadline: .now + .seconds(5))], now: Date.init)
                    let deniedResult = try await store.executeIndependentRoomTurns(denied.map { try $0.get() },
                        capacityProfile: profile, identifiers: .init(), now: Date.init)
                    guard case .sendOperation(.receipt(let rejection))? = try deniedResult[0].get().first else {
                        throw V2RoomWriteStoreError.corruptPersistenceState
                    }
                    #expect(rejection.outcome == .rejected(.permissionDenied))
                    #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.policy_authorization_holders").first(decoding: PolicyDomainCount.self)?.value == 0)
                    try await sql.raw("ALTER TABLE im_v2.current_group_hidden_profiles RENAME TO public_user_profiles").run()
                    hidden = false
                }
                try await policies.shutdown(); await directory.shutdown()
            } catch {
                if hidden { try? await sql.raw("ALTER TABLE im_v2.current_group_hidden_profiles RENAME TO public_user_profiles").run() }
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
            let legacy = V2DirectAuthorizationCoordinator(controlDatabase: control, ownerDatabases: [:])
            let directory = PostgresV2PolicyOwnerDirectory(journal: .init(database: control, stateMetrics: metrics, roomDrainRequired: false),
                dispatcher: .init(database: control, projectionDelivery: SuccessfulProjectionDelivery(), legacyAuthorization: legacy),
                revoke: { _ in Issue.record("Current policy service must not revoke a room"); throw V2PolicyAuthorizationLifecycleError.invalidTarget })
            let policies = V2RoomPolicyAuthorizationService(roomDatabase: owner, controlDatabase: control,
                policyOwners: directory, endpoint: "room-b", maximumRooms: 1, usesCurrentState: true,
                sendOperationMetrics: metrics)
            let writes = PostgresV2RoomWriteStore(database: owner,
                strangerMessagePolicy: try .init(maximumMessagesPerWindow: 10, window: 86_400), contentReviewMode: .disabled)
                .usingControlDatabase(control).usingPolicyAuthorizations(policies)
            let store = PostgresV2MessageSendOperationStore(database: owner, writes: writes, sendOperationMetrics: metrics)
            let social = PostgresV2SocialRelationshipStore(database: control, projectionDelivery: SuccessfulProjectionDelivery(),
                authorizationCoordinator: legacy).usingPolicyOwners(directory)
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
            var hidden: [String] = []
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
                        let readsBefore = metrics.sendOperationBatchMetricsSnapshot().stages[.preparationOwnerRead]?.count ?? 0
                        #expect(readsBefore == 0)
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
                        #expect(metrics.sendOperationBatchMetricsSnapshot().stages[.preparationOwnerRead]?.count ?? 0 == readsBefore)
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
                    #expect(mergedStages[.ownerReceiptPersistence]?.count ?? 0 == 0)
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
                        fingerprint: first.fingerprint, domainFingerprint: first.command.fingerprint, action: .query)
                    let missing = try command()
                    let absentQuery = try V2MessageSendOperationRecoveryRequest(identity: missing.identity,
                        fingerprint: missing.fingerprint, domainFingerprint: missing.command.fingerprint, action: .closeIfAbsent)
                    let missingPrepared = try await prepare([missing])
                    let runtimeTables = friends ? ["room_activation_leases", "room_memberships", "room_member_mutes", "direct_room_pairs", "shard_admission_pools", "room_admission"] : ["room_activation_leases"]
                    var runtimeHidden: [String] = []
                    do {
                        for table in runtimeTables {
                            try await ownerSQL.raw("ALTER TABLE im_v2.\(unsafeRaw: table) RENAME TO \(unsafeRaw: table + "_runtime_hidden")").run()
                            runtimeHidden.append(table)
                        }
                        #expect(try await PostgresV2MessageSendOperationStore.queryRecovery(resultQuery, database: owner)
                            == { if case .sendOperation(let result) = accepted[0] { return result }; return .unresolved }())
                        #expect(try await PostgresV2MessageSendOperationStore.queryRecovery(absentQuery, database: owner) == .unresolved)
                        #expect(try await ownerSQL.raw("SELECT count(*)::bigint AS value FROM im_v2.message_operation_closures").first(decoding: MergedReceiptCount.self)?.value == 0)
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
                    _ = try await social.submitSocialOperation(block, now: Date())
                    let blockedCommand = try command()
                    let blockedResult = try await execute(prepare([blockedCommand]))
                    guard case .sendOperation(.receipt(let denied))? = blockedResult.first else {
                        throw V2RoomWriteStoreError.corruptPersistenceState
                    }
                    #expect(denied.outcome == .rejected(.directPolicyDenied))
                    let rejectionQuery = try V2MessageSendOperationRecoveryRequest(identity: blockedCommand.identity,
                        fingerprint: blockedCommand.fingerprint, domainFingerprint: blockedCommand.command.fingerprint, action: .query)
                    #expect(try await PostgresV2MessageSendOperationStore.queryRecovery(rejectionQuery, database: owner) == .unresolved)
                    #expect(try await ownerSQL.raw("SELECT count(*)::bigint AS value FROM im_v2.direct_message_denials WHERE client_message_id=\(bind: blockedCommand.command.clientMessageID.uuidValue!)").first(decoding: MergedReceiptCount.self)?.value == 0)
                    #expect(try await execute(prepare([first, second])) == accepted)
                    let unblock = try await social.freezeSocialFixture(actorUserID: senderID, targetUserID: .init(uuid: memberTwoUUID),
                        operation: .userBlock(.init(uuid: UUID())), action: .userBlock(.unblock), now: Date())
                    _ = try await social.submitSocialOperation(unblock, now: Date())
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
                        hidden.append(table)
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
                    #expect(metrics.sendOperationBatchMetricsSnapshot().stages[.policySnapshotRegistration]?.count ?? 0 == 0)
                    #expect(try await controlSQL.raw("SELECT count(*)::bigint AS value FROM im_v2.policy_authorization_holders").first(decoding: PolicyDomainCount.self)?.value == 0)
                    #expect(try await ownerSQL.raw("SELECT count(*)::bigint AS value FROM im_v2.room_policy_authorization_leases").first(decoding: PolicyDomainCount.self)?.value == 0)
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
                            fingerprint: uncertain.fingerprint, domainFingerprint: uncertain.command.fingerprint, action: .query)
                        let recovered = try await PostgresV2MessageSendOperationStore.queryRecovery(recovery, database: owner)
                        if case .receipt(let receipt) = recovered {
                            let identity = try uncertain.identity
                            #expect(receipt.identity == identity)
                        } else { #expect(recovered == .unresolved) }
                    }
                    for table in hidden.reversed() {
                        try await controlSQL.raw("ALTER TABLE im_v2.\(unsafeRaw: table + "_current_service_hidden") RENAME TO \(unsafeRaw: table)").run()
                    }
                    hidden = []
                }
                try await policies.shutdown(); await directory.shutdown()
            } catch {
                for table in hidden.reversed() {
                    try? await controlSQL.raw("ALTER TABLE im_v2.\(unsafeRaw: table + "_current_service_hidden") RENAME TO \(unsafeRaw: table)").run()
                }
                try? await policies.shutdown(); await directory.shutdown()
                throw error
            }
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
            let journal = PostgresV2PolicyAuthorizationJournal(database: control, roomDrainRequired: false)
            let directory = PostgresV2PolicyOwnerDirectory(journal: journal,
                dispatcher: .init(database: control, projectionDelivery: SuccessfulProjectionDelivery(),
                    legacyAuthorization: .init(controlDatabase: control, ownerDatabases: [:])),
                revoke: { _ in Issue.record("Current memory policy must not revoke a room"); throw V2PolicyAuthorizationLifecycleError.invalidTarget })
            // Warm the potential non-friend branch too. Hiding fact tables
            // after the mutation then proves the new decision is memory-only.
            _ = try await directory.registrationStates(scopes: [.account(senderUUID), .account(memberTwoUUID),
                .pair(senderUUID, memberTwoUUID), .stranger(memberTwoUUID)])
            let mutation = try await policyDomainCommand(kind: kind, database: control)
            try await withRoomActivation(database: owner, roomID: room.roomID, shardID: "room-b") { token in
                let host = PostgresV2RoomPolicyAuthorizationDirectory(database: owner, endpoint: "room-b", maximumRooms: 1,
                    currentLoader: { _, sender, recipient, _ in
                        let recipient = try #require(recipient)
                        let scopes: [V2PolicyAuthorizationScope] = [.account(sender), .account(recipient), .pair(sender, recipient)]
                        var states = try await directory.registrationStates(scopes: scopes)
                        let relationship = try #require(states.first { $0.owner.scope.key == V2PolicyAuthorizationScope.pair(sender, recipient).key })
                        guard case .pair(let social) = relationship.facts else { throw V2PolicyAuthorizationLifecycleError.invalidTarget }
                        if !social.isFriend { states += try await directory.registrationStates(scopes: [.stranger(recipient)]) }
                        return try .direct(pair: .init(sender: sender, recipient: recipient), states: states)
                    }, loader: { _, _, _, _ in
                        Issue.record("Current policy must not register a room snapshot")
                        throw V2PolicyAuthorizationLifecycleError.invalidRequest
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
                var hidden: [String] = []
                do {
                    let deadline = ContinuousClock.now + .seconds(5)
                    while !(await barrier.entered), .now < deadline { await Task.yield() }
                    #expect(await barrier.entered)
                    // This call must finish with the actual message SQL still
                    // held. A room-draining implementation times out here.
                    _ = try await directory.changeExecution(mutation)
                    #expect(await runtime.pressure().executions == 1)
                    #expect(await barrier.entered)
                    #expect(await !barrier.released)
                    for table in tables {
                        try await controlSQL.raw("ALTER TABLE im_v2.\(unsafeRaw: table) RENAME TO \(unsafeRaw: table + "_current_hidden")").run()
                        hidden.append(table)
                    }
                    let next = try V2SendMessageCommand(roomID: room.roomID, senderUserID: senderID,
                        clientMessageID: .init(uuid: UUID()), text: "new authorization", limits: .init(maxUTF8Bytes: 64))
                    let nextPrepared = try await runtime.prepareBatch(commands: [next], callerDeadline: .now + .seconds(5))
                    let updatedPolicy = try #require(try await runtime.executePreparedBatch(nextPrepared) { $0.snapshot.policy })
                    switch kind {
                    case "block": #expect(updatedPolicy.blocked)
                    case "disable": #expect(!updatedPolicy.recipient.isActive)
                    default: #expect(!updatedPolicy.isFriend && !updatedPolicy.allowsStrangers)
                    }
                    #expect(try await controlSQL.raw("SELECT count(*)::bigint AS value FROM im_v2.policy_authorization_holders").first(decoding: PolicyDomainCount.self)?.value == 0)
                    #expect(try await controlSQL.raw("SELECT count(*)::bigint AS value FROM im_v2.policy_authorization_revocations").first(decoding: PolicyDomainCount.self)?.value == 0)
                    #expect(try await ownerSQL.raw("SELECT count(*)::bigint AS value FROM im_v2.room_policy_authorization_leases").first(decoding: PolicyDomainCount.self)?.value == 0)
                    await barrier.release()
                    let (accepted, expiredExecution) = try await held.value
                    guard case .accepted = accepted else { throw V2RoomWriteStoreError.corruptPersistenceState }
                    #expect(await runtime.pressure().executions == 0)
                    let denied = try await runtime.executePreparedBatch(nextPrepared) { execution in
                        try await base.usingPolicyExecution(execution).accept(command: next, capacityProfile: profile,
                            identifiers: V2AcceptanceIDFactory().make(at: Date()), now: Date())
                    }
                    guard case .denied = denied else { throw V2RoomWriteStoreError.corruptPersistenceState }
                    await #expect(throws: V2RoomPolicyAuthorizationGate.Failure.invalidPermit) {
                        try await owner.transaction { transaction in
                            try await expiredExecution.requireActive(roomID: room.roomID.uuidValue!, senderID: senderUUID,
                                clientMessageID: command.clientMessageID.uuidValue!, sql: try #require(transaction as? any SQLDatabase))
                        }
                    }
                    for table in hidden.reversed() {
                        try await controlSQL.raw("ALTER TABLE im_v2.\(unsafeRaw: table + "_current_hidden") RENAME TO \(unsafeRaw: table)").run()
                    }
                    hidden = []
                    try await host.shutdown()
                } catch {
                    await barrier.release(); _ = await held.result
                    for table in hidden.reversed() {
                        try? await controlSQL.raw("ALTER TABLE im_v2.\(unsafeRaw: table + "_current_hidden") RENAME TO \(unsafeRaw: table)").run()
                    }
                    try? await host.shutdown(); await directory.shutdown()
                    throw error
                }
            }
            await directory.shutdown()
        }
    }

    @Test("detached local policy state work keeps its caller deadline while waiting for SQL admission")
    func policyStateAdmissionKeepsCallerDeadline() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, _, _, _, _ in
            let admission = V2DatabaseWorkAdmissionController(policy: .init(maximumForegroundWriteInFlight: 1,
                maximumInteractiveReadInFlight: 1, maximumSyncInFlight: 1,
                maximumForegroundWriteQueued: 1, maximumInteractiveReadQueued: 1,
                maximumSyncQueued: 16, timeout: .seconds(5)))
            let metrics = V2SendOperationBatchMetrics()
            let owners = PostgresV2PolicyOwnerDirectory(journal: .init(database: control,
                stateReadAdmission: admission, stateMetrics: metrics),
                dispatcher: .init(database: control, projectionDelivery: SuccessfulProjectionDelivery(),
                    legacyAuthorization: .init(controlDatabase: control, ownerDatabases: [:])),
                revoke: { _ in throw V2PolicyAuthorizationLifecycleError.invalidTarget })
            guard case .admitted = await admission.acquire(.sync, callerDeadline: .now + .seconds(5)) else {
                throw V2PolicyAuthorizationLifecycleError.busy
            }
            let deadline = ContinuousClock.now + .milliseconds(250)
            let waiting = Task {
                try await V2RoomSQLDeadline.withDeadline(deadline) {
                    try await owners.registrationStates(scopes: [.account(senderUUID)])
                }
            }
            var permitHeld = true
            do {
                await #expect(throws: V2RoomCallFailure.notAccepted(.deadlineExceeded)) { try await waiting.value }
                #expect(await owners.pressure().roots == 0)
                let pressure = await admission.snapshot().sync
                #expect(pressure.inFlight == 1 && pressure.queued == 0 && pressure.timeoutRejections == 1)
                let stages = metrics.sendOperationBatchMetricsSnapshot().stages
                #expect(stages[.policyOwnerStateDatabaseAdmission]?.count == 1)
                #expect(stages[.policyOwnerStateTransaction]?.count == 0)
                #expect(stages[.policyOwnerStateTransaction]?.inFlight == 0)
                await admission.release(.sync)
                permitHeld = false
                let states = try await owners.registrationStates(scopes: [.account(senderUUID)])
                #expect(states.count == 1 && states[0].deadline > .now)
                #expect(await admission.snapshot().sync.inFlight == 0)
                #expect(metrics.sendOperationBatchMetricsSnapshot().stages[.policyOwnerStateTransaction]?.count == 1)
                await owners.shutdown()
            } catch {
                if permitHeld { await admission.release(.sync) }
                _ = await waiting.result
                await owners.shutdown()
                throw error
            }
        }
    }

    @Test("policy mutations publish transaction facts only after actual COMMIT and never reload after success",
          arguments: [false, true], [false, true])
    func policyMutationCommittedMemoryPublication(failCommit: Bool, usesCurrentState: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, _, sql, _, _ in
            let journal = PostgresV2PolicyAuthorizationJournal(database: control, roomDrainRequired: !usesCurrentState)
            let scope = V2PolicyAuthorizationScope.account(senderUUID)
            let owner = PostgresV2PolicyOwner(journal: journal, scope: scope,
                snapshot: { context, change in
                    let facts = try await journal.mutationFacts(scope: scope, context: context, change: change)
                    if !failCommit {
                        let connection = try #require(context.transaction as? any SQLDatabase)
                        try await connection.raw("ALTER TABLE im_v2.public_user_profiles RENAME TO policy_commit_hidden_profiles").run()
                    }
                    return facts
                }, revoke: { _ in throw V2PolicyAuthorizationLifecycleError.invalidTarget },
                apply: { context, _ in
                    let connection = try #require(context.transaction as? any SQLDatabase)
                    try await connection.raw("UPDATE im_v2.public_user_profiles SET state='suspended' WHERE user_id=\(bind: senderUUID)").run()
                    return Data([1])
                })
            let initial = try await owner.registrationState()
            var hidden = false, trigger = false
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
                    #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.policy_authorization_scopes WHERE scope_key=\(bind: scope.key) AND revision=\(bind: initial.owner.revision) AND pending_change_key='commit-memory'").first(decoding: PolicyDomainCount.self)?.value == (usesCurrentState ? 0 : 1))
                    #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.policy_authorization_outbox WHERE operation_key='commit-memory'").first(decoding: PolicyDomainCount.self)?.value == 0)
                    if usesCurrentState {
                        // A failed COMMIT rolls back the whole operation;
                        // it leaves no prepared change or authorization seal.
                        #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.policy_authorization_changes WHERE operation_key='commit-memory'").first(decoding: PolicyDomainCount.self)?.value == 0)
                        let unchanged = try await owner.registrationState()
                        #expect(unchanged.owner.revision == initial.owner.revision && unchanged.facts == initial.facts)
                    } else {
                        await #expect(throws: V2PolicyAuthorizationLifecycleError.busy) { try await owner.registrationState() }
                    }
                    try await sql.raw("DROP TRIGGER policy_commit_test_failure ON im_v2.public_user_profiles").run()
                    try await sql.raw("DROP FUNCTION im_v2.policy_commit_test_failure()").run()
                    trigger = false
                }
                let execution = try await owner.changeExecution(operationKey: "commit-memory", fingerprint: Data(repeating: 3, count: 32), commandJSON: "{}")
                hidden = !failCommit
                #expect(execution.receipt == Data([1]) && !execution.replayed)
                #expect(execution.state?.owner.revision == initial.owner.revision + 1)
                if failCommit {
                    try await sql.raw("ALTER TABLE im_v2.public_user_profiles RENAME TO policy_commit_hidden_profiles").run()
                    hidden = true
                }
                let updated = try await owner.registrationState()
                guard case .account(let facts) = updated.facts else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
                #expect(!facts.isActive && updated.owner.revision == initial.owner.revision + 1)
                #expect(updated.deadline > .now && updated.owner == execution.state?.owner)
                // Facts remain hidden: replay must preserve the current
                // committed memory state without another cold SQL read.
                let replay = try await owner.changeExecution(operationKey: "commit-memory",
                    fingerprint: Data(repeating: 3, count: 32), commandJSON: "{}")
                #expect(replay.replayed && replay.receipt == execution.receipt && replay.state == nil)
                let afterReplay = try await owner.registrationState()
                #expect(afterReplay.owner == updated.owner && afterReplay.facts == updated.facts
                    && afterReplay.deadline == updated.deadline)
                try await sql.raw("ALTER TABLE im_v2.policy_commit_hidden_profiles RENAME TO public_user_profiles").run()
                hidden = false
                await owner.shutdown()
            } catch {
                if hidden { try? await sql.raw("ALTER TABLE im_v2.policy_commit_hidden_profiles RENAME TO public_user_profiles").run() }
                if trigger {
                    try? await sql.raw("DROP TRIGGER policy_commit_test_failure ON im_v2.public_user_profiles").run()
                    try? await sql.raw("DROP FUNCTION im_v2.policy_commit_test_failure()").run()
                }
                await owner.shutdown()
                throw error
            }
        }
    }

    @Test("expired memory owners renew unchanged policy facts without querying fact tables",
          arguments: ["account", "pair", "stranger"])
    func memoryPolicyFactsSurviveLeaseRenewal(kind: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, _, sql, _, _ in
            let scope: V2PolicyAuthorizationScope
            let table: String
            switch kind {
            case "pair": scope = .pair(senderUUID, memberTwoUUID); table = "user_blocks"
            case "stranger": scope = .stranger(memberTwoUUID); table = "user_stranger_message_preferences"
            default: scope = .account(senderUUID); table = "public_user_profiles"
            }
            let metrics = V2SendOperationBatchMetrics()
            let owner = PostgresV2PolicyOwner(journal: .init(database: control, stateMetrics: metrics), scope: scope,
                leaseSeconds: 0.2, revoke: { _ in throw V2PolicyAuthorizationLifecycleError.invalidTarget },
                apply: { _, _ in throw V2PolicyAuthorizationLifecycleError.invalidRequest })
            let original = try await owner.registrationState()
            try await sql.raw("ALTER TABLE im_v2.\(unsafeRaw: table) RENAME TO policy_renewal_hidden_facts").run()
            do {
                try await Task.sleep(for: .milliseconds(250))
                #expect(original.deadline <= .now)
                let renewed = try await owner.registrationState()
                #expect(renewed.facts == original.facts)
                #expect(renewed.owner.ownerID == original.owner.ownerID)
                #expect(renewed.owner.epoch == original.owner.epoch + 1)
                #expect(renewed.owner.revision == original.owner.revision)
                #expect(renewed.deadline > .now)
                #expect(await owner.pressure().roots == 0)
                let measured = metrics.sendOperationBatchMetricsSnapshot().stages
                #expect(measured[.policyOwnerStateTransaction]?.count == 2)
                #expect(measured[.policyOwnerStateFacts]?.count == 1)
                #expect(measured[.policyOwnerStateFacts]?.inFlight == 0)
                try await sql.raw("ALTER TABLE im_v2.policy_renewal_hidden_facts RENAME TO \(unsafeRaw: table)").run()
                await owner.shutdown()
            } catch {
                try? await sql.raw("ALTER TABLE im_v2.policy_renewal_hidden_facts RENAME TO \(unsafeRaw: table)").run()
                await owner.shutdown()
                throw error
            }
        }
    }

    @Test("memory fact renewal rejects pending changes and reloads after revision or incarnation changes",
          arguments: ["revision", "epoch", "takeover", "pending"])
    func memoryPolicyFactRenewalFences(kind: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, _, sql, _, _ in
            let journal = PostgresV2PolicyAuthorizationJournal(database: control)
            let scope = V2PolicyAuthorizationScope.account(senderUUID), ownerID = UUID()
            let original = try await journal.acquireOwnerState(scope: scope, ownerID: ownerID, durationSeconds: 30)
            if kind == "revision" || kind == "pending" {
                _ = try await journal.beginChange(owner: original.owner, operationKey: "renewal-change",
                    fingerprint: Data(repeating: 3, count: 32), commandJSON: "{}")
                if kind == "revision" {
                    _ = try await journal.commitChange(owner: original.owner, operationKey: "renewal-change") { transaction, _ in
                        let connection = try #require(transaction as? any SQLDatabase)
                        try await connection.raw("UPDATE im_v2.public_user_profiles SET state='suspended' WHERE user_id=\(bind: senderUUID)").run()
                        return Data([1])
                    }
                }
            } else {
                try await sql.raw("UPDATE im_v2.policy_authorization_scopes SET owner_valid_until=clock_timestamp()-interval '1 second' WHERE scope_key=\(bind: scope.key)").run()
                _ = try await journal.acquireOwner(scope: scope, ownerID: kind == "takeover" ? UUID() : ownerID, durationSeconds: 30)
                if kind == "takeover" {
                    try await sql.raw("UPDATE im_v2.policy_authorization_scopes SET owner_valid_until=clock_timestamp()-interval '1 second' WHERE scope_key=\(bind: scope.key)").run()
                }
            }
            try await sql.raw("ALTER TABLE im_v2.public_user_profiles RENAME TO policy_renewal_hidden_facts").run()
            do {
                if kind == "pending" {
                    await #expect(throws: V2PolicyAuthorizationLifecycleError.busy) {
                        try await journal.acquireOwnerState(scope: scope, ownerID: ownerID, durationSeconds: 30, cachedState: original)
                    }
                } else {
                    // The missing table proves that stale cached facts were
                    // not reused across a version or owner incarnation change.
                    await #expect(throws: (any Error).self) {
                        try await journal.acquireOwnerState(scope: scope, ownerID: ownerID, durationSeconds: 30, cachedState: original)
                    }
                }
                try await sql.raw("ALTER TABLE im_v2.policy_renewal_hidden_facts RENAME TO public_user_profiles").run()
            } catch {
                try? await sql.raw("ALTER TABLE im_v2.policy_renewal_hidden_facts RENAME TO public_user_profiles").run()
                throw error
            }
            if kind != "pending" {
                let loaded = try await journal.acquireOwnerState(scope: scope, ownerID: ownerID, durationSeconds: 30, cachedState: original)
                #expect(loaded.deadline > .now)
                if kind == "revision" {
                    guard case .account(let facts) = loaded.facts else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
                    #expect(!facts.isActive && loaded.owner.revision == original.owner.revision + 1)
                } else {
                    #expect(loaded.owner.epoch > original.owner.epoch)
                }
            }
        }
    }

    @Test("a one-entry owner cache still returns a complete four-scope state batch without growing")
    func parallelPolicyStateSmallCache() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, _, _, _, _ in
            let directory = PostgresV2PolicyOwnerDirectory(journal: .init(database: control),
                dispatcher: .init(database: control, projectionDelivery: SuccessfulProjectionDelivery(),
                    legacyAuthorization: .init(controlDatabase: control, ownerDatabases: [:])),
                maximumOwners: 1, maximumRoots: 1,
                revoke: { _ in throw V2PolicyAuthorizationLifecycleError.invalidTarget })
            let scopes: [V2PolicyAuthorizationScope] = [.account(senderUUID), .account(memberTwoUUID),
                .pair(senderUUID, memberTwoUUID), .stranger(memberTwoUUID)]
            do {
                let states = try await directory.registrationStates(scopes: scopes.reversed())
                #expect(states.map { $0.owner.scope.key } == scopes.map(\.key).sorted())
                #expect(states.allSatisfy { $0.deadline > .now })
                #expect(await directory.pressure().owners == 1)
                #expect(await directory.pressure().roots == 0)
                await directory.shutdown()
            } catch { await directory.shutdown(); throw error }
        }
    }

    @Test("independent scope state initialization overlaps real SQL waits and joins cancellation", arguments: [false, true])
    func parallelPolicyStateInitialization(cancel: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, _, sql, _, _ in
            let ownerID = UUID(), gate = PolicyStateSQLGate()
            let scopes = [V2PolicyAuthorizationScope.account(senderUUID), .account(memberTwoUUID)]
                .sorted { $0.key < $1.key }
            let blockedUser = scopes[0] == .account(senderUUID) ? senderUUID : memberTwoUUID
            let directory = PostgresV2PolicyOwnerDirectory(journal: .init(database: control),
                dispatcher: .init(database: control, projectionDelivery: SuccessfulProjectionDelivery(),
                    legacyAuthorization: .init(controlDatabase: control, ownerDatabases: [:])),
                ownerID: ownerID, maximumOwners: 2, maximumRoots: 1,
                revoke: { _ in throw V2PolicyAuthorizationLifecycleError.invalidTarget })
            let blocker = Task {
                try await control.transaction { transaction in
                    let connection = try #require(transaction as? any SQLDatabase)
                    _ = try await connection.raw("SELECT user_id FROM im_v2.public_user_profiles WHERE user_id=\(bind: blockedUser) FOR UPDATE").all()
                    let pid = try #require(try await connection.raw("SELECT pg_backend_pid()::bigint AS value").first(decoding: PolicyDomainCount.self)).value
                    await gate.hold(pid: pid)
                }
            }
            var loading: Task<[V2PolicyOwnerState], any Error>?
            var closing: Task<Void, Never>?
            do {
                try await policyFriendObserve { await gate.pid != nil }
                let pid = try #require(await gate.pid)
                let task = Task { try await directory.registrationStates(scopes: scopes.reversed()) }
                loading = task
                try await policyFriendObserve {
                    try await sql.raw("SELECT count(*)::bigint AS value FROM pg_stat_activity WHERE \(bind: pid)::integer=ANY(pg_blocking_pids(pid))").first(decoding: PolicyDomainCount.self)?.value ?? 0 > 0
                }
                // The later canonical scope commits while the first is blocked.
                try await policyFriendObserve {
                    try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.policy_authorization_scopes WHERE scope_key=\(bind: scopes[1].key) AND owner_id=\(bind: ownerID)").first(decoding: PolicyDomainCount.self)?.value == 1
                }
                #expect(await directory.pressure().roots == 1)
                if cancel {
                    task.cancel()
                    closing = Task { await directory.shutdown() }
                    try await policyFriendObserve { await directory.pressure().closed }
                    #expect(await directory.pressure().roots == 1)
                }
                await gate.release(); try await blocker.value
                #expect(try await task.value.map { $0.owner.scope.key } == scopes.map(\.key))
                if let closing { await closing.value } else { await directory.shutdown() }
                #expect(await directory.pressure().roots == 0)
            } catch {
                await gate.release(); _ = await blocker.result; _ = await loading?.result
                if let closing { await closing.value } else { await directory.shutdown() }
                throw error
            }
        }
    }

    @Test("atomic cold facts fail without committing ownership and pending changes reject before reading facts",
          arguments: [false, true])
    func atomicPolicyStateInitializationRollback(usesCurrentState: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, _, sql, _, _ in
            let metrics = V2SendOperationBatchMetrics()
            let journal = PostgresV2PolicyAuthorizationJournal(database: control, stateMetrics: metrics,
                roomDrainRequired: !usesCurrentState)
            let scope = V2PolicyAuthorizationScope.account(senderUUID), previousID = UUID(), replacementID = UUID()
            let previous = try await journal.acquireOwner(scope: scope, ownerID: previousID, durationSeconds: 30)
            try await sql.raw("UPDATE im_v2.policy_authorization_scopes SET owner_valid_until=clock_timestamp()-interval '1 second' WHERE scope_key=\(bind: scope.key)").run()
            try await sql.raw("ALTER TABLE im_v2.public_user_profiles RENAME TO policy_atomic_hidden_profiles").run()
            do {
                await #expect(throws: (any Error).self) {
                    try await journal.acquireOwnerState(scope: scope, ownerID: replacementID, durationSeconds: 30)
                }
                for stage in [V2SendOperationStage.policyOwnerStateTransaction, .policyOwnerStateFacts] {
                    let measured = metrics.sendOperationBatchMetricsSnapshot().stages[stage]
                    #expect(measured?.count == 1 && measured?.inFlight == 0)
                }
                #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.policy_authorization_scopes WHERE scope_key=\(bind: scope.key) AND owner_id=\(bind: previousID) AND owner_epoch=\(bind: previous.epoch)").first(decoding: PolicyDomainCount.self)?.value == 1)
                try await sql.raw("ALTER TABLE im_v2.policy_atomic_hidden_profiles RENAME TO public_user_profiles").run()
            } catch {
                try? await sql.raw("ALTER TABLE im_v2.policy_atomic_hidden_profiles RENAME TO public_user_profiles").run()
                throw error
            }
            let loaded = try await journal.acquireOwnerState(scope: scope, ownerID: replacementID, durationSeconds: 30)
            #expect(loaded.owner.epoch == previous.epoch + 1 && loaded.owner.revision == previous.revision)
            guard case .account(let account) = loaded.facts else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
            #expect(account.isActive && loaded.deadline > .now)
            await #expect(throws: V2PolicyAuthorizationLifecycleError.ownerChanged) {
                try await journal.acquireOwnerState(scope: scope, ownerID: UUID(), durationSeconds: 30)
            }
            _ = try await journal.beginChange(owner: loaded.owner, operationKey: "atomic-state-pending",
                fingerprint: Data(repeating: 3, count: 32), commandJSON: "{}")
            try await sql.raw("ALTER TABLE im_v2.public_user_profiles RENAME TO policy_atomic_hidden_profiles").run()
            do {
                // Undefined fact tables must not mask the scope's change seal.
                await #expect(throws: V2PolicyAuthorizationLifecycleError.busy) {
                    try await journal.acquireOwnerState(scope: scope, ownerID: replacementID, durationSeconds: 30)
                }
                try await sql.raw("ALTER TABLE im_v2.policy_atomic_hidden_profiles RENAME TO public_user_profiles").run()
            } catch {
                try? await sql.raw("ALTER TABLE im_v2.policy_atomic_hidden_profiles RENAME TO public_user_profiles").run()
                throw error
            }
            let completed = metrics.sendOperationBatchMetricsSnapshot().stages
            #expect(completed[.policyOwnerStateDatabaseAdmission]?.count == 4)
            #expect(completed[.policyOwnerStateTransaction]?.count == 4)
            #expect(completed[.policyOwnerStateFacts]?.count == 2)
            for stage in [V2SendOperationStage.policyOwnerStateDatabaseAdmission, .policyOwnerStateTransaction, .policyOwnerStateFacts] {
                #expect(completed[stage]?.inFlight == 0)
            }
        }
    }

    @Test("atomic cold initialization checks lease expiry after a real fact row lock wait", arguments: [false, true])
    func atomicPolicyStateInitializationExpiry(usesCurrentState: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, _, sql, _, _ in
            let journal = PostgresV2PolicyAuthorizationJournal(database: control, roomDrainRequired: !usesCurrentState)
            let scope = V2PolicyAuthorizationScope.account(senderUUID), ownerID = UUID()
            let previous = try await journal.acquireOwner(scope: scope, ownerID: ownerID, durationSeconds: 30)
            let gate = PolicyStateSQLGate()
            let blocker = Task {
                try await control.transaction { transaction in
                    let connection = try #require(transaction as? any SQLDatabase)
                    _ = try await connection.raw("SELECT user_id FROM im_v2.public_user_profiles WHERE user_id=\(bind: senderUUID) FOR UPDATE").all()
                    let pid = try #require(try await connection.raw("SELECT pg_backend_pid()::bigint AS value").first(decoding: PolicyDomainCount.self)).value
                    await gate.hold(pid: pid)
                }
            }
            var loading: Task<V2PolicyOwnerState, any Error>?
            do {
                try await policyFriendObserve { await gate.pid != nil }
                let pid = try #require(await gate.pid)
                let task = Task { try await journal.acquireOwnerState(scope: scope, ownerID: ownerID, durationSeconds: 0.5) }
                loading = task
                try await policyFriendObserve {
                    try await sql.raw("SELECT count(*)::bigint AS value FROM pg_stat_activity WHERE \(bind: pid)::integer=ANY(pg_blocking_pids(pid))").first(decoding: PolicyDomainCount.self)?.value ?? 0 > 0
                }
                let clock = try #require(try await sql.raw("SELECT clock_timestamp() AS value").first(decoding: AtomicPolicyStateClock.self)).value
                try await policyFriendObserve {
                    try await sql.raw("SELECT CASE WHEN clock_timestamp()>=\(bind: clock.addingTimeInterval(0.6))::timestamptz THEN 1 ELSE 0 END::bigint AS value").first(decoding: PolicyDomainCount.self)?.value == 1
                }
                await gate.release(); try await blocker.value
                await #expect(throws: V2PolicyAuthorizationLifecycleError.ownerChanged) { try await task.value }
                // The failed short renewal rolled back, leaving the original
                // valid owner lease available rather than publishing stale facts.
                #expect(try await journal.readOwnerState(owner: previous).owner == previous)
            } catch {
                await gate.release(); _ = await blocker.result; _ = await loading?.result
                throw error
            }
        }
    }

    @Test("policy owners drain outside SQL before committing real domain facts and receipts",
          arguments: ["block", "remove", "stranger", "disable"])
    func policyOwnerDomainMutation(kind: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, roomDatabase, sql, _, _ in
            if kind == "block" || kind == "remove" {
                try await sql.raw("""
                    INSERT INTO im_v2.user_relationships
                    VALUES (LEAST(\(bind: senderUUID)::uuid,\(bind: memberTwoUUID)::uuid),
                        GREATEST(\(bind: senderUUID)::uuid,\(bind: memberTwoUUID)::uuid),
                        'accepted',\(bind: senderUUID),clock_timestamp())
                    """).run()
            }
            let journal = PostgresV2PolicyAuthorizationJournal(database: control)
            let legacy = V2DirectAuthorizationCoordinator(controlDatabase: control, ownerDatabases: [:])
            let dispatcher = PostgresV2PolicyMutationDispatcher(database: control,
                projectionDelivery: SuccessfulProjectionDelivery(), legacyAuthorization: legacy)
            let fence = PostgresV2RoomPolicyLeaseFence(database: roomDatabase)
            let gate = PolicyDomainRevocationGate()
            let directory = PostgresV2PolicyOwnerDirectory(journal: journal, dispatcher: dispatcher,
                maximumOwners: 4, maximumRoots: 2, revoke: { holder in
                    await gate.hold(); return try await fence.revoke(holder)
                })
            let owners = try await directory.registrationOwners(scopes: [.account(senderUUID), .account(memberTwoUUID), .pair(senderUUID, memberTwoUUID), .stranger(memberTwoUUID)])
            let snapshot = try await PostgresV2DirectPolicySnapshotStore(database: control).register(
                pair: .init(sender: senderUUID, recipient: memberTwoUUID), owners: owners,
                registrationID: UUID(), roomID: UUID(), activationID: UUID(), roomOwnerEpoch: 1,
                endpoint: "room-b", durationSeconds: 20)
            try await fence.install(snapshot.holder)
            let mutation = try await policyDomainCommand(kind: kind, database: control)
            let submitted = Task {
                switch mutation {
                case .social(let command):
                    let store = PostgresV2SocialRelationshipStore(database: control, projectionDelivery: SuccessfulProjectionDelivery(),
                        authorizationCoordinator: legacy).usingPolicyOwners(directory)
                    return V2PolicyMutationResult.social(try await store.submitSocialOperation(command, now: Date()))
                case .strangerPreference(let command):
                    let store = PostgresV2AccountPreferenceOperationStore(database: control,
                        projectionDelivery: SuccessfulProjectionDelivery(), authorizationCoordinator: legacy).usingPolicyOwners(directory)
                    return V2PolicyMutationResult.preference(try await store.submit(command, now: Date()))
                case .disable(let command):
                    let service = try V2PostgresAccountDisableService(database: control,
                        operatorPrincipal: command.operatorPrincipal, authorizationCoordinator: legacy).usingPolicyOwners(directory)
                    return .disable(.init(try await service.disable(command.validatedCommand())))
                }
            }
            let deadline = ContinuousClock.now + .seconds(5)
            while !(await gate.entered), ContinuousClock.now < deadline { await Task.yield() }
            guard await gate.entered else {
                await gate.release(); _ = await submitted.result; await directory.shutdown()
                throw V2PolicyAuthorizationLifecycleError.corruptPersistence
            }
            do {
                #expect(try await policyDomainEffect(kind: kind, sql: sql) == 0)
                #expect(try await sql.raw("""
                    SELECT count(*)::bigint AS value FROM pg_stat_activity
                    WHERE state='idle in transaction' AND datname=current_database()
                        AND EXISTS (SELECT 1 FROM pg_locks l WHERE l.pid=pg_stat_activity.pid
                            AND l.relation=to_regclass('im_v2.policy_authorization_scopes'))
                    """).first(decoding: PolicyDomainCount.self)?.value == 0)
                // A held pair/account mutation cannot block a different account
                // and idle cache entries can be evicted without growing memory.
                let independent = try await directory.registrationOwners(scopes: [.account(UUID())])
                #expect(independent.count == 1)
                #expect(await directory.pressure().owners <= 4)
                #expect(await directory.pressure().roots == 1)
                submitted.cancel()
                await gate.release()
                let result = try await submitted.value
                switch (kind, result) {
                case ("block", .social(.receipt(let receipt))): #expect(receipt.outcome == .applied(.userBlock(isBlocked: true, revision: 1)))
                case ("remove", .social(.receipt(let receipt))): #expect(receipt.outcome == .applied(.relationship(state: .none, revision: 1)))
                case ("stranger", .preference(.receipt(let receipt))): #expect(receipt.outcome == .applied(value: .strangerMessage(.deny), revision: 1))
                case ("disable", .disable(let receipt)): #expect(receipt.kind == .disabled)
                default: Issue.record("Unexpected domain result")
                }
                #expect(try await policyDomainEffect(kind: kind, sql: sql) == 1)
                let key = mutation.operationKey
                #expect(try await sql.raw("SELECT revision AS value FROM im_v2.policy_authorization_scopes WHERE scope_key=\(bind: mutation.scope.key)").first(decoding: PolicyDomainCount.self)?.value == 2)
                #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.policy_authorization_outbox WHERE operation_key=\(bind: key)").first(decoding: PolicyDomainCount.self)?.value == 1)
                // Permanent reply survives retry; the business effect and its
                // account/pair version must not execute a second time.
                _ = try await directory.change(mutation)
                if case .disable(let command) = mutation, case .disable(let receipt) = result {
                    let service = try V2PostgresAccountDisableService(database: control,
                        operatorPrincipal: command.operatorPrincipal, authorizationCoordinator: legacy).usingPolicyOwners(directory)
                    #expect(try await service.disable(command.validatedCommand()) == .idempotent(disabledAt: receipt.disabledAt))
                }
                #expect(try await sql.raw("SELECT revision AS value FROM im_v2.policy_authorization_scopes WHERE scope_key=\(bind: mutation.scope.key)").first(decoding: PolicyDomainCount.self)?.value == 2)
                await #expect(throws: V2PolicyAuthorizationLifecycleError.staleVersion) { try await fence.install(snapshot.holder) }
                await directory.shutdown()
                #expect(await directory.pressure().roots == 0)
            } catch {
                await gate.release(); _ = await submitted.result; await directory.shutdown(); throw error
            }
        }
    }

    @Test("real policy effects roll back on outbox failure and recover from their frozen command")
    func policyOwnerDomainRollbackRecovery() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, roomDatabase, sql, _, _ in
            let journal = PostgresV2PolicyAuthorizationJournal(database: control)
            let legacy = V2DirectAuthorizationCoordinator(controlDatabase: control, ownerDatabases: [:])
            let dispatcher = PostgresV2PolicyMutationDispatcher(database: control,
                projectionDelivery: SuccessfulProjectionDelivery(), legacyAuthorization: legacy)
            let fence = PostgresV2RoomPolicyLeaseFence(database: roomDatabase)
            let directory = PostgresV2PolicyOwnerDirectory(journal: journal, dispatcher: dispatcher, revoke: { try await fence.revoke($0) })
            let mutation = try await policyDomainCommand(kind: "block", database: control)
            try await sql.raw("ALTER TABLE im_v2.policy_authorization_outbox ADD CONSTRAINT reject_domain_outbox CHECK (false) NOT VALID").run()
            do {
                _ = try await directory.change(mutation)
                Issue.record("Outbox failure did not abort the domain transaction")
            } catch {
                #expect(try await policyDomainEffect(kind: "block", sql: sql) == 0)
                #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.social_operation_receipts").first(decoding: PolicyDomainCount.self)?.value == 0)
                #expect(try await journal.pendingChanges().count == 1)
            }
            await directory.shutdown()
            try await sql.raw("ALTER TABLE im_v2.policy_authorization_outbox DROP CONSTRAINT reject_domain_outbox").run()
            try await sql.raw("UPDATE im_v2.policy_authorization_scopes SET owner_valid_until=clock_timestamp()-interval '1 second'").run()
            let recovered = PostgresV2PolicyOwnerDirectory(journal: journal, dispatcher: dispatcher, revoke: { try await fence.revoke($0) })
            do {
                try await recovered.recoverPending()
                #expect(try await policyDomainEffect(kind: "block", sql: sql) == 1)
                #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.social_operation_receipts").first(decoding: PolicyDomainCount.self)?.value == 1)
                #expect(try await journal.pendingChanges().isEmpty)
                try await sql.raw("ALTER TABLE im_v2.user_blocks RENAME TO policy_recovery_hidden_blocks").run()
                do {
                    let states = try await recovered.registrationStates(scopes: [mutation.scope])
                    let state = try #require(states.first)
                    guard case .pair(let facts) = state.facts else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
                    #expect(facts.blocked && state.owner.revision == 2 && state.deadline > .now)
                    try await sql.raw("ALTER TABLE im_v2.policy_recovery_hidden_blocks RENAME TO user_blocks").run()
                } catch {
                    try? await sql.raw("ALTER TABLE im_v2.policy_recovery_hidden_blocks RENAME TO user_blocks").run()
                    throw error
                }
                await recovered.shutdown()
            } catch { await recovered.shutdown(); throw error }
        }
    }

    @Test("stranger setting changes bypass executing friend SQL but removing friendship drains it")
    func policyFriendDependencyIsolation() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, roomDatabase, sql, roomSQL, _ in
            try await sql.raw("""
                INSERT INTO im_v2.user_relationships
                VALUES (LEAST(\(bind: senderUUID)::uuid,\(bind: memberTwoUUID)::uuid),
                    GREATEST(\(bind: senderUUID)::uuid,\(bind: memberTwoUUID)::uuid),
                    'accepted',\(bind: senderUUID),clock_timestamp())
                """).run()
            let fence = PostgresV2RoomPolicyLeaseFence(database: roomDatabase)
            let directory = PostgresV2PolicyOwnerDirectory(journal: .init(database: control),
                dispatcher: .init(database: control, projectionDelivery: SuccessfulProjectionDelivery(),
                    legacyAuthorization: .init(controlDatabase: control, ownerDatabases: [:])),
                revoke: { try await fence.revoke($0) })
            let scopes: [V2PolicyAuthorizationScope] = [.account(senderUUID), .account(memberTwoUUID), .pair(senderUUID, memberTwoUUID)]
            let pair = V2DirectSendControlPair(sender: senderUUID, recipient: memberTwoUUID)
            let reader = PostgresV2DirectPolicySnapshotStore(database: control)
            let states = try await directory.registrationStates(scopes: scopes)
            let snapshot = try await reader.register(pair: pair, states: states, registrationID: UUID(),
                roomID: UUID(), activationID: UUID(), roomOwnerEpoch: 1, endpoint: "room-b", durationSeconds: 20)
            #expect(snapshot.policy.isFriend && !snapshot.policy.allowsStrangers)
            #expect(snapshot.versions == .init(sender: 1, recipient: 1, pair: 1, stranger: nil))
            #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.policy_authorization_holders WHERE registration_id=\(bind: snapshot.holder.registrationID)").first(decoding: PolicyDomainCount.self)?.value == 3)
            try await fence.install(snapshot.holder)
            let held = PolicyStateSQLGate(), progress = PolicyFriendMutationProgress()
            let executing = Task {
                try await roomDatabase.transaction { transaction in
                    try await fence.requireActive(snapshot.holder, transaction: transaction)
                    let sql = try #require(transaction as? any SQLDatabase)
                    let pid = try #require(try await sql.raw("SELECT pg_backend_pid()::bigint AS value").first(decoding: PolicyDomainCount.self)).value
                    await held.hold(pid: pid)
                }
            }
            var changing: Task<V2PolicyMutationResult, any Error>?
            do {
                try await policyFriendObserve { await held.pid != nil }
                let setting = try await policyDomainCommand(kind: "stranger", database: control)
                let task = Task {
                    let result = try await directory.change(setting)
                    await progress.completed()
                    return result
                }
                changing = task
                try await policyFriendObserve { await progress.done }
                _ = try await task.value
                // The actual friend transaction still owns its SHARE fence.
                #expect(await held.pid != nil)
                #expect(try await roomSQL.raw("SELECT count(*)::bigint AS value FROM im_v2.room_policy_authorization_leases WHERE registration_id=\(bind: snapshot.holder.registrationID) AND NOT revoked").first(decoding: PolicyDomainCount.self)?.value == 1)
                let removed = try await policyDomainCommand(kind: "remove", database: control)
                let removal = Task { try await directory.change(removed) }; changing = removal
                let pid = try #require(await held.pid)
                try await policyFriendObserve {
                    try await roomSQL.raw("SELECT count(*)::bigint AS value FROM pg_stat_activity WHERE \(bind: pid)::integer=ANY(pg_blocking_pids(pid))").first(decoding: PolicyDomainCount.self)?.value ?? 0 > 0
                }
                #expect(try await policyDomainEffect(kind: "remove", sql: sql) == 0)
                await held.release(); try await executing.value
                _ = try await removal.value
                await #expect(throws: V2PolicyAuthorizationLifecycleError.staleVersion) {
                    try await reader.register(pair: pair, states: states, registrationID: UUID(), roomID: UUID(),
                        activationID: UUID(), roomOwnerEpoch: 1, endpoint: "room-b", durationSeconds: 20)
                }
                let current = try await directory.registrationStates(scopes: scopes + [.stranger(memberTwoUUID)])
                let replacement = try await reader.register(pair: pair, states: current, registrationID: UUID(),
                    roomID: UUID(), activationID: UUID(), roomOwnerEpoch: 1, endpoint: "room-b", durationSeconds: 20)
                #expect(!replacement.policy.isFriend && !replacement.policy.allowsStrangers)
                #expect(replacement.versions == .init(sender: 1, recipient: 1, pair: 2, stranger: 2))
                await #expect(throws: V2PolicyAuthorizationLifecycleError.invalidRequest) {
                    try await reader.register(pair: pair, states: current.filter { $0.owner.scope != .stranger(memberTwoUUID) },
                        registrationID: UUID(), roomID: UUID(), activationID: UUID(), roomOwnerEpoch: 1,
                        endpoint: "room-b", durationSeconds: 20)
                }
                await directory.shutdown()
            } catch {
                await held.release(); _ = await executing.result; _ = await changing?.result
                await directory.shutdown(); throw error
            }
        }
    }

    @Test("policy owners reuse complete memory facts and publish updated state after domain commit")
    func policyOwnerMemoryState() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, roomDatabase, sql, _, _ in
            let journal = PostgresV2PolicyAuthorizationJournal(database: control)
            let legacy = V2DirectAuthorizationCoordinator(controlDatabase: control, ownerDatabases: [:])
            let fence = PostgresV2RoomPolicyLeaseFence(database: roomDatabase)
            let directory = PostgresV2PolicyOwnerDirectory(journal: journal,
                dispatcher: .init(database: control, projectionDelivery: SuccessfulProjectionDelivery(), legacyAuthorization: legacy),
                revoke: { try await fence.revoke($0) })
            let scopes: [V2PolicyAuthorizationScope] = [.account(senderUUID), .account(memberTwoUUID), .pair(senderUUID, memberTwoUUID), .stranger(memberTwoUUID)]
            let pair = V2DirectSendControlPair(sender: senderUUID, recipient: memberTwoUUID)
            do {
                let states = try await directory.registrationStates(scopes: scopes)
                let reader = PostgresV2DirectPolicySnapshotStore(database: control)
                let baseline = try await reader.register(pair: pair, owners: states.map(\.owner), registrationID: UUID(),
                    roomID: UUID(), activationID: UUID(), roomOwnerEpoch: 1, endpoint: "room-b", durationSeconds: 20)
                let hidden = ["public_user_profiles", "special_accounts", "account_disables", "user_blocks",
                    "user_relationships", "user_stranger_message_preferences"]
                for table in hidden { try await sql.raw("ALTER TABLE im_v2.\(unsafeRaw: table) RENAME TO \(unsafeRaw: table + "_memory_hidden")").run() }
                // A database query against any control fact would now fail.
                let cached = try await directory.registrationStates(scopes: scopes)
                let installed = try await reader.register(pair: pair, states: cached, registrationID: UUID(),
                    roomID: UUID(), activationID: UUID(), roomOwnerEpoch: 1, endpoint: "room-b", durationSeconds: 20)
                #expect(installed.policy == baseline.policy)
                #expect(cached.map { $0.owner.revision } == states.map { $0.owner.revision })
                for table in hidden { try await sql.raw("ALTER TABLE im_v2.\(unsafeRaw: table + "_memory_hidden") RENAME TO \(unsafeRaw: table)").run() }
                _ = try await directory.change(policyDomainCommand(kind: "stranger", database: control))
                _ = try await directory.change(policyDomainCommand(kind: "block", database: control))
                let updated = try await directory.registrationStates(scopes: scopes)
                guard let recipient = updated.first(where: { $0.owner.scope.key == V2PolicyAuthorizationScope.stranger(memberTwoUUID).key }),
                      case .stranger(let account) = recipient.facts,
                      let relationship = updated.first(where: { $0.owner.scope.key == V2PolicyAuthorizationScope.pair(senderUUID, memberTwoUUID).key }),
                      case .pair(let social) = relationship.facts else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
                #expect(!account.allowsStrangers && recipient.owner.revision == 2)
                #expect(social.blocked && relationship.owner.revision == 2)
                await #expect(throws: V2PolicyAuthorizationLifecycleError.staleVersion) {
                    try await reader.register(pair: pair, states: states, registrationID: UUID(), roomID: UUID(),
                        activationID: UUID(), roomOwnerEpoch: 1, endpoint: "room-b", durationSeconds: 20)
                }
                let replacement = try await reader.register(pair: pair, states: updated, registrationID: UUID(), roomID: UUID(),
                    activationID: UUID(), roomOwnerEpoch: 1, endpoint: "room-b", durationSeconds: 20)
                #expect(replacement.policy.blocked && !replacement.policy.allowsStrangers)
                await directory.shutdown()
            } catch { await directory.shutdown(); throw error }
        }
    }

    @Test("coalesced owner state loads survive caller cancellation and shutdown waits for the actual SQL root")
    func policyOwnerStateLoadSettlement() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, _, sql, _, _ in
            let admission = V2DatabaseWorkAdmissionController(policy: .init(maximumForegroundWriteInFlight: 1,
                maximumInteractiveReadInFlight: 1, maximumSyncInFlight: 1,
                maximumForegroundWriteQueued: 1, maximumInteractiveReadQueued: 1,
                maximumSyncQueued: 2, timeout: .seconds(5)))
            let stateMetrics = V2SendOperationBatchMetrics()
            let journal = PostgresV2PolicyAuthorizationJournal(database: control, stateReadAdmission: admission,
                stateMetrics: stateMetrics)
            let ownerID = UUID(), scope = V2PolicyAuthorizationScope.account(senderUUID)
            _ = try await journal.acquireOwner(scope: scope, ownerID: ownerID, durationSeconds: 30)
            let owner = PostgresV2PolicyOwner(journal: journal, scope: scope, ownerID: ownerID,
                revoke: { _ in throw V2PolicyAuthorizationLifecycleError.invalidTarget }, apply: { _, _ in Data([1]) })
            let gate = PolicyStateSQLGate()
            let held = Task {
                try await control.transaction { transaction in
                    let sql = try #require(transaction as? any SQLDatabase)
                    _ = try await sql.raw("SELECT scope_key FROM im_v2.policy_authorization_scopes WHERE scope_key=\(bind: scope.key) FOR UPDATE").all()
                    let pid = try #require(try await sql.raw("SELECT pg_backend_pid()::bigint AS value").first(decoding: PolicyDomainCount.self)).value
                    await gate.hold(pid: pid)
                }
            }
            var loads: [Task<V2PolicyOwnerState, any Error>] = []
            var admissionHeld = false
            do {
                let deadline = ContinuousClock.now + .seconds(5)
                while await gate.pid == nil, .now < deadline { await Task.yield() }
                let pid = try #require(await gate.pid)
                guard case .admitted = await admission.acquire(.sync, callerDeadline: .now + .seconds(5)) else {
                    throw V2PolicyAuthorizationLifecycleError.busy
                }
                admissionHeld = true
                for _ in 0..<2 { loads.append(Task { try await owner.registrationState() }) }
                while await admission.snapshot().value(for: .sync).queued != 1, .now < deadline { await Task.yield() }
                try #require(await admission.snapshot().value(for: .sync).queued == 1)
                let waiting = stateMetrics.sendOperationBatchMetricsSnapshot().stages
                #expect(waiting[.policyOwnerStateDatabaseAdmission]?.inFlight == 1)
                #expect(waiting[.policyOwnerStateTransaction]?.count == 0)
                #expect(waiting[.policyOwnerStateTransaction]?.inFlight == 0)
                await admission.release(.sync)
                admissionHeld = false
                var blocked: Int64 = 0
                repeat {
                    blocked = try await sql.raw("SELECT count(*)::bigint AS value FROM pg_stat_activity WHERE \(bind: pid)::integer=ANY(pg_blocking_pids(pid))").first(decoding: PolicyDomainCount.self)?.value ?? 0
                    if blocked > 0 { break }; await Task.yield()
                } while .now < deadline
                #expect(blocked == 1)
                #expect(await owner.pressure().roots == 1)
                #expect(await admission.snapshot().value(for: .sync).inFlight == 1)
                let executing = stateMetrics.sendOperationBatchMetricsSnapshot().stages
                #expect(executing[.policyOwnerStateDatabaseAdmission]?.count == 1)
                #expect(executing[.policyOwnerStateDatabaseAdmission]?.inFlight == 0)
                #expect(executing[.policyOwnerStateTransaction]?.inFlight == 1)
                loads[0].cancel()
                let closing = Task { await owner.shutdown() }
                while !(await owner.pressure().closed), .now < deadline { await Task.yield() }
                #expect(await owner.pressure().closed)
                #expect(await owner.pressure().roots == 1)
                #expect(await admission.snapshot().value(for: .sync).inFlight == 1)
                #expect(stateMetrics.sendOperationBatchMetricsSnapshot().stages[.policyOwnerStateTransaction]?.inFlight == 1)
                await #expect(throws: V2PolicyAuthorizationLifecycleError.closed) { try await owner.registrationState() }
                await gate.release(); try await held.value
                let first = try await loads[0].value, second = try await loads[1].value
                #expect(first.owner == second.owner && first.facts == second.facts)
                await closing.value
                #expect(await owner.pressure().roots == 0)
                let finished = await admission.snapshot().value(for: .sync)
                #expect(finished.inFlight == 0 && finished.queued == 0)
                let settled = stateMetrics.sendOperationBatchMetricsSnapshot().stages
                for stage in [V2SendOperationStage.policyOwnerStateDatabaseAdmission, .policyOwnerStateTransaction, .policyOwnerStateFacts] {
                    #expect(settled[stage]?.count == 1 && settled[stage]?.inFlight == 0)
                }
            } catch {
                if admissionHeld { await admission.release(.sync) }
                await gate.release(); _ = await held.result
                for load in loads { _ = await load.result }
                await owner.shutdown(); throw error
            }
        }
    }

    private func policyDomainCommand(kind: String, database: any Database) async throws -> V2DurablePolicyMutation {
        let recipient = UserID(uuid: memberTwoUUID)
        switch kind {
        case "block", "remove":
            let store = PostgresV2SocialRelationshipStore(database: database, projectionDelivery: SuccessfulProjectionDelivery())
            return .social(try await store.freezeSocialFixture(actorUserID: senderID, targetUserID: recipient,
                operation: kind == "block" ? .userBlock(.init(uuid: UUID())) : .relationship(.init(uuid: UUID())),
                action: kind == "block" ? .userBlock(.block) : .relationship(.remove), now: Date()))
        case "stranger":
            let store = PostgresV2AccountPreferenceOperationStore(database: database,
                projectionDelivery: SuccessfulProjectionDelivery(), authorizationCoordinator: .init(controlDatabase: database, ownerDatabases: [:]))
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
private struct AtomicPolicyStateClock: Decodable { let value: Date }
private actor PolicyDomainRevocationGate {
    private(set) var entered = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

/// Test transport around the real database: hold a cold transaction result
/// only after its COMMIT future succeeds. Mutations and SQL still run normally.
private final class PolicyColdResultDatabase: Database, SQLDatabase, Sendable {
    let underlying: any Database
    let sql: any SQLDatabase
    let gate: PolicyColdResultGate
    var context: DatabaseContext { underlying.context }
    var inTransaction: Bool { underlying.inTransaction }
    var dialect: any SQLDialect { sql.dialect }

    init(underlying: any Database, gate: PolicyColdResultGate) throws {
        self.underlying = underlying
        self.sql = try #require(underlying as? any SQLDatabase)
        self.gate = gate
    }
    func transaction<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        let completed = underlying.transaction(closure)
        return completed.flatMap { result in
            guard let state = result as? V2PolicyOwnerState else { return completed }
            return self.gate.hold(state, eventLoop: self.eventLoop).flatMap { completed }
        }
    }
    func withConnection<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        underlying.withConnection(closure)
    }
    func execute(query: DatabaseQuery, onOutput: @escaping @Sendable (any DatabaseOutput) -> Void) -> EventLoopFuture<Void> {
        underlying.execute(query: query, onOutput: onOutput)
    }
    func execute(schema: DatabaseSchema) -> EventLoopFuture<Void> { underlying.execute(schema: schema) }
    func execute(enum databaseEnum: DatabaseEnum) -> EventLoopFuture<Void> { underlying.execute(enum: databaseEnum) }
    func execute(sql query: any SQLExpression, _ onRow: @escaping @Sendable (any SQLRow) -> Void) -> EventLoopFuture<Void> {
        sql.execute(sql: query, onRow)
    }
    func withSession<R>(_ closure: @escaping @Sendable (any SQLDatabase) async throws -> R) async throws -> R {
        try await sql.withSession(closure)
    }
}

private final class PolicyColdResultGate: Sendable {
    private struct State: Sendable {
        var captured: V2PolicyOwnerState?
        var promise: EventLoopPromise<Void>?
        var released = false
    }
    private let state = Mutex(State())
    var captured: V2PolicyOwnerState? { state.withLock { $0.captured } }
    func hold(_ value: V2PolicyOwnerState, eventLoop: any EventLoop) -> EventLoopFuture<Void> {
        state.withLock {
            guard !$0.released, $0.captured == nil else { return eventLoop.makeSucceededVoidFuture() }
            let promise = eventLoop.makePromise(of: Void.self)
            $0.captured = value
            $0.promise = promise
            return promise.futureResult
        }
    }
    func release() {
        let promise = state.withLock {
            $0.released = true
            let promise = $0.promise
            $0.promise = nil
            return promise
        }
        promise?.succeed(())
    }
}

private actor PolicyStateSQLGate {
    private(set) var pid: Int64?
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    func hold(pid: Int64) async {
        self.pid = pid
        if !released { await withCheckedContinuation { waiter = $0 } }
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
