import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Message mutation interruption", .serialized)
struct V2MessageMutationCancellationTests {
    @Test("interrupted submission stays unknown with the exact frozen withdrawal")
    func interruptedWithdrawal() async throws {
        let f=try V2MutationTestFixture(kind:"cancel");defer { f.remove() }
        let payload=try f.payload(withdraw:true),id=try await f.service.enqueue(payload)
        await #expect(throws:CancellationError.self) { try await f.service.execute(f.claim(id)) }
        let work=try #require(try await f.store.operationWork(id:id))
        #expect(work.execution == .awaitingConfirmation && work.nextAction == .reconcile)
        #expect(try await f.store.messageMutationPayload(workID:id)==payload)
        try await f.store.close()
    }
    @Test("long server cooldown survives an explicit continuation")
    func durableCooldown() async throws {
        let f=try V2MutationTestFixture(kind:"cooldown");defer { f.remove() }
        let id=try await f.service.enqueue(f.payload())
        try await f.service.execute(f.claim(id))
        let floor=f.remote.serverFloor
        #expect(abs(try #require(try await f.store.operationWork(id:id)).nextActionAt.timeIntervalSince(floor)) < 0.001)
        #expect(try await f.store.operationWork(id:id)?.scheduling == .needsAttention)
        try await f.service.resumeConfirmation(workID:id)
        #expect(abs(try #require(try await f.store.operationWork(id:id)).nextActionAt.timeIntervalSince(floor)) < 0.001)
        #expect(try await f.store.dueOperationWork(now:Date(),kinds:[.editMessage]).isEmpty)
        try await f.store.close()
    }
}
