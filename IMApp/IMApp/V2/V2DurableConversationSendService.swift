import Foundation
import IMV2ClientKit
import IMV2Core

protocol V2DurableConversationSending: Sendable {
    func upload(_ attachment: V2StagedConversationAttachment, usage: V2ResourceUsage) async throws -> V2MediaReference
    func copyAttachments(sources: [V2ResourceImportSource], to room: RoomID) async throws
    func pending(in roomID: RoomID) async throws -> [V2DurableConversationSendService.Pending]
    func retry(intentID: UUID) async throws
    func cancel(intentID: UUID) async throws
    func startRecovery() async
    func close() async
    func freezeSend(text: String, mentions: [V2MentionTarget], replyTo: V2MessageReplyReference?, roomID: RoomID, attachments: [V2StagedConversationAttachment]) async throws
}

/// Account lifetime owner; recovery survives page closure and reads only frozen
/// intents. Signed targets and UI drafts never become recovery inputs.
actor V2DurableConversationSendService: V2DurableConversationSending {
    private let store: GRDBV2LocalSyncStore
    private let engine: V2ResourceTransferEngine
    private let outbox: V2CommandOutboxEngine
    private let imports: any V2ResourceImportControlling
    private let groupAvatars: V2GroupAvatarIntentEngine
    private let groupAvatarManager: V2GroupAvatarManagementService?
    private var recovery: Task<Void, Never>?
    private var closed = false
    private let operations = V2ResourceOperationScope()

    init(store: GRDBV2LocalSyncStore, engine: V2ResourceTransferEngine, outbox: V2CommandOutboxEngine,
         imports: any V2ResourceImportControlling, groupAvatars: V2GroupAvatarIntentEngine,
         groupAvatarManager: V2GroupAvatarManagementService? = nil) {
        self.store = store; self.engine = engine; self.outbox = outbox; self.imports = imports
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
        let request = try V2ResourceUploadRequest(operationID: .init(attachment.id.uuidString), mediaID: .init(attachment.id.uuidString), usage: usage, contentType: attachment.contentType, byteCount: attachment.byteCount, checksum: .init(value: checksum), clientModes: [.httpPut])
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
        let job = try await engine.resume(id: id)
        try Task.checkCancellation()
        guard !closed, job.stage == .ready else { throw V2ClientMediaTransferError.scanPending }
        return .init(mediaID: job.request.mediaID)
    }

    func freezeSend(text: String, mentions: [V2MentionTarget], replyTo: V2MessageReplyReference?, roomID: RoomID, attachments: [V2StagedConversationAttachment]) async throws {
        try requireOpen()
        return try await operations.run { try await self.performFreezeSend(text: text, mentions: mentions, replyTo: replyTo, roomID: roomID, attachments: attachments) }
    }

    private func performFreezeSend(text: String, mentions: [V2MentionTarget], replyTo: V2MessageReplyReference?, roomID: RoomID, attachments: [V2StagedConversationAttachment]) async throws {
        try requireOpen()
        var jobs: [UUID] = []
        for attachment in attachments {
            jobs.append(try await performPrepare(attachment, usage: .messageAttachment(roomID)))
        }
        let intent = try V2SendIntent(id: UUID(), roomID: roomID, clientMessageID: .init(UUID().uuidString), text: text, mentions: mentions, replyTo: replyTo, attachmentJobIDs: jobs)
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        try await store.freezeSendIntent(intent)
        startRecovery()
    }

    func copyAttachments(sources: [V2ResourceImportSource], to room: RoomID) async throws {
        try requireOpen()
        return try await operations.run { try await self.performCopyAttachments(sources: sources, to: room) }
    }

    private func performCopyAttachments(sources: [V2ResourceImportSource], to room: RoomID) async throws {
        try requireOpen()
        guard !sources.isEmpty, sources.count <= V2MessageCommandLimits.maxMediaAttachments else { throw V2ResourceJournalError.invalidRecord }
        var jobs: [UUID] = []
        for source in sources {
            try Task.checkCancellation()
            let id = UUID()
            let request = try V2ResourceImportRequest(operationID: .init(id.uuidString), source: source, targetUsage: .messageAttachment(room), targetMediaID: .init(UUID().uuidString))
            try requireOpen()
            try await store.prepareResourceImport(id: id, request: request)
            jobs.append(id)
        }
        let intent = try V2SendIntent(id: UUID(), roomID: room, clientMessageID: .init(UUID().uuidString), text: "", attachmentJobIDs: jobs)
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        try await store.freezeSendIntent(intent)
        startRecovery()
    }
    private func advanceImport(_ job: V2ResourceImportJob) async throws -> Bool {
        try requireOpen()
        guard !job.cancellationRequested, job.attempts < 5, job.retryAt <= Date() else { return false }
        let status: V2ResourceImportStatus
        if let saved = job.status { status = try await imports.status(saved.locator) }
        else { status = try await imports.create(job.request) }
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

    struct Pending: Identifiable, Sendable {
        let id: UUID
        let text: String
        let completed: Int
        let total: Int
        let status: String
        let canRetry: Bool
        let canCancel: Bool
    }
    func pending(in roomID: RoomID) async throws -> [Pending] {
        try requireOpen()
        return try await operations.run { try await self.performPending(in: roomID) }
    }

    private func performPending(in roomID: RoomID) async throws -> [Pending] {
        try requireOpen()
        var result: [Pending] = []
        for intent in try await store.preparingSendIntents(in: roomID) {
            try requireOpen()
            var jobs: [V2ResourceTransferJob] = []
            var imported: [V2ResourceImportJob] = []
            for id in intent.attachmentJobIDs {
                try requireOpen()
                if let job = try await store.resourceTransfer(id: id) { jobs.append(job) }
                else if let job = try await store.resourceImport(id: id) { imported.append(job) }
            }
            let paused = jobs.contains { $0.stage == .paused } || imported.contains { $0.attempts >= 5 }
            let expired = jobs.contains { $0.stage == .expired || ($0.session?.bindableUntil.map { $0 <= Date() } ?? false) }
            let rejected = jobs.contains { $0.stage == .rejected } || imported.contains { $0.status?.state == .failed }
            let status = expired ? "资源已过期，等待确认终态" : rejected ? "附件未通过安全处理" : paused ? "上传已暂停，可重试" : jobs.contains { $0.stage == .processing } ? "正在安全处理" : "正在准备附件"
            result.append(.init(id: intent.id, text: intent.text, completed: jobs.filter { $0.stage == .ready }.count + imported.filter { $0.status?.state == .ready }.count, total: intent.attachmentJobIDs.count, status: status, canRetry: paused && !expired && !rejected, canCancel: true))
        }
        try requireOpen()
        for submitted in try await store.submittedSendIntents(in: roomID) {
            let status = switch submitted.status {
            case .pending: "正在发送，等待服务器确认"
            case .confirmingOutcome: "正在确认原消息的发送结果"
            case .closed: "服务器已确认这条消息未发送"
            case .rejected: "这条消息未能发送"
            }
            result.append(.init(id: submitted.id,text: submitted.text,completed: 0,total: 0,status: status,
                canRetry: submitted.status == .closed,canCancel: submitted.status == .closed))
        }
        return result
    }
    func retry(intentID: UUID) async throws {
        try requireOpen()
        return try await operations.run { try await self.performRetry(intentID: intentID) }
    }

    private func performRetry(intentID: UUID) async throws {
        try requireOpen()
        guard let intent = try await store.preparingSendIntents().first(where: { $0.id == intentID }) else {
            try requireOpen()
            _ = try await store.replacePermanentlyClosedSendIntent(intentID)
            startRecovery()
            return
        }
        for id in intent.attachmentJobIDs {
            try requireOpen()
            try await store.retryResourceTransfer(id: id)
            try requireOpen()
            try await store.retryResourceImport(id: id)
        }
        startRecovery()
    }
    func cancel(intentID: UUID) async throws {
        try requireOpen()
        return try await operations.run { try await self.performCancel(intentID: intentID) }
    }

    private func performCancel(intentID: UUID) async throws {
        try requireOpen()
        guard let intent = try await store.preparingSendIntents().first(where: { $0.id == intentID }) else {
            try requireOpen()
            try await store.abandonPermanentlyClosedSendIntent(intentID)
            try await engine.releaseAcceptedStaging()
            return
        }
        // Stop any future handoff before cancelling a remote transfer.
        try requireOpen()
        try await store.cancelSendIntent(intentID)
        for id in intent.attachmentJobIDs {
            if try await store.resourceImport(id: id) != nil { try await cancelImport(id) }
            else { try await engine.cancel(id: id) }
        }
    }

    func startRecovery() {
        guard !closed, recovery == nil else { return }
        // This task is explicitly owned and drained by the account service.
        recovery = Task { await self.recover() }
    }

    func close() async {
        closed = true
        recovery?.cancel()
        async let drainOperations: Void = operations.close()
        async let drainGroupManagement: Void = groupAvatarManager?.close() ?? ()
        await groupAvatars.close()
        await engine.close()
        await recovery?.value
        recovery = nil
        await drainOperations
        await drainGroupManagement
    }

    private func requireOpen() throws {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
    }

    private func recover() async {
        while !closed && !Task.isCancelled {
            do {
                try await engine.refreshCapabilitiesIfNeeded()
                for intent in try await store.preparingSendIntents() {
                    try Task.checkCancellation()
                    var ready = true
                    for id in intent.attachmentJobIDs {
                        if let imported = try await store.resourceImport(id: id) {
                            do { if try await !advanceImport(imported) { ready = false; break } }
                            catch is CancellationError { throw CancellationError() }
                            catch { try requireOpen(); try await store.pauseResourceImport(id: id); ready = false; break }
                            continue
                        }
                        guard let job = try await store.resourceTransfer(id: id), job.attempts < 5,
                              job.retryAt <= Date(), ![.rejected, .cancelled, .expired].contains(job.stage) else { ready = false; break }
                        do { _ = try await engine.resume(id: id) }
                        catch is CancellationError { throw CancellationError() }
                        catch { ready = false; break }
                    }
                    if ready {
                        do {
                            try requireOpen()
                            _ = try await store.handOffSendIntent(intent.id)
                            try requireOpen()
                            _ = try await outbox.flushOnce()
                        } catch is CancellationError { throw CancellationError() }
                        catch { /* Persisted intent keeps its exact identity for the next pass. */ }
                    }
                }
                try await groupAvatars.recoverOnce()
                try await engine.releaseAcceptedStaging()
                for id in try await store.pendingImportCancellations() {
                    try Task.checkCancellation()
                    do { try await cancelImport(id) }
                    catch is CancellationError { throw CancellationError() }
                    catch { }
                }
                for id in try await store.pendingResourceCancellations() {
                    try Task.checkCancellation()
                    do { try await engine.cancel(id: id) }
                    catch is CancellationError { throw CancellationError() }
                    catch { /* Durable cancellation retries on the next pass. */ }
                }
                try await Task.sleep(for: .seconds(5))
            } catch { if Task.isCancelled || closed { break }; try? await Task.sleep(for: .seconds(5)) }
        }
    }
}
