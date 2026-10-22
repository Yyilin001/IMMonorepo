import Foundation
import IMV2ClientKit
import IMV2Core

protocol V2DurableConversationSending: Sendable {
    func upload(_ attachment: V2StagedConversationAttachment, usage: V2ResourceUsage) async throws -> V2MediaReference
    func copyAttachments(sources: [V2ResourceImportSource], to room: RoomID) async throws
    func pending(in roomID: RoomID) async throws -> [V2DurableConversationSendService.Pending]
    func pendingPageUpdates(in roomID:RoomID,page:Int) -> AsyncThrowingStream<V2DurableConversationSendService.PendingPage,any Error>
    func retry(intentID: UUID) async throws
    func cancel(intentID: UUID) async throws
    func runRecovery() async throws
    func close() async
    func freezeSend(text: String, mentions: [V2MentionTarget], replyTo: V2MessageReplyReference?, roomID: RoomID, attachments: [V2StagedConversationAttachment]) async throws
}

/// Account lifetime owner; recovery survives page closure and reads only frozen
/// intents. Signed targets and UI drafts never become recovery inputs.
actor V2DurableConversationSendService: V2DurableConversationSending {
    private let store: GRDBV2LocalSyncStore
    private let engine: V2ResourceTransferEngine
    private let messageOperations: V2MessageSendOperationService
    private let imports: any V2ResourceImportControlling
    private let groupAvatars: V2GroupAvatarIntentEngine
    private let groupAvatarManager: V2GroupAvatarManagementService?
    private var closed = false
    private var recoveryRunning = false
    private(set) var recoveryError: String?
    private let operations = V2ResourceOperationScope()

    init(store: GRDBV2LocalSyncStore, engine: V2ResourceTransferEngine, messageOperations: V2MessageSendOperationService,
         imports: any V2ResourceImportControlling, groupAvatars: V2GroupAvatarIntentEngine,
         groupAvatarManager: V2GroupAvatarManagementService? = nil) {
        self.store = store; self.engine = engine; self.messageOperations = messageOperations; self.imports = imports
        self.groupAvatars = groupAvatars
        self.groupAvatarManager = groupAvatarManager
    }

    func prepare(_ attachment: V2StagedConversationAttachment, usage: V2ResourceUsage) async throws -> UUID {
        try requireOpen()
        return try await operations.run { try await self.performPrepare(attachment, usage: usage) }
    }

    private func performPrepare(_ attachment: V2StagedConversationAttachment, usage: V2ResourceUsage) async throws -> UUID {
        try requireOpen()
        if let existing = try await store.resourceTransfer(id: attachment.id) {
            guard existing.request.usage == usage else { throw V2ResourceJournalError.conflict }
            return existing.id
        }
        try requireOpen()
        let checksum = try V2ResourceFileDigest.sha256(fileURL: attachment.fileURL, expectedByteCount: attachment.byteCount)
        let request = try V2ResourceUploadRequest(operationID: .init(attachment.id.uuidString), mediaID: .init(attachment.id.uuidString), usage: usage, contentType: attachment.contentType, byteCount: attachment.byteCount, checksum: .init(value: checksum), clientModes: [.httpPartPut, .httpPut])
        _ = try await engine.prepare(id: attachment.id, request: request)
        return attachment.id
    }

    func upload(_ attachment: V2StagedConversationAttachment, usage: V2ResourceUsage) async throws -> V2MediaReference {
        try requireOpen()
        return try await operations.run { try await self.performUpload(attachment, usage: usage) }
    }

    private func performUpload(_ attachment: V2StagedConversationAttachment, usage: V2ResourceUsage) async throws -> V2MediaReference {
        try requireOpen()
        let id = try await performPrepare(attachment, usage: usage)
        // Persistence is the handoff. The account activity advances work;
        // this page owns only a bounded database observation.
        for try await value in store.resourceTransferUpdates(id: id) {
            try Task.checkCancellation()
            guard !closed, let job = value else { throw CancellationError() }
            if job.stage == .ready { return .init(mediaID: job.request.mediaID) }
            if job.needsAttention { throw V2ClientMediaTransferError.scanPending }
            if [.rejected,.cancelled,.expired].contains(job.stage) { throw V2ClientMediaTransferError.mediaRejected }
        }
        throw CancellationError()
    }

    func freezeSend(text: String, mentions: [V2MentionTarget], replyTo: V2MessageReplyReference?, roomID: RoomID, attachments: [V2StagedConversationAttachment]) async throws {
        try requireOpen()
        return try await operations.run { try await self.performFreezeSend(text: text, mentions: mentions, replyTo: replyTo, roomID: roomID, attachments: attachments) }
    }

    private func performFreezeSend(text: String, mentions: [V2MentionTarget], replyTo: V2MessageReplyReference?, roomID: RoomID, attachments: [V2StagedConversationAttachment]) async throws {
        try requireOpen()
        var resources: [V2ResourcePreparedUpload] = []
        for attachment in attachments {
            try Task.checkCancellation()
            let checksum = try V2ResourceFileDigest.sha256(fileURL: attachment.fileURL, expectedByteCount: attachment.byteCount)
            let request = try V2ResourceUploadRequest(operationID: .init(attachment.id.uuidString), mediaID: .init(attachment.id.uuidString), usage: .messageAttachment(roomID), contentType: attachment.contentType, byteCount: attachment.byteCount, checksum: .init(value: checksum), clientModes: [.httpPartPut, .httpPut])
            resources.append(try .init(id: attachment.id, request: request, localFileToken: attachment.id.uuidString))
        }
        let intent = try V2SendIntent(id: UUID(), roomID: roomID, clientMessageID: .init(UUID().uuidString), text: text, mentions: mentions, replyTo: replyTo, attachmentJobIDs: resources.map(\.id))
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        // All uploads and their consumer become recoverable in one transaction.
        try await engine.prepareSend(intent, resources: resources)
    }

    func copyAttachments(sources: [V2ResourceImportSource], to room: RoomID) async throws {
        try requireOpen()
        return try await operations.run { try await self.performCopyAttachments(sources: sources, to: room) }
    }

    private func performCopyAttachments(sources: [V2ResourceImportSource], to room: RoomID) async throws {
        try requireOpen()
        guard !sources.isEmpty, sources.count <= V2MessageCommandLimits.maxMediaAttachments else { throw V2ResourceJournalError.invalidRecord }
        var jobs: [UUID] = []
        var prepared: [UUID: V2ResourceImportRequest] = [:]
        for source in sources {
            try Task.checkCancellation()
            let id = UUID()
            let request = try V2ResourceImportRequest(operationID: .init(id.uuidString), source: source, targetUsage: .messageAttachment(room), targetMediaID: .init(UUID().uuidString))
            try requireOpen()
            prepared[id] = request
            jobs.append(id)
        }
        let intent = try V2SendIntent(id: UUID(), roomID: room, clientMessageID: .init(UUID().uuidString), text: "", attachmentJobIDs: jobs)
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        try await store.freezeSendIntent(intent, imports: prepared)
    }
    private func advanceImport(_ job: V2ResourceImportJob) async throws -> Bool {
        try requireOpen()
        guard !job.cancellationRequested, try await store.claimResourceImport(job.id) else { return false }
        let status: V2ResourceImportStatus
        let due = try await store.resourceImportDeadline(job.id) ?? Date()
        let deadline = ContinuousClock.now.advanced(by: .seconds(max(0,due.timeIntervalSinceNow)))
        status = try await V2NetworkWorkScope.$context.withValue(.init(service: "resources", priority: .recovery, isRetry: job.attempts>0)) {
            try await V2HTTPRequestDeadline.$current.withValue(deadline) {
                if let saved = job.status { return try await self.imports.status(saved.locator) }
                return try await self.imports.create(job.request)
            }
        }
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        try await store.saveResourceImport(status, id: job.id)
        return status.state == .ready
    }
    private func cancelImport(_ id: UUID) async throws {
        try requireOpen()
        try await store.requestImportCancellation(id: id)
        guard let job = try await store.resourceImport(id: id) else { return }
        try requireOpen()
        let status: V2ResourceImportStatus
        if let saved = job.status { status = saved }
        else { status = try await imports.create(job.request) }
        try requireOpen()
        let result = try await imports.cancel(status.locator)
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        try await store.saveResourceImport(result, id: id)
    }

    struct Pending: Identifiable, Hashable, Sendable {
        let id: UUID
        let createdAt: Date
        let text: String
        let completed: Int
        let total: Int
        let status: String
        let canRetry: Bool
        let retryTitle: String
        let canCancel: Bool
    }
    struct PendingPage: Sendable {
        let items:[Pending]
        let hasNext:Bool
    }
    func pending(in roomID: RoomID) async throws -> [Pending] {
        try await pendingPage(in:roomID,page:0).items
    }
    private func pendingPage(in roomID:RoomID,page:Int) async throws -> PendingPage {
        try requireOpen()
        guard page >= 0 && page <= Int.max / 200 - 1 else { throw V2ResourceJournalError.invalidRecord }
        return try await operations.run { try await self.performPending(in:roomID,page:page) }
    }
    nonisolated func pendingPageUpdates(in roomID:RoomID,page:Int) -> AsyncThrowingStream<PendingPage,any Error> {
        AsyncThrowingStream(bufferingPolicy:.bufferingNewest(1)) { continuation in
            let observer=Task {
                do {
                    for try await _ in self.store.resourceSendChanges(in:roomID,page:page) {
                        continuation.yield(try await self.pendingPage(in:roomID,page:page))
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing:error) }
            }
            continuation.onTermination = { _ in observer.cancel() }
        }
    }

    private func performPending(in roomID: RoomID,page:Int) async throws -> PendingPage {
        try requireOpen()
        var result: [Pending] = []
        let snapshot = try await store.pendingResourceSendSnapshot(in: roomID, page: page)
        for intent in snapshot.preparing {
            let status = recoveryError ?? (intent.isExpired ? "资源已过期，等待确认终态" : intent.isRejected ? "附件未通过安全处理" : intent.isPaused ? "上传已暂停，可重试" : intent.isProcessing ? "正在安全处理" : "正在准备附件")
            result.append(.init(id: intent.id, createdAt: intent.createdAt, text: intent.text, completed: intent.completed, total: intent.total,
                                status: status, canRetry: intent.isPaused && !intent.isExpired && !intent.isRejected,
                                retryTitle: "重试准备", canCancel: true))
        }
        for submitted in snapshot.submitted {
            let status = switch submitted.status {
            case .pending: "等待发送"
            case .waitingForNetwork: "等待网络连接后发送"
            case .waitingForAuthentication: "等待登录恢复后发送"
            case .acceptedAwaitingProjection: "服务器已受理，等待消息同步"
            case .confirmingOutcome: "正在确认原消息的发送结果"
            case .needsAttention: "原消息结果未知，确认已暂停"
            case .expiredUnsubmitted: "消息尚未提交，已超过发送确认期限"
            case .closed: "服务器已确认这条消息未发送"
            case .rejected: "这条消息未能发送"
            }
            result.append(.init(id: submitted.id,createdAt: submitted.createdAt,text: submitted.text,completed: 0,total: 0,status: status,
                canRetry: submitted.status == .closed || submitted.status == .rejected || submitted.status == .expiredUnsubmitted || submitted.status == .needsAttention,retryTitle:submitted.status == .needsAttention ? "继续确认" : "重新发送",canCancel: submitted.status == .closed || submitted.status == .rejected || submitted.status == .expiredUnsubmitted))
        }
        return .init(items:result,hasNext:snapshot.hasNext)
    }
    func retry(intentID: UUID) async throws {
        try requireOpen()
        return try await operations.run { try await self.performRetry(intentID: intentID) }
    }

    private func performRetry(intentID: UUID) async throws {
        try requireOpen()
        guard let intent = try await store.preparingSendIntent(id:intentID) else {
            try requireOpen()
            if try await store.sendIntentNeedsAttention(id:intentID) {
                try await messageOperations.resumeConfirmation(intentID:intentID)
            } else { _ = try await store.replaceProvenUnsentSendIntent(intentID) }
            return
        }
        try await store.retryPreparedSendIntent(intentID)
        for id in intent.attachmentJobIDs {
            try requireOpen()
            try await store.retryResourceTransfer(id: id)
            try requireOpen()
            try await store.retryResourceImport(id: id)
        }
    }
    func cancel(intentID: UUID) async throws {
        try requireOpen()
        return try await operations.run { try await self.performCancel(intentID: intentID) }
    }

    private func performCancel(intentID: UUID) async throws {
        try requireOpen()
        guard let intent = try await store.preparingSendIntent(id:intentID) else {
            try requireOpen()
            try await store.abandonProvenUnsentSendIntent(intentID)
            try await engine.releaseAcceptedStaging()
            return
        }
        // Stop any future handoff before cancelling a remote transfer.
        try requireOpen()
        try await store.cancelSendIntent(intentID)
        for id in intent.attachmentJobIDs {
            if try await store.resourceImport(id: id) != nil { try await store.requestImportCancellation(id: id) }
            else { try await engine.cancel(id: id) }
        }
    }

    func close() async {
        closed = true
        async let drainOperations: Void = operations.close()
        async let drainGroupManagement: Void = groupAvatarManager?.close() ?? ()
        await groupAvatars.close()
        await engine.close()
        await drainOperations
        await drainGroupManagement
    }

    private func requireOpen() throws {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
    }

    /// The account runtime may own this activity directly and report infrastructure failures.
    func runRecovery() async throws {
        try requireOpen()
        guard !recoveryRunning else { throw V2ResourceOperationScopeError.busy }
        recoveryRunning = true
        recoveryError = nil
        defer { recoveryRunning = false }
        do {
            try await operations.run {
                try await self.store.runResourcePreparation { try await self.recoverDue() }
            }
            try Task.checkCancellation()
        } catch {
            if Task.isCancelled || closed { await groupAvatars.stopRecoveryAndDrain() }
            else { recoveryError = "附件恢复已暂停，请重新连接账户后重试" }
            throw error
        }
    }

    private func recoverDue() async throws {
        try requireOpen()
        for job in try await store.dueResourceImports() {
            try requireOpen()
            do {
                if job.cancellationRequested {
                    if try await store.claimResourceImport(job.id) {
                        let due = try await store.resourceImportDeadline(job.id) ?? Date()
                        let deadline = ContinuousClock.now.advanced(by: .seconds(max(0,due.timeIntervalSinceNow)))
                        try await V2NetworkWorkScope.$context.withValue(.init(service: "resources", priority: .recovery, isRetry: job.attempts>0)) {
                            try await V2HTTPRequestDeadline.$current.withValue(deadline) { try await self.cancelImport(job.id) }
                        }
                    }
                } else { _ = try await advanceImport(job) }
            } catch is CancellationError { throw CancellationError() }
            catch {
                try requireOpen()
                let http = error as? V2HTTPFailure
                let transient: Bool
                if let http {
                    transient = http.kind == .transport || http.kind == .deadlineExceeded || http.statusCode == 401 || http.statusCode == 408 || http.statusCode == 429 || (http.statusCode ?? 0)>=500
                } else { transient = error is URLError || (error as? V2ClientMediaTransferError) == .authorizationUnavailable }
                try await store.pauseResourceImport(id: job.id, retryNotBefore: http?.retryAfter, needsAttention: !transient)
            }
        }
        for intent in try await store.duePreparedSendIntents() {
            try requireOpen()
            do { _ = try await store.handOffSendIntent(intent.id) }
            catch is CancellationError { throw CancellationError() }
            catch { try requireOpen(); try await store.deferPreparedSendIntent(intent.id) }
        }
        // The outbox and byte journal have their own owners and DB schedules.
        try await groupAvatars.recoverOnce()
        try await engine.releaseAcceptedStaging()
    }
}
