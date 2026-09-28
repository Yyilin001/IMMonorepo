import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Message intent admission", .serialized)
struct V2MessageIntentAdmissionTests {
    @Test("persisted send action freezes mentions, entities and reply before any network")
    func immutableSnapshot() async throws {
        let f=try SendWorkFixture();defer { f.remove() }
        let intent=try V2SendIntent(id:UUID(),roomID:f.room,clientMessageID:.init(uuid:UUID()),text:"content",replyTo:.init(messageID:.init(uuid:UUID())),attachmentJobIDs:[])
        try await f.store.freezeSendIntent(intent)
        #expect(await f.remote.submissions==0)
        #expect(try await f.store.preparingSendIntents()==[intent])
        try await f.store.handOffSendIntent(intent.id)
        let command=try await f.store.messageSendCommand(workID:f.head().id)
        #expect(command.command.clientMessageID==intent.clientMessageID)
        #expect(command.command.replyTo==intent.replyTo)
        #expect(command.command.text==intent.text)
        try await f.store.close()
    }
    @Test("duplicate local action cannot modify the original body")
    func duplicateIntent() async throws {
        let f=try SendWorkFixture();defer { f.remove() }
        let intent=try f.intent("original")
        try await f.store.freezeSendIntent(intent)
        try await f.store.freezeSendIntent(intent)
        let changed=try V2SendIntent(id:intent.id,roomID:intent.roomID,clientMessageID:intent.clientMessageID,text:"changed",attachmentJobIDs:[])
        await #expect(throws:V2ResourceJournalError.conflict) { try await f.store.freezeSendIntent(changed) }
        #expect(try await f.store.preparingSendIntents()==[intent])
        try await f.store.close()
    }
    @Test("cancelled callers cannot enqueue a new durable send")
    func cancelledBeforeEnqueue() async throws {
        let f=try SendWorkFixture();defer { f.remove() }
        let service=V2MessageSendOperationService(accountID:f.account,store:f.store,client:f.remote)
        let task=Task { while !Task.isCancelled { await Task.yield() };return try await service.enqueueMessage(roomID:f.room,text:"cancelled") }
        task.cancel()
        await #expect(throws:CancellationError.self) { try await task.value }
        #expect(try await f.store.preparingSendIntents().isEmpty)
        try await f.store.close()
    }
    @Test("empty body has no executable command")
    func emptyContent() throws {
        #expect(throws:V2ClientCommandError.invalidText) {
            try V2SendIntent(id:UUID(),roomID:.init(uuid:UUID()),clientMessageID:.init(uuid:UUID()),text:"",attachmentJobIDs:[])
        }
    }
}
