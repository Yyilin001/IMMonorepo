import Foundation
import IMV2Core
import Synchronization
import Testing
@testable import IMV2ClientKit
@testable import IMApp

@MainActor
@Suite("Durable account resource closure", .timeLimit(.minutes(1)))
struct V2DurableResourceLifecycleTests {
    @Test("text sends recover after all account activities have registered")
    func textRecoveryAfterAccountRegistrations() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "db.sqlite"),
            installationBinding: .init(value: UUID()), userID: user)
        let transfers = V2ResourceTransferEngine(store: store, control: NoLifecycleUpload(), executor: NoLifecycleUpload(), directory: directory)
        let groups = V2GroupAvatarIntentEngine(actorUserID: user, store: store, transfers: transfers, submissions: NoLifecycleGroupCommand())
        let sender = V2DurableConversationSendService(store: store, engine: transfers,
            messageOperations: .init(accountID: user, store: store, client: NoLifecycleMessageTransport()),
            imports: LateResourceImport(), groupAvatars: groups)
        let intent = try V2SendIntent(id: UUID(), roomID: room, clientMessageID: .init(uuid: UUID()), text: "saved before startup", attachmentJobIDs: [])
        try await store.freezeSendIntent(intent)
        #expect(try await sender.pending(in: room).first?.status == "等待发送")
        let runtime = V2AccountRuntime()
        for index in 0..<20 {
            await runtime.startActivity(id: "account-\(index)") { try await Task.sleep(for: .seconds(3600)) }
        }
        await runtime.startActivity(id: "resourcePreparation") { try await sender.runRecovery() }
        #expect(await runtime.activitySnapshot()["resourcePreparation"] == .running)
        // Observe the real preparation-to-operation handoff, including saved work
        // from before startup and a new text frozen after the owner is running.
        for try await _ in store.resourceSendChanges(in: room) {
            if try await store.preparingSendIntent(id: intent.id) == nil { break }
        }
        try await sender.freezeSend(text: "new send", mentions: [], replyTo: nil, roomID: room, attachments: [])
        for try await _ in store.resourceSendChanges(in: room) {
            if try await store.preparingSendIntents(in: room).isEmpty { break }
        }
        #expect(try await sender.pending(in: room).count == 2)
        #expect(try await store.dueOperationWork(now: Date(), kinds: [.sendMessage]).count == 1)
        await runtime.close()
        #expect(await runtime.activitySnapshot()["resourcePreparation"] == .cancelled)
        await sender.close()
        try await store.close()
    }

    @Test("cancelling an upload observer leaves the persisted account activity running")
    func observerCancellationKeepsAccountTransfer() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "durable-observer-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = UserID(uuid: UUID()), id = UUID()
        let file = directory.appending(path: id.uuidString)
        try Data("abc".utf8).write(to: file)
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "db.sqlite"), installationBinding: .init(value: UUID()), userID: user)
        let control = DurableCreationGate(user: user)
        let transfers = V2ResourceTransferEngine(store: store, control: control, executor: NoLifecycleUpload(), directory: directory)
        let groups = V2GroupAvatarIntentEngine(actorUserID: user, store: store, transfers: transfers, submissions: NoLifecycleGroupCommand())
        let sender = V2DurableConversationSendService(store: store, engine: transfers, messageOperations: .init(accountID: user, store: store, client: NoLifecycleMessageTransport()), imports: LateResourceImport(), groupAvatars: groups)
        let activity = Task { try await transfers.runRecovery() }
        let attachment = V2StagedConversationAttachment(id: id, fileURL: file, displayName: "a.png", contentType: "image/png", byteCount: 3)
        let observer = Task { try await sender.upload(attachment, usage: .userAvatar) }
        await control.entered()
        observer.cancel()
        await #expect(throws: CancellationError.self) { _ = try await observer.value }
        #expect(await control.wasCancelled == false)
        let pending = try #require(try await store.resourceTransfer(id: id))
        #expect(!pending.cancellationRequested && pending.stage == .prepared)
        await control.release()
        for try await value in store.resourceTransferUpdates(id: id) {
            if value?.stage == .ready { break }
        }
        #expect(try await store.resourceTransfer(id: id)?.stage == .ready)
        #expect(FileManager.default.fileExists(atPath: file.path))
        activity.cancel(); _ = await activity.result
        await sender.close(); try await store.close()
    }

    @Test("page actions resolve the exact preparing intent beyond the first 64", arguments: ["retry", "cancel"])
    func latePreparingIntentUsesExactIdentity(action: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appendingPathComponent("db.sqlite"),
            installationBinding: .init(value: UUID()), userID: user)
        let transfers = V2ResourceTransferEngine(store: store, control: NoLifecycleUpload(), executor: NoLifecycleUpload(), directory: directory)
        let groups = V2GroupAvatarIntentEngine(actorUserID: user, store: store, transfers: transfers, submissions: NoLifecycleGroupCommand())
        let sender = V2DurableConversationSendService(store: store, engine: transfers,
            messageOperations: .init(accountID: user, store: store, client: NoLifecycleMessageTransport()), imports: LateResourceImport(), groupAvatars: groups)
        var lastID = UUID()
        let created = Date()
        for index in 0..<65 {
            let intent = try V2SendIntent(id: UUID(), roomID: room, clientMessageID: .init(uuid: UUID()),
                text: "queued \(index)", attachmentJobIDs: [])
            try await store.freezeSendIntent(intent, now: created.addingTimeInterval(Double(index)))
            lastID = intent.id
        }
        #expect(try await store.preparingSendIntents(in: room).count == 64)
        #expect(try await store.preparingSendIntent(id: lastID) != nil)
        if action == "retry" {
            for _ in 0..<5 { try await store.deferPreparedSendIntent(lastID) }
            #expect(try await store.preparedSendRequiresAttention(lastID))
            try await sender.retry(intentID: lastID)
            #expect(try await store.preparedSendRequiresAttention(lastID) == false)
            #expect(try await store.preparingSendIntent(id: lastID) != nil)
        } else {
            try await sender.cancel(intentID: lastID)
            #expect(try await store.preparingSendIntent(id: lastID) == nil)
        }
        await sender.close(); try await store.close()
    }

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
            messageOperations: .init(accountID: user, store: store, client: NoLifecycleMessageTransport()), imports: imports, groupAvatars: groups)
        let source = V2ResourceImportSource.message(location: .init(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID())),
            mediaID: .init(uuid: UUID()), variantID: nil)
        let id = UUID()
        let request = try V2ResourceImportRequest(operationID: .init(uuid: UUID()), source: source,
            targetUsage: .messageAttachment(room), targetMediaID: .init(uuid: UUID()))
        try await store.prepareResourceImport(id: id, request: request)
        let intent = try V2SendIntent(id: UUID(), roomID: room, clientMessageID: .init(uuid: UUID()), text: "kept", attachmentJobIDs: [id])
        try await store.freezeSendIntent(intent)
        if !recovery { try await sender.cancel(intentID: intent.id) }
        let work = Task { try await sender.runRecovery() }
        await imports.entered()
        let returned = Mutex(false)
        let closing = Task { await sender.close(); returned.withLock { $0 = true } }
        await imports.cancelled()
        #expect(!returned.withLock { $0 })
        await imports.release()
        await closing.value
        await #expect(throws: CancellationError.self) { try await work.value }
        let saved = try #require(try await store.resourceImport(id: id))
        #expect(saved.request == request && saved.status == nil)
        #expect(saved.cancellationRequested == !recovery)
        #expect(await imports.cancelCalls == 0)
        #expect(try await store.dueOperationWork(now:Date(),kinds:[.sendMessage]).isEmpty)
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
        await #expect(throws: CancellationError.self) { try await sender.runRecovery() }
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
    func target(_ session: V2ResourceUploadSession) throws -> V2ResourceTransferPlan? { throw CancellationError() }
    func finalize(_ session: V2ResourceUploadSession) throws -> V2ResourceUploadSession { throw CancellationError() }
    func cancel(_ session: V2ResourceUploadSession) throws -> V2ResourceUploadSession { throw CancellationError() }
    func upload(fileURL: URL, plan: V2ResourceTransferPlan) throws { throw CancellationError() }
}
private struct NoLifecycleGroupCommand: V2GroupAvatarCommandSubmitting {
    func submitGroupAvatar(_ command: V2GroupAvatarCommand) throws -> V2GroupAvatarCommandResponse { throw CancellationError() }
}
private struct NoLifecycleMessageTransport: V2MessageSendOperationClient {
    func submit(_ command: V2MessageSendOperationCommand) throws -> V2MessageSendOperationRecoveryResult { throw CancellationError() }
    func recover(_ request: V2MessageSendOperationRecoveryRequest) throws -> V2MessageSendOperationRecoveryResult { throw CancellationError() }
}

