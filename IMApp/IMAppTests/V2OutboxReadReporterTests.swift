import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing
@testable import IMApp

@MainActor @Suite("Read reporter durable admission",.serialized)
struct V2OperationReadReporterTests {
    @Test("a cancelled page task admits nothing and a successful report only queues local max")
    func cancelledBeforeAdmission() async throws {
        let directory=FileManager.default.temporaryDirectory.appending(path:"read-reporter-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let account=UserID(uuid:UUID()), room=RoomID(uuid:UUID())
        let store=try GRDBV2LocalSyncStore(databaseURL:directory.appending(path:"state.sqlite"),installationBinding:.init(value:UUID()),userID:account)
        let client=NoPageReadIO(), service=V2ReadReceiptOperationService(accountID:account,store:store,client:client)
        let reporter=V2OperationConversationReadReporter(service:service)
        let task=Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await reporter.recordReadThrough(roomID:room.rawValue,roomSequence:1)
        }
        await #expect(throws:CancellationError.self) { _ = try await task.value }
        #expect(try await store.roomReadWatermark(roomID:room) == nil)
        #expect(try await reporter.recordReadThrough(roomID:room.rawValue,roomSequence:1) == .queuedForRetry)
        #expect(try await reporter.recordReadThrough(roomID:room.rawValue,roomSequence:1) == .alreadyRecorded)
        #expect(try await store.roomReadWatermark(roomID:room) == 1)
        #expect(await client.calls == 0)
        try await store.close()
    }
    @Test("leaving the page after enqueue preserves a coalesced receipt through cold startup")
    func pageExitPreservesReading() async throws {
        let directory=FileManager.default.temporaryDirectory.appending(path:"read-reporter-cold-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let account=UserID(uuid:UUID()), room=RoomID(uuid:UUID()), binding=V2LocalInstallationBinding(value:UUID())
        let url=directory.appending(path:"state.sqlite"), client=NoPageReadIO()
        let store=try GRDBV2LocalSyncStore(databaseURL:url,installationBinding:binding,userID:account)
        let reporter=V2OperationConversationReadReporter(service:.init(accountID:account,store:store,client:client))
        let page=Task {
            _ = try await reporter.recordReadThrough(roomID:room.rawValue,roomSequence:3)
            _ = try await reporter.recordReadThrough(roomID:room.rawValue,roomSequence:8)
        }
        try await page.value
        page.cancel()
        try await store.close()
        let reopened=try GRDBV2LocalSyncStore(databaseURL:url,installationBinding:binding,userID:account)
        #expect(try await reopened.roomReadWatermark(roomID:room) == 8)
        #expect(try await reopened.prepareNextReadReceiptIntent(accountID:account))
        let work=try #require(try await reopened.dueOperationWork(now:.now,kinds:[.readReceipt]).first)
        #expect(work.identity.accountID == account && work.identity.scope == .room(room))
        #expect(await client.calls == 0)
        try await reopened.close()
    }
}
private actor NoPageReadIO:V2ReadReceiptOperationClient {
    var calls=0
    func submit(_ command:V2RecordReadReceiptCommand) throws -> V2ReadReceiptOperationReceipt { calls += 1;throw V2RealtimeTransportError.unexpectedResponse }
    func recover(_ request:V2ReadReceiptRecoveryRequest) throws -> V2ReadReceiptRecoveryResult { calls += 1;throw V2RealtimeTransportError.unexpectedResponse }
}
