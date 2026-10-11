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
    @Test("periodic shutdown retains delivery and lost acknowledgements replay in scope revision order")
    func retainedDeliveryAndReplay() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let journal = PostgresV2PolicyAuthorizationJournal(database: database, schema: schema)
            let scope = V2PolicyAuthorizationScope.account(UUID()), ownerID = UUID()
            for i in 0..<2 {
                _ = try await journal.changeCurrentPolicy(scope: scope, ownerID: ownerID, durationSeconds: 30,
                    operationKey: "publication-\(i)", fingerprint: Data(repeating: UInt8(i + 1), count: 32),
                    commandJSON: "{}", apply: { _, _ in Data([1]) })
            }
            try await sql.raw("CREATE TABLE \(unsafeRaw: schema).policy_test_sink(operation_key text PRIMARY KEY, revision bigint NOT NULL)").run()
            let owners = PostgresV2PolicyOwnerDirectory(journal: journal,
                dispatcher: .init(database: database, projectionDelivery: SuccessfulProjectionDelivery()),
                ownsScope: { _ in false })
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
