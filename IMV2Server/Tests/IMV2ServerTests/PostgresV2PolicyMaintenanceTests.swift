import Foundation
import FluentKit
import IMV2Core
import IMV2ServerContracts
@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("maintenance scans past foreign backlog and isolates a corrupt local command")
    func policyMaintenanceRecoversBeyondForeignBacklog() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, roomDatabase, sql, _, _ in
            let journal = PostgresV2PolicyAuthorizationJournal(database: control)
            for i in 0..<131 {
                let lease = try await journal.acquireOwner(scope: .account(UUID()), ownerID: UUID(), durationSeconds: 30)
                _ = try await journal.beginChange(owner: lease, operationKey: "foreign-\(i)",
                    fingerprint: Data(repeating: 1, count: 32), commandJSON: "{}")
            }
            let poisoned = try await journal.acquireOwner(scope: .account(memberTwoUUID), ownerID: UUID(), durationSeconds: 30)
            _ = try await journal.beginChange(owner: poisoned, operationKey: "corrupt-local", fingerprint: Data(repeating: 2, count: 32), commandJSON: "{}")
            let social = PostgresV2SocialRelationshipStore(database: control, projectionDelivery: SuccessfulProjectionDelivery())
            let command = try await social.freezeSocialFixture(actorUserID: senderID, targetUserID: .init(uuid: memberTwoUUID),
                operation: .userBlock(.init(uuid: UUID())), action: .userBlock(.block), now: Date())
            let mutation = V2DurablePolicyMutation.social(command)
            let lease = try await journal.acquireOwner(scope: mutation.scope, ownerID: UUID(), durationSeconds: 30)
            _ = try await journal.beginChange(owner: lease, operationKey: mutation.operationKey,
                fingerprint: mutation.fingerprint, commandJSON: mutation.json)
            try await sql.raw("UPDATE im_v2.policy_authorization_scopes SET owner_valid_until=clock_timestamp()-interval '1 second'").run()
            try await sql.raw("CREATE TABLE im_v2.policy_test_notifications(operation_key text PRIMARY KEY, revision bigint NOT NULL)").run()
            try await sql.raw("CREATE TABLE im_v2.policy_test_projection_sink(user_id uuid NOT NULL, event_id text NOT NULL, PRIMARY KEY(user_id,event_id))").run()
            let receiver = DurablePolicyProjectionReceiver(database: control)
            let effects = PostgresV2PolicyCommittedEffectsPublisher(journal: journal, delivery: receiver)
            let owned = Set([mutation.scope.key, V2PolicyAuthorizationScope.account(memberTwoUUID).key])
            let fence = PostgresV2RoomPolicyLeaseFence(database: roomDatabase)
            let owners = PostgresV2PolicyOwnerDirectory(journal: journal,
                dispatcher: .init(database: control, projectionDelivery: SuccessfulProjectionDelivery(),
                    legacyAuthorization: .init(controlDatabase: control, ownerDatabases: [:])),
                ownsScope: { owned.contains($0) }, revoke: { try await fence.revoke($0) })
            let publisher = PostgresV2PolicyOutboxPublisher(journal: journal, limit: 2, scanLimit: 64,
                ownsScope: { owners.acceptsScope($0) }, deliver: { notification in
                    try await effects.publish(notification)
                    try await sql.raw("INSERT INTO im_v2.policy_test_notifications VALUES(\(bind: notification.operationKey),\(bind: notification.revision)) ON CONFLICT DO NOTHING").run()
                })
            let worker = V2PolicyMaintenanceWorker(owners: owners, publisher: publisher, limit: 2, scanLimit: 64)
            func appendForeign(_ batch: Int) async throws {
                try await sql.raw("""
                    WITH input AS (SELECT gen_random_uuid() AS id,i FROM generate_series(1,64) i),
                    scopes AS (
                        INSERT INTO im_v2.policy_authorization_scopes(scope_key,owner_id,owner_epoch,owner_valid_until,pending_change_key)
                        SELECT 'account:'||id::text,gen_random_uuid(),1,clock_timestamp()+interval '30 seconds',
                            'arrival-'||\(bind: batch)::text||'-'||i::text FROM input
                        RETURNING scope_key,pending_change_key
                    ) INSERT INTO im_v2.policy_authorization_changes(operation_key,scope_key,fingerprint,command,expected_revision,next_revision)
                    SELECT pending_change_key,scope_key,decode(repeat('01',32),'hex'),'{}'::jsonb,1,2 FROM scopes
                    """).run()
            }
            do {
                for batch in 0..<2 {
                    let report = try await worker.runOnce()
                    #expect(report.recovery?.scanned == 64 && report.recovery?.attempted == 0)
                    try await appendForeign(batch)
                }
                let recovered = try await worker.runOnce()
                #expect(recovered.recovery?.completed == 1 && recovered.recovery?.failed == 1 && recovered.recovery?.exhausted == true)
                try await appendForeign(2)
                #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.user_blocks WHERE blocker_user_id=\(bind: senderUUID) AND blocked_user_id=\(bind: memberTwoUUID)").first(decoding: PolicyMaintenanceCount.self)?.value == 1)
                #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.policy_authorization_outbox WHERE published_at IS NOT NULL").first(decoding: PolicyMaintenanceCount.self)?.value == 0)
                await receiver.allowDelivery()
                let notified = try await worker.runOnce()
                #expect(notified.publication?.published == 1)
                try await appendForeign(3)
                _ = try await worker.runOnce()
                try await appendForeign(4)
                let retryCorrupt = try await worker.runOnce()
                #expect(retryCorrupt.recovery?.failed == 1)
                #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.policy_test_projection_sink").first(decoding: PolicyMaintenanceCount.self)?.value == 2)
                #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.policy_test_notifications").first(decoding: PolicyMaintenanceCount.self)?.value == 1)
                #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.policy_authorization_changes WHERE NOT committed").first(decoding: PolicyMaintenanceCount.self)?.value == 452)
                #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.policy_authorization_outbox WHERE published_at IS NOT NULL").first(decoding: PolicyMaintenanceCount.self)?.value == 1)
                await #expect(throws: V2PolicyAuthorizationLifecycleError.invalidTarget) {
                    try await journal.markPublished(.init(operationKey: mutation.operationKey, scopeKey: mutation.scope.key, revision: 999))
                }
                await worker.shutdown(); await owners.shutdown()
            } catch { await worker.shutdown(); await owners.shutdown(); throw error }
        }
    }
}

