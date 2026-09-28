import Foundation
import GRDB
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Bounded durable backlog")
struct V2OperationBacklogTests {
    @Test func freshInteractionStartsWhileOldBacklogIOOccupiesRecoverySlots() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = UserID(uuid: UUID()), now = Date()
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appendingPathComponent("state.sqlite"),
            installationBinding: .init(value: UUID()), userID: user)
        try await store.databasePool.write { db in
            for index in 0..<1_999 {
                _ = try GRDBV2LocalSyncStore.insertOperationWork(.init(intentID: UUID(), identity: .init(accountID: user,
                    scope: .account(user), operation: .profileUpdate(.init(uuid: UUID()))),
                    fingerprint: .init(kind: .profileUpdate, fields: [.init("value", .text(String(index)))]),
                    orderingKey: "old-\(index)", payloadBytes: 16, admissionDeadline: nil), now: now.addingTimeInterval(-120), db: db)
            }
        }
        let interactiveID = UUID()
        let dispatcher = V2OperationWorkDispatcher(store: store, handlers: [.init(kind: .profileUpdate) { claim in
            if claim.work.id == interactiveID {
                try await store.completeOperationWork(.init(identity: claim.work.identity, fingerprint: claim.work.fingerprint,
                    state: .committed, receipt: "original interactive proof"), now: now)
            } else { try await Task.sleep(for: .seconds(60)) }
        }])
        let task = Task { try await dispatcher.run() }
        do {
            let deadline = ContinuousClock.now + .seconds(10)
            while true {
                let claimed = try await store.databasePool.read { db in
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_operation_work WHERE scheduling_state='claimed'") ?? 0
                }
                if claimed == 5 { break }
                guard ContinuousClock.now < deadline else { throw V2OperationWorkError.invalidTransition }
                try await Task.sleep(for: .milliseconds(10))
            }
            // MIN(next_action_at) stays the old backlog timestamp. This insertion
            // must still wake the owner and use its reserved domain slot.
            try await store.databasePool.write { db in
                _ = try GRDBV2LocalSyncStore.insertOperationWork(.init(id: interactiveID, intentID: UUID(),
                    identity: .init(accountID: user, scope: .account(user), operation: .profileUpdate(.init(uuid: UUID()))),
                    fingerprint: .init(kind: .profileUpdate, fields: [.init("value", .text("new"))]),
                    orderingKey: "new-interaction", payloadBytes: 16, admissionDeadline: nil), now: now, db: db)
            }
            while try await store.operationWork(id: interactiveID)?.execution != .committed {
                guard ContinuousClock.now < deadline else { throw V2OperationWorkError.invalidTransition }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(try await store.operationWork(id: interactiveID)?.attemptCount == 1)
            await dispatcher.stopAndDrain(); try await task.value
            let claimed = try await store.databasePool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_operation_work WHERE scheduling_state='claimed'") ?? 0
            }
            #expect(claimed == 0)
            try await store.close()
        } catch {
            await dispatcher.stopAndDrain(); _ = await task.result
            try? await store.close(); throw error
        }
    }

    @Test func twoThousandRowsDrainWithoutUnboundedTasksOrKeyOverlap() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = UserID(uuid: UUID()), now = Date()
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appendingPathComponent("state.sqlite"),
            installationBinding: .init(value: UUID()), userID: user)
        // Exercise the shared execution journal, not domain business semantics.
        // Twenty independent keys each contain one hundred ordered operations.
        try await store.databasePool.write { db in
            for index in 0..<2_000 {
                let input = try V2NewOperationWork(intentID: UUID(), identity: .init(accountID: user,
                    scope: .account(user), operation: .profileUpdate(.init(uuid: UUID()))),
                    fingerprint: .init(kind: .profileUpdate, fields: [.init("value", .text(String(index)))]),
                    orderingKey: "backlog-\(index % 20)", payloadBytes: 16, admissionDeadline: nil)
                _ = try GRDBV2LocalSyncStore.insertOperationWork(input, now: now, db: db)
            }
        }
        let probe = BacklogProbe()
        let dispatcher = V2OperationWorkDispatcher(store: store, handlers: [.init(kind: .profileUpdate) { claim in
            await probe.begin(claim.work)
            await Task.yield()
            await probe.endIO(claim.work)
            try await store.completeOperationWork(.init(identity: claim.work.identity, fingerprint: claim.work.fingerprint,
                state: .committed, receipt: "verified fixture"), now: now)
            await probe.finish(claim.work)
        }], maximumInFlight: 6, now: { now })
        let task = Task { try await dispatcher.run() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while await probe.completedCount < 2_000, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        await dispatcher.stopAndDrain()
        try await task.value
        let result = await probe.result()
        #expect(result.completed == 2_000)
        #expect(result.maximumActive >= 1 && result.maximumActive <= 6)
        #expect(!result.invalidOrder)
        #expect(!result.overlap)
        #expect(!result.duplicate)
        let totals = try await store.databasePool.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS total,
                  SUM(execution_state='committed' AND scheduling_state='finished' AND attempt_count=1) AS valid,
                  SUM(claim_id IS NOT NULL) AS claimed FROM v2_operation_work
                """)!
            return (row["total"] as Int, row["valid"] as Int, row["claimed"] as Int)
        }
        #expect(totals.0 == 2_000)
        #expect(totals.1 == 2_000)
        #expect(totals.2 == 0)
        try await store.close()
    }
}

private actor BacklogProbe {
    struct Result: Sendable {
        let completed: Int, maximumActive: Int
        let invalidOrder: Bool, overlap: Bool, duplicate: Bool
    }
    private var active = Set<UUID>()
    private var keys = Set<String>()
    private var completed = Set<UUID>()
    private var lastSequence: [String: Int64] = [:]
    private var maximumActive = 0
    private var invalidOrder = false, overlap = false, duplicate = false
    var completedCount: Int { completed.count }
    func begin(_ work: V2OperationWork) {
        if !keys.insert(work.orderingKey).inserted { overlap = true }
        if !active.insert(work.id).inserted || completed.contains(work.id) { duplicate = true }
        if let previous = lastSequence[work.orderingKey], previous >= work.localSequence { invalidOrder = true }
        lastSequence[work.orderingKey] = work.localSequence
        maximumActive = max(maximumActive, active.count)
    }
    func endIO(_ work: V2OperationWork) {
        active.remove(work.id); keys.remove(work.orderingKey)
    }
    func finish(_ work: V2OperationWork) { completed.insert(work.id) }
    func result() -> Result {
        .init(completed: completed.count, maximumActive: maximumActive,
            invalidOrder: invalidOrder, overlap: overlap, duplicate: duplicate)
    }
}
