import Foundation
import Testing
import IMV2Core
@testable import IMV2ClientKit

@Suite("Reaction durable admission and recovery")
struct V2MessageReactionAdmissionTests {
    @Test("expired unfrozen draft never performs baseline or submission I/O")
    func expiredDraft() async throws {
        let f=try ReactionWorkFixture();defer { f.remove() }
        _ = try await f.store.enqueueReactionIntent(accountID:f.account,roomID:f.room,messageID:f.message,reaction:"👍",targetState:.present,now:Date().addingTimeInterval(-90_000))
        #expect(try await f.service.prepareNextIntent())
        #expect(await f.remote.calls==0)
        #expect(try await f.store.dueOperationWork(now:.distantFuture,kinds:[.reaction]).isEmpty)
        try await f.store.close()
    }
    @Test("a full shared reservation transfers into frozen work without a second admission")
    func fullCapacity() async throws {
        let f=try ReactionWorkFixture();defer { f.remove() }
        _ = try await f.store.enqueueReactionIntent(accountID:f.account,roomID:f.room,messageID:f.message,reaction:"👍",targetState:.present,limits:.init(maximumActiveCount:1))
        await #expect(throws:V2OperationWorkError.capacityExceeded) {
            try await f.store.enqueueReactionIntent(accountID:f.account,roomID:f.room,messageID:.init(uuid:UUID()),reaction:"👍",targetState:.present,limits:.init(maximumActiveCount:1))
        }
        #expect(try await f.service.prepareNextIntent())
        #expect(try await f.store.dueOperationWork(now:.now,kinds:[.reaction]).count==1)
        try await f.store.close()
    }
    @Test("cancelling a page before saving never enters the durable journal")
    func cancelled() async throws {
        let f=try ReactionWorkFixture();defer { f.remove() }
        let task=Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await f.service.enqueue(roomID:f.room,messageID:f.message,reaction:"👍",targetState:.present)
        }
        await #expect(throws:CancellationError.self) { _ = try await task.value }
        #expect(try await f.store.nextReactionDraft(now:.distantFuture)==nil)
        try await f.store.close()
    }
}