@Suite("policy maintenance delivery lifecycle", .serialized, .timeLimit(.minutes(2)))
struct PostgresV2PolicyMaintenanceLifecycleTests {
    @Test("periodic shutdown retains delivery and lost acknowledgements replay in scope revision order")
    func retainedDeliveryAndReplay() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let journal = PostgresV2PolicyAuthorizationJournal(database: database, schema: schema)
            let scope = V2PolicyAuthorizationScope.account(UUID()), ownerID = UUID()
            for i in 0..<2 {
                let owner = try await journal.acquireOwner(scope: scope, ownerID: ownerID, durationSeconds: 30)
                _ = try await journal.beginChange(owner: owner, operationKey: "publication-\(i)",
                    fingerprint: Data(repeating: UInt8(i + 1), count: 32), commandJSON: "{}")
                _ = try await journal.commitChange(owner: owner, operationKey: "publication-\(i)") { _, _ in Data([1]) }
            }
            try await sql.raw("CREATE TABLE \(unsafeRaw: schema).policy_test_sink(operation_key text PRIMARY KEY, revision bigint NOT NULL)").run()
            let owners = PostgresV2PolicyOwnerDirectory(journal: journal,
                dispatcher: .init(database: database, projectionDelivery: SuccessfulProjectionDelivery(),
                    legacyAuthorization: .init(controlDatabase: database, ownerDatabases: [:])),
                ownsScope: { _ in false }, revoke: { _ in throw V2PolicyAuthorizationLifecycleError.invalidTarget })
            let gate = PolicyNotificationGate()
            let firstPublisher = PostgresV2PolicyOutboxPublisher(journal: journal, ownsScope: { _ in true }, deliver: { notification in
                try await sql.raw("INSERT INTO \(unsafeRaw: schema).policy_test_sink VALUES(\(bind: notification.operationKey),\(bind: notification.revision)) ON CONFLICT DO NOTHING").run()
                await gate.hold()
                throw PolicyNotificationFailure.ackLost
            })
            let worker = V2PolicyMaintenanceWorker(owners: owners, publisher: firstPublisher, interval: .milliseconds(10))
            var closing: Task<Void, Never>?
            do {
                try await worker.start(); try await worker.start()
                try await eventually { await gate.entered }
                let running = await worker.pressure()
                #expect(running.active && running.started)
                let close = Task { await worker.shutdown() }; closing = close
                try await eventually { await worker.pressure().closed }
                #expect(await worker.pressure().active)
                #expect(await firstPublisher.pressure().active)
                #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).policy_authorization_outbox WHERE published_at IS NOT NULL").first(decoding: PolicyMaintenanceCount.self)?.value == 0)
                #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).policy_test_sink").first(decoding: PolicyMaintenanceCount.self)?.value == 1)
                await gate.release(); await close.value
                let stopped = await worker.pressure()
                #expect(!stopped.active && !stopped.started)
                let stoppedPublisher = await firstPublisher.pressure()
                #expect(stoppedPublisher.closed && !stoppedPublisher.active)
                await #expect(throws: V2PolicyAuthorizationLifecycleError.closed) { try await worker.runOnce() }
                let retry = PostgresV2PolicyOutboxPublisher(journal: journal, ownsScope: { _ in true }, deliver: { notification in
                    try await sql.raw("INSERT INTO \(unsafeRaw: schema).policy_test_sink VALUES(\(bind: notification.operationKey),\(bind: notification.revision)) ON CONFLICT DO NOTHING").run()
                })
                do {
                    let replay = try await retry.runOnce()
                    #expect(replay.published == 1)
                    #expect(try await sql.raw("SELECT revision AS value FROM \(unsafeRaw: schema).policy_authorization_outbox WHERE published_at IS NULL").first(decoding: PolicyMaintenanceCount.self)?.value == 3)
                    #expect(try await retry.runOnce().published == 1)
                    #expect(try await retry.runOnce().published == 0)
                    #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).policy_test_sink").first(decoding: PolicyMaintenanceCount.self)?.value == 2)
                    await retry.shutdown()
                } catch { await retry.shutdown(); throw error }
                await owners.shutdown()
            } catch {
                await gate.release(); await closing?.value; await worker.shutdown(); await owners.shutdown(); throw error
            }
        }
    }
    private func eventually(_ predicate: @Sendable () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while .now < deadline { if try await predicate() { return }; await Task.yield() }
        throw V2PolicyAuthorizationLifecycleError.notDrained
    }
}
private struct PolicyMaintenanceCount: Decodable { let value: Int64 }
private enum PolicyNotificationFailure: Error { case ackLost }
private actor PolicyNotificationGate {
    private(set) var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    func hold() async {
        entered = true
        if !released { await withCheckedContinuation { waiter = $0 } }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

private actor DurablePolicyProjectionReceiver: V2UserShardProjectionDelivering {
    let database: any Database
    private var allowed = false
    init(database: any Database) { self.database = database }
    func allowDelivery() { allowed = true }
    func deliverToCurrentShard(userID: UserID, sourceEventID: EventID, projectionKinds: Set<String>) async throws -> UInt64? {
        guard allowed else { return nil }
        guard let sql = database as? any SQLDatabase else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
        try await sql.raw("INSERT INTO im_v2.policy_test_projection_sink VALUES(\(bind: userID.uuidValue!),\(bind: sourceEventID.rawValue)) ON CONFLICT DO NOTHING").run()
        return 1
    }
}
