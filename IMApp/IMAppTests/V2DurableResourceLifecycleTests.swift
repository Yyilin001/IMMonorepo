import Foundation
import IMV2Core
import Synchronization
import Testing
@testable import IMV2ClientKit
@testable import IMApp

@MainActor
@Suite("Durable account resource closure", .timeLimit(.minutes(1)))
struct V2DurableResourceLifecycleTests {
    @Test("close drains public mutations as well as recovery before the journal closes", arguments: [false, true])
    func drainsImports(recovery: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appendingPathComponent("db.sqlite"),
            installationBinding: .init(value: UUID()), userID: user)
        let imports = LateResourceImport()
        let transfers = V2ResourceTransferEngine(store: store, control: NoLifecycleUpload(), executor: NoLifecycleUpload(), directory: directory)
        let groups = V2GroupAvatarIntentEngine(actorUserID: user, store: store, transfers: transfers, submissions: NoLifecycleGroupCommand())
        let sender = V2DurableConversationSendService(store: store, engine: transfers,
            outbox: .init(store: store, transport: NoLifecycleMessageTransport()), imports: imports, groupAvatars: groups)
        let source = V2ResourceImportSource.message(location: .init(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID())),
            mediaID: .init(uuid: UUID()), variantID: nil)
        let id = UUID()
        let request = try V2ResourceImportRequest(operationID: .init(uuid: UUID()), source: source,
            targetUsage: .messageAttachment(room), targetMediaID: .init(uuid: UUID()))
        try await store.prepareResourceImport(id: id, request: request)
        let intent = try V2SendIntent(id: UUID(), roomID: room, clientMessageID: .init(uuid: UUID()), text: "kept", attachmentJobIDs: [id])
        try await store.freezeSendIntent(intent)
        let work = Task {
            if recovery { await sender.startRecovery() }
            else { try await sender.cancel(intentID: intent.id) }
        }
        await imports.entered()
        let returned = Mutex(false)
        let closing = Task { await sender.close(); returned.withLock { $0 = true } }
        await imports.cancelled()
        #expect(!returned.withLock { $0 })
        await imports.release()
        await closing.value
        if recovery { try await work.value }
        else { await #expect(throws: CancellationError.self) { try await work.value } }
        let saved = try #require(try await store.resourceImport(id: id))
        #expect(saved.request == request && saved.status == nil)
        #expect(saved.cancellationRequested == !recovery)
        #expect(await imports.cancelCalls == 0)
        #expect(try await store.pendingMessageCommands().isEmpty)
        try await store.close()
        let attachment = V2StagedConversationAttachment(id: UUID(), fileURL: directory.appending(path: "missing"),
            displayName: "a.png", contentType: "image/png", byteCount: 1)
        // Closed owners reject at admission, before touching the closed store,
        // a missing source file, or an implementation-specific transport.
        await #expect(throws: CancellationError.self) { _ = try await sender.prepare(attachment, usage: .userAvatar) }
        await #expect(throws: CancellationError.self) { _ = try await sender.upload(attachment, usage: .userAvatar) }
        await #expect(throws: CancellationError.self) { try await sender.freezeSend(text: "late", mentions: [], replyTo: nil, roomID: room, attachments: []) }
        await #expect(throws: CancellationError.self) { try await sender.copyAttachments(sources: [source], to: room) }
        await #expect(throws: CancellationError.self) { _ = try await sender.pending(in: room) }
        await #expect(throws: CancellationError.self) { try await sender.retry(intentID: intent.id) }
        await #expect(throws: CancellationError.self) { try await sender.cancel(intentID: intent.id) }
        await sender.startRecovery()
        await sender.close()
    }
}

private actor LateResourceImport: V2ResourceImportControlling {
    private let starts = AsyncStream<Void>.makeStream()
    private let cancellations = AsyncStream<Void>.makeStream()
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var cancelCalls = 0
    func create(_ request: V2ResourceImportRequest) async throws -> V2ResourceImportStatus {
        await withTaskCancellationHandler {
            await withCheckedContinuation {
                continuation = $0
                starts.continuation.yield(())
            }
        } onCancel: { cancellations.continuation.yield(()) }
        return try .init(locator: .init(home: .room(.init(uuid: UUID())), operationID: request.operationID),
            mediaID: request.targetMediaID, state: .ready, bindableUntil: Date().addingTimeInterval(60))
    }
    func entered() async { var iterator = starts.stream.makeAsyncIterator(); _ = await iterator.next() }
    func cancelled() async { var iterator = cancellations.stream.makeAsyncIterator(); _ = await iterator.next() }
    func release() { continuation?.resume(); continuation = nil }
    func status(_ locator: V2ResourceImportLocator) throws -> V2ResourceImportStatus { throw CancellationError() }
    func cancel(_ locator: V2ResourceImportLocator) throws -> V2ResourceImportStatus { cancelCalls += 1; throw CancellationError() }
}

private struct NoLifecycleUpload: V2ResourceUploadControlling, V2ResourcePlanExecuting {
    func create(_ request: V2ResourceUploadRequest) throws -> V2ResourceUploadSession { throw CancellationError() }
    func status(_ locator: V2ResourceUploadLocator) throws -> V2ResourceUploadSession { throw CancellationError() }
    func target(_ session: V2ResourceUploadSession) throws -> V2ResourceTransferPlan { throw CancellationError() }
    func finalize(_ session: V2ResourceUploadSession) throws -> V2ResourceUploadSession { throw CancellationError() }
    func cancel(_ session: V2ResourceUploadSession) throws -> V2ResourceUploadSession { throw CancellationError() }
    func upload(fileURL: URL, plan: V2ResourceTransferPlan) throws { throw CancellationError() }
}
private struct NoLifecycleGroupCommand: V2GroupAvatarCommandSubmitting {
    func submitGroupAvatar(_ command: V2GroupAvatarCommand) throws -> V2GroupAvatarCommandResponse { throw CancellationError() }
}
private struct NoLifecycleMessageTransport: V2ClientMessageTransport {
    func sendMessage(roomID: RoomID, clientMessageID: ClientMessageID, text: String, media: [V2MediaReference],
                     mentions: [V2MentionTarget], entities: [V2MessageEntity], replyTo: V2MessageReplyReference?) throws -> V2ClientMessageAcceptance {
        throw CancellationError()
    }
}
