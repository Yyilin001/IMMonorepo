import Foundation
import IMV2Core
import Synchronization
import Testing
@testable import IMV2ClientKit
@testable import IMApp

@MainActor
@Suite("Durable account resource closure", .timeLimit(.minutes(1)))
struct V2DurableResourceLifecycleTests {
    @Test func localPhotoDimensionsReachFrozenUploadAndPendingLayout() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try await V2OriginalResourceTestFixture(root: root), room = RoomID(uuid: UUID())
        let dimensions = try V2ResourcePixelDimensions(width: 1536, height: 2048)
        let selected = try await f.stager.stageNormalizedPhoto(.init(data: Data([1, 2, 3]), format: .jpeg,
            imageDimensions: dimensions), purpose: .messageDraft(room))
        let engine = V2ResourceTransferEngine(store: f.store, control: NoLifecycleUpload(), executor: NoLifecycleUpload(), resources: f.resources)
        let groups = V2GroupAvatarIntentEngine(actorUserID: f.scope.accountID, store: f.store, transfers: engine, submissions: NoLifecycleGroupCommand())
        let sender = V2DurableConversationSendService(store: f.store, engine: engine, resources: f.resources,
            messageOperations: .init(accountID: f.scope.accountID, store: f.store, client: NoLifecycleMessageTransport()),
            imports: NoMetadataImport(), groupAvatars: groups)
        try await sender.freezeSend(text: "", mentions: [], replyTo: nil, roomID: room, attachments: [selected])
        let job = try #require(try await f.store.resourceTransfer(id: selected.id))
        #expect(job.request.clientImageDimensions == dimensions)
        #expect(try await sender.pending(in: room).first?.images.first?.dimensions == dimensions)
        await sender.close(); try await f.close()
    }
    @Test(arguments: [false, true]) func expiredImportedChatAttachmentOffersAndPerformsFreshPreparation(rejected: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let user = UserID(uuid: UUID()), room = RoomID(uuid: UUID()), id = UUID(), owner = UUID()
        let store = try GRDBV2LocalSyncStore(databaseURL: root.appendingPathComponent("V2.sqlite"),
            installationBinding: .init(value: UUID()), userID: user)
        let resources = try await makeAppResourceTestCenter(store: store, root: root)
        let transfers = V2ResourceTransferEngine(store: store, control: NoLifecycleUpload(), executor: NoLifecycleUpload(), resources: resources)
        let groups = V2GroupAvatarIntentEngine(actorUserID: user, store: store, transfers: transfers, submissions: NoLifecycleGroupCommand())
        let request = try V2ResourceImportRequest(operationID: .init(uuid: UUID()),
            source: .message(location: .init(roomID: room, messageID: .init(uuid: UUID())), mediaID: .init(uuid: UUID()), variantID: nil),
            targetUsage: .messageAttachment(room), targetMediaID: .init(uuid: UUID()))
        let sender = V2DurableConversationSendService(store: store, engine: transfers, resources: resources,
            messageOperations: .init(accountID: user, store: store, client: NoLifecycleMessageTransport()),
            imports: ManagedCancelledImport(request: request, room: room), groupAvatars: groups)
        try await store.prepareResourceImport(id: id, request: request)
        #expect(try await store.claimResourceImport(id, owner: owner))
        try await store.saveResourceImport(.init(locator: .init(home: .room(room), operationID: request.operationID),
            mediaID: request.targetMediaID, state: rejected ? .failed : .ready,
            bindableUntil: rejected ? nil : Date().addingTimeInterval(-60)), id: id, owner: owner)
        try await store.releaseResourceImportExecution(id, owner: owner)
        let intent = try V2SendIntent(id: UUID(), roomID: room, clientMessageID: .init(uuid: UUID()),
            text: "Keep this draft", attachmentJobIDs: [id])
        try await store.freezeSendIntent(intent, now: Date().addingTimeInterval(rejected ? -2 * 86400 : 0))
        let row = try #require(try await sender.pending(in: room).first)
        if rejected {
            #expect(row.status == "附件处理失败")
            #expect(!row.canRetry && row.canCancel)
            try await sender.cancel(intentID: intent.id)
            #expect(try await store.preparingSendIntent(id: intent.id) == nil)
            await sender.close(); await resources.close(); try await store.close()
            return
        }
        #expect(row.status == "发送准备已过期，可重新准备后发送")
        #expect(row.canRetry && row.retryTitle == "重新准备" && row.canCancel)
        try await sender.retry(intentID: intent.id)
        let next = try #require(try await store.preparingSendIntents().first)
        #expect(next.id != intent.id && next.attachmentJobIDs != intent.attachmentJobIDs)
        #expect(next.text == intent.text)
        try await sender.retry(intentID: intent.id)
        #expect(try await store.preparingSendIntents().map(\.id) == [next.id])
        await sender.close(); await resources.close(); try await store.close()
    }

    @Test func localImportPauseWaitsForCurrentRequestAndContinueQueriesOriginalLocator() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "local-import-pause-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let user = UserID(uuid: UUID()), room = RoomID(uuid: UUID()), id = UUID()
        let store = try GRDBV2LocalSyncStore(databaseURL: root.appending(path: "V2.sqlite"), installationBinding: .init(value: UUID()), userID: user)
        let resources = try await makeAppResourceTestCenter(store: store, root: root)
        let transfers = V2ResourceTransferEngine(store: store, control: NoLifecycleUpload(), executor: NoLifecycleUpload(), resources: resources)
        try await resources.attachUploads(transfers)
        let groups = V2GroupAvatarIntentEngine(actorUserID: user, store: store, transfers: transfers, submissions: NoLifecycleGroupCommand())
        let request = try V2ResourceImportRequest(operationID: .init(uuid: UUID()), source: .message(location: .init(roomID: room, messageID: .init(uuid: UUID())), mediaID: .init(uuid: UUID()), variantID: nil), targetUsage: .messageAttachment(room), targetMediaID: .init(uuid: UUID()))
        let imports = LocalImportPauseGate(request: request, room: room)
        let sender = V2DurableConversationSendService(store: store, engine: transfers, resources: resources,
            messageOperations: .init(accountID: user, store: store, client: NoLifecycleMessageTransport()), imports: imports, groupAvatars: groups)
        try await store.prepareResourceImport(id: id, request: request)
        try await store.freezeSendIntent(.init(id: UUID(), roomID: room, clientMessageID: .init(uuid: UUID()), text: "paused copy", attachmentJobIDs: [id]))
        let worker = Task { try await sender.runRecovery() }
        do {
            await imports.entered()
            try await resources.pauseTransfer(.serverImport(id))
            #expect(try await store.managedResourceTransfers(.init()).entries.first?.phase == .pausing)
            await #expect(throws: V2ResourceTransferManagementError.actionUnavailable) { try await resources.resumeTransfer(.serverImport(id)) }
            await imports.release()
            let deadline = ContinuousClock.now + .seconds(10)
            while try await store.managedResourceTransfers(.init(group: .attention)).entries.first?.phase != .paused { try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(5)) }
            #expect(try await sender.pending(in: room).first?.status == "附件准备已暂停，可在文件与存储中继续")
            #expect(try await sender.pending(in: room).first?.canRetry == false)
            #expect(try await store.dueResourceImports(now: .distantFuture).isEmpty)
            let locator = try #require(try await store.resourceImport(id: id)?.status?.locator)
            try await resources.resumeTransfer(.serverImport(id))
            await imports.entered()
            try await resources.pauseTransfer(.serverImport(id))
            await imports.release()
            while try await store.managedResourceTransfers(.init(group: .attention)).entries.first?.phase != .paused { try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(5)) }
            #expect(await imports.created == [request.operationID])
            #expect(await imports.queried == [locator])
            #expect(try await store.preparingSendIntents().count == 1)
            #expect(try await store.dueOperationWork(now: Date(), kinds: [.sendMessage]).isEmpty)
        } catch {
            await imports.finish(); worker.cancel(); _ = await worker.result
            await sender.close(); await resources.close(); try? await store.close(); throw error
        }
        await imports.finish(); worker.cancel(); _ = await worker.result
        await sender.close(); await resources.close(); try await store.close()
    }

    @Test(arguments: [(false,false),(true,false),(false,true),(true,true)]) func managementCancellationRecoversTheOriginalImportWithoutSubmittingItsMessage(retryCancellation: Bool, unbound: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "managed-import-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let user = UserID(uuid: UUID()), room = RoomID(uuid: UUID()), id = UUID()
        let store = try GRDBV2LocalSyncStore(databaseURL: root.appending(path: "V2.sqlite"), installationBinding: .init(value: UUID()), userID: user)
        let resources = try await makeAppResourceTestCenter(store: store, root: root)
        let transfers = V2ResourceTransferEngine(store: store, control: NoLifecycleUpload(), executor: NoLifecycleUpload(), resources: resources)
        try await resources.attachUploads(transfers)
        let groups = V2GroupAvatarIntentEngine(actorUserID: user, store: store, transfers: transfers, submissions: NoLifecycleGroupCommand())
        let request = try V2ResourceImportRequest(operationID: .init(uuid: UUID()), source: .message(location: .init(roomID: room, messageID: .init(uuid: UUID())), mediaID: .init(uuid: UUID()), variantID: nil), targetUsage: .messageAttachment(room), targetMediaID: .init(uuid: UUID()))
        let imports = ManagedCancelledImport(request: request, room: room, failCancellation: retryCancellation)
        let sender = V2DurableConversationSendService(store: store, engine: transfers, resources: resources,
            messageOperations: .init(accountID: user, store: store, client: NoLifecycleMessageTransport()), imports: imports, groupAvatars: groups)
        try await store.prepareResourceImport(id: id, request: request)
        if unbound {
            try await resources.cancelUnbound(try await resources.planUnboundCancellation(.serverImport(id)))
        } else {
            let intent = try V2SendIntent(id: UUID(), roomID: room, clientMessageID: .init(uuid: UUID()), text: "must not send", attachmentJobIDs: [id])
            try await store.freezeSendIntent(intent)
            let plan = try await resources.planPreparationCancellation(.serverImport(id))
            try await resources.cancelPreparation(plan)
        }
        let worker = Task { try await sender.runRecovery() }
        let deadline = ContinuousClock.now + .seconds(10)
        if retryCancellation {
            while try await store.resourceImport(id: id)?.attempts != 5 { try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(10)) }
            // An owned failure is not actionable until the real worker releases it.
            while try await store.managedResourceTransfers(.init(group: .attention)).entries.first?.actions != [.retryCancellation] {
                try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(10))
            }
            await imports.allowCancellation()
            try await resources.retryCancellation(.serverImport(id))
        }
        while try await store.resourceImport(id: id)?.status?.state != .cancelled { try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(10)) }
        let expected = Array(repeating: request.operationID, count: retryCancellation ? 2 : 1)
        #expect(await imports.createdOperations == expected)
        #expect(await imports.cancelledOperations == expected)
        #expect(try await store.dueOperationWork(now: Date(), kinds: [.sendMessage]).isEmpty)
        #expect(try await sender.pending(in: room).isEmpty)
        worker.cancel(); _ = await worker.result
        await sender.close(); await resources.close(); try await store.close()
    }

    @Test("text sends recover after all account activities have registered")
    func textRecoveryAfterAccountRegistrations() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "db.sqlite"),
            installationBinding: .init(value: UUID()), userID: user)
        let resources = try await makeAppResourceTestCenter(store: store, root: directory)
        let transfers = V2ResourceTransferEngine(store: store, control: NoLifecycleUpload(), executor: NoLifecycleUpload(), resources: resources)
        let groups = V2GroupAvatarIntentEngine(actorUserID: user, store: store, transfers: transfers, submissions: NoLifecycleGroupCommand())
        let sender = V2DurableConversationSendService(store: store, engine: transfers, resources: resources,
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
        await resources.close(); try await store.close()
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
        let resources = try await makeAppResourceTestCenter(store: store, root: directory)
        let transfers = V2ResourceTransferEngine(store: store, control: control, executor: NoLifecycleUpload(), resources: resources)
        let groups = V2GroupAvatarIntentEngine(actorUserID: user, store: store, transfers: transfers, submissions: NoLifecycleGroupCommand())
        let sender = V2DurableConversationSendService(store: store, engine: transfers, resources: resources, messageOperations: .init(accountID: user, store: store, client: NoLifecycleMessageTransport()), imports: LateResourceImport(), groupAvatars: groups)
        let activity = Task { try await transfers.runRecovery() }
        let asset = try await resources.importLocal(at: file, displayName: .init("a.png"), contentType: .init("image/png"), purpose: .personalAvatar, id: .init(id))
        let attachment = V2StagedConversationAttachment(asset: asset)
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
        await sender.close(); await resources.close(); try await store.close()
    }

    @Test("page actions resolve the exact preparing intent beyond the first 64", arguments: ["retry", "cancel"])
    func latePreparingIntentUsesExactIdentity(action: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appendingPathComponent("db.sqlite"),
            installationBinding: .init(value: UUID()), userID: user)
        let resources = try await makeAppResourceTestCenter(store: store, root: directory)
        let transfers = V2ResourceTransferEngine(store: store, control: NoLifecycleUpload(), executor: NoLifecycleUpload(), resources: resources)
        let groups = V2GroupAvatarIntentEngine(actorUserID: user, store: store, transfers: transfers, submissions: NoLifecycleGroupCommand())
        let sender = V2DurableConversationSendService(store: store, engine: transfers, resources: resources,
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
        await sender.close(); await resources.close(); try await store.close()
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
        let resources = try await makeAppResourceTestCenter(store: store, root: directory)
        let transfers = V2ResourceTransferEngine(store: store, control: NoLifecycleUpload(), executor: NoLifecycleUpload(), resources: resources)
        let groups = V2GroupAvatarIntentEngine(actorUserID: user, store: store, transfers: transfers, submissions: NoLifecycleGroupCommand())
        let sender = V2DurableConversationSendService(store: store, engine: transfers, resources: resources,
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
        // Simulate an interrupted prior account activity. The real new
        // activity must adopt this claim without resetting its charged budget.
        #expect(try await store.claimResourceImport(id, owner: UUID(), now: Date().addingTimeInterval(-2)))
        let work = Task { try await sender.runRecovery() }
        await imports.entered()
        #expect(try await store.resourceImport(id: id)?.attempts == 2)
        #expect(try await store.dueResourceImports(now: .distantFuture).isEmpty)
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
        #expect(try await store.dueResourceImports(now: .distantFuture).map(\.id) == [id])
        #expect(await imports.cancelCalls == 0)
        #expect(try await store.dueOperationWork(now:Date(),kinds:[.sendMessage]).isEmpty)
        await resources.close(); try await store.close()
        let attachment = V2StagedConversationAttachment(id: UUID(), displayName: "a.png", contentType: "image/png", byteCount: 1)
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

private actor LocalImportPauseGate: V2ResourceImportControlling {
    let request: V2ResourceImportRequest
    let room: RoomID
    private let starts = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private var continuation: CheckedContinuation<Void, Never>?
    private var stopped = false
    private(set) var created: [ResourceImportOperationID] = []
    private(set) var queried: [V2ResourceImportLocator] = []
    init(request: V2ResourceImportRequest, room: RoomID) { self.request = request; self.room = room }
    func entered() async { for await _ in starts.stream { return } }
    func release() { continuation?.resume(); continuation = nil }
    func finish() { stopped = true; release() }
    func create(_ request: V2ResourceImportRequest) async throws -> V2ResourceImportStatus {
        #expect(request == self.request); created.append(request.operationID)
        return try await hold(.init(home: .room(room), operationID: request.operationID))
    }
    func status(_ locator: V2ResourceImportLocator) async throws -> V2ResourceImportStatus {
        queried.append(locator); return try await hold(locator)
    }
    private func hold(_ locator: V2ResourceImportLocator) async throws -> V2ResourceImportStatus {
        guard !stopped else { throw CancellationError() }
        await withCheckedContinuation { continuation = $0; starts.continuation.yield(()) }
        try Task.checkCancellation()
        return try .init(locator: locator, mediaID: request.targetMediaID, state: .copying, bindableUntil: nil)
    }
    func cancel(_ locator: V2ResourceImportLocator) throws -> V2ResourceImportStatus {
        Issue.record("Pausing local follow-up must not cancel the server operation")
        throw V2ResourceJournalError.invalidRecord
    }
}

private actor ManagedCancelledImport: V2ResourceImportControlling {
    let request: V2ResourceImportRequest
    let room: RoomID
    private(set) var createdOperations: [ResourceImportOperationID] = []
    private(set) var cancelledOperations: [ResourceImportOperationID] = []
    private var failCancellation: Bool
    init(request: V2ResourceImportRequest, room: RoomID, failCancellation: Bool = false) { self.request = request; self.room = room; self.failCancellation = failCancellation }
    func allowCancellation() { failCancellation = false }
    func create(_ request: V2ResourceImportRequest) throws -> V2ResourceImportStatus {
        #expect(request == self.request)
        createdOperations.append(request.operationID)
        return try .init(locator: .init(home: .room(room), operationID: request.operationID), mediaID: request.targetMediaID, state: .pending, bindableUntil: nil)
    }
    func status(_ locator: V2ResourceImportLocator) throws -> V2ResourceImportStatus {
        try .init(locator: locator, mediaID: request.targetMediaID, state: .pending, bindableUntil: nil)
    }
    func cancel(_ locator: V2ResourceImportLocator) throws -> V2ResourceImportStatus {
        #expect(locator.operationID == request.operationID)
        cancelledOperations.append(locator.operationID)
        if failCancellation { throw V2ResourceJournalError.invalidRecord }
        return try .init(locator: locator, mediaID: request.targetMediaID, state: .cancelled, bindableUntil: nil)
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

private struct NoMetadataImport: V2ResourceImportControlling {
    func create(_ request: V2ResourceImportRequest) throws -> V2ResourceImportStatus { throw CancellationError() }
    func status(_ locator: V2ResourceImportLocator) throws -> V2ResourceImportStatus { throw CancellationError() }
    func cancel(_ locator: V2ResourceImportLocator) throws -> V2ResourceImportStatus { throw CancellationError() }
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
