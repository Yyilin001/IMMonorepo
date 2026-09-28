import Foundation
import IMV2Core
import SQLKit
import Testing
@testable import IMV2Server

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("forward parent handoff fences cancellation and preserves original bounded progress")
    func permanentForwardPlanHandoff() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let store = PostgresV2ForwardPlanStore(database: database, clock: { now })
            func command(operation: MessageForwardOperationID = .init(uuid: UUID()), deadline: UInt64? = nil) throws -> V2ForwardPlanOperationCommand {
                try .init(actorUserID: senderID, command: .init(operationID: operation,
                    sources: (0..<21).map { _ in try .init(roomID: roomID, messageID: .init(uuid: UUID()), revision: .init(1)) },
                    targetRoomIDs: [roomID]), firstSubmissionDeadlineMilliseconds: deadline ?? UInt64(now.timeIntervalSince1970*1000)+60_000)
            }
            let frozen = try command()
            guard case .processing(let pending) = try await store.submit(frozen) else { throw CancellationError() }
            #expect(pending.executionState == .waitingToStart && pending.children.count == 2)
            let claimed = try await store.claimNext(frozen)
            #expect(claimed?.operationID == (try frozen.childCommand(index: 0).operationID))
            guard case .processing(let stillStarted) = try await store.recover(.init(command: frozen, action: .closeIfUnstarted)) else { throw CancellationError() }
            #expect(stillStarted.executionState == .processing)
            guard case .processing(let cancelling) = try await store.recover(.init(command: frozen, action: .cancelRemaining)) else { throw CancellationError() }
            #expect(cancelling.executionState == .cancelling)
            if case .resolved(let receipt) = cancelling.children[1].state { #expect(receipt.outcome == .cancelledBeforeStart) } else { Issue.record("pending child not cancelled") }
            #expect(try await store.claimNext(frozen) == nil)
            let pairs = try frozen.childCommand(index: 0).sources.enumerated().map { offset, source in
                try V2ForwardPlanItemResult(sourceMessageID: source.messageID, targetRoomID: roomID,
                    outcome: .accepted(.init(messageID: .init(uuid: UUID()), roomSequence: UInt64(offset+1))))
            }
            let child = try V2ForwardPlanChildReceipt(parentIdentity: frozen.identity, parentFingerprint: frozen.fingerprint,
                index: 0, operationID: frozen.childCommand(index: 0).operationID, outcome: .completed(pairs), resolvedAtMilliseconds: UInt64(now.timeIntervalSince1970*1000))
            guard case .receipt(let resolved) = try await store.record(child, command: frozen) else { throw CancellationError() }
            #expect(resolved.validates(command: frozen))
            #expect(try await store.recover(.init(command: frozen, action: .query)) == .receipt(resolved))
            #expect(try await store.submit(frozen) == .receipt(resolved))
            let closed = try command()
            guard case .receipt(let tombstone) = try await store.recover(.init(command: closed, action: .closeIfUnstarted)) else { throw CancellationError() }
            #expect(tombstone.receipt.outcome == .closedBeforeStart && tombstone.validates(command: closed))
            #expect(try await store.submit(closed) == .receipt(tombstone))
            let changed = try command(operation: closed.operationID)
            #expect(try await store.submit(changed) == .fingerprintConflict)
            let expired = try command(deadline: UInt64(now.timeIntervalSince1970*1000)-1)
            guard case .receipt(let expiry) = try await store.submit(expired) else { throw CancellationError() }
            #expect(expiry.receipt.outcome == .rejected(.expiredUnsubmitted))
            let waiting=try command()
            _=try await store.submit(waiting)
            let later=PostgresV2ForwardPlanStore(database:database,clock:{now.addingTimeInterval(61)})
            #expect(try await later.claimNext(waiting)==nil)
            guard case .receipt(let delayedExpiry)=try await later.recover(.init(command:waiting,action:.query)) else { throw CancellationError() }
            #expect(delayedExpiry.receipt.outcome == .rejected(.expiredUnsubmitted))
            let service=V2ForwardPlanService(store:store,reconcile:{_,_,_ in nil},clock:{now})
            var active:[V2ForwardPlanOperationCommand]=[]
            for _ in 0..<64 { let queued=try command();_=try await service.submit(queued);active.append(queued) }
            let overflow=try command()
            guard case .deferred(let hint)=try await service.submit(overflow) else { throw CancellationError() }
            #expect(hint.reason == .admissionUnavailable && hint.retryAfterMilliseconds==5000)
            let overflowIdentity=try overflow.identity,overflowFingerprint=try overflow.fingerprint
            #expect(hint.identity == overflowIdentity && hint.fingerprint == overflowFingerprint)
            _=try await service.recover(.init(command:active[0],action:.closeIfUnstarted))
            guard case .processing=try await service.submit(overflow) else { throw CancellationError() }
            await #expect(throws: (any Error).self) { try await sql.raw("DELETE FROM im_v2.forward_plan_operations WHERE actor_user_id=\(bind:senderUUID)").run() }
            await #expect(throws: (any Error).self) { try await sql.raw("UPDATE im_v2.forward_plan_operations SET resolved_json=NULL WHERE operation_id=\(bind:frozen.operationID.uuidValue!)").run() }
        }
    }
}