private actor DurableCreationGate: V2ResourceUploadControlling {
    let user: UserID
    private let starts = AsyncStream<Void>.makeStream()
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var wasCancelled = false
    init(user: UserID) { self.user = user }
    func create(_ request: V2ResourceUploadRequest) async throws -> V2ResourceUploadSession {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                starts.continuation.yield(())
            }
        } onCancel: { Task { await self.recordCancellation() } }
        return try .init(locator: .init(home: .account(user), sessionID: .init(uuid: UUID())), mediaID: request.mediaID, generation: 1, state: .completed, resourceState: .ready, expiresAt: .now.addingTimeInterval(600), bindableUntil: .now.addingTimeInterval(600))
    }
    private func recordCancellation() { wasCancelled = true }
    func entered() async { var iterator = starts.stream.makeAsyncIterator(); _ = await iterator.next() }
    func release() { continuation?.resume(); continuation = nil }
    func status(_ locator: V2ResourceUploadLocator) throws -> V2ResourceUploadSession { throw CancellationError() }
    func target(_ session: V2ResourceUploadSession) throws -> V2ResourceTransferPlan? { throw CancellationError() }
    func finalize(_ session: V2ResourceUploadSession) throws -> V2ResourceUploadSession { throw CancellationError() }
    func cancel(_ session: V2ResourceUploadSession) throws -> V2ResourceUploadSession { throw CancellationError() }
}
