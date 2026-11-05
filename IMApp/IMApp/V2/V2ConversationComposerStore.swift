import Foundation
import IMV2ClientKit
import IMV2Core
import Observation

/// Owns the editable draft and observes account-owned durable sending work.
/// Timeline refreshes cannot supersede draft restoration or sending authority.
@MainActor
@Observable
final class V2ConversationComposerStore {
    enum SubmissionEffect { case none, refreshTimeline }

    private let roomID: String
    private let isGroupConversation: Bool
    private let sender: (any V2ConversationSending)?
    private let attachmentStager: (any V2ConversationAttachmentStaging)?
    private let resourceSender: (any V2DurableConversationSending)?
    private let publicIdentityResolver: (any V2ConversationPublicIdentityResolving)?
    private let sendingCapabilityReader: (any V2ConversationSendingCapabilityReading)?
    @ObservationIgnored private var didRestoreAttachmentDraft = false
    private var capabilityGeneration = 0

    @ObservationIgnored private var draftRevision: UInt64 = 0
    var draft: String {
        didSet { if oldValue != draft { draftRevision &+= 1 } }
    }
    var mentionHandlesText: String
    private(set) var replyTarget: V2ConversationMessageItem?
    private(set) var attachments: [V2ConversationAttachmentItem] = []
    private(set) var trackedSendIntentID: UUID?
    private(set) var sendFeedback: String?
    private(set) var isSending = false
    private(set) var canSendInDirectConversation: Bool?
    private(set) var availabilityFeedback: String?

    init(roomID: String, kind: V2ConversationKind, sender: (any V2ConversationSending)?,
         attachmentStager: (any V2ConversationAttachmentStaging)?,
         resourceSender: (any V2DurableConversationSending)?,
         publicIdentityResolver: (any V2ConversationPublicIdentityResolving)?,
         sendingCapabilityReader: (any V2ConversationSendingCapabilityReading)?,
         initialDraft: String?, initialMentionHandles: String?) {
        self.roomID = roomID
        isGroupConversation = kind.isGroup
        self.sender = sender
        self.attachmentStager = attachmentStager
        self.resourceSender = resourceSender
        self.publicIdentityResolver = publicIdentityResolver
        self.sendingCapabilityReader = sendingCapabilityReader
        draft = initialDraft ?? ""
        mentionHandlesText = initialMentionHandles ?? ""
    }

    func refreshSendingCapability() async {
        guard !isGroupConversation, let sendingCapabilityReader else { return }
        capabilityGeneration &+= 1
        let generation = capabilityGeneration
        do {
            let capability = try await sendingCapabilityReader.directSendingCapability(in: roomID)
            try Task.checkCancellation()
            guard generation == capabilityGeneration else { return }
            canSendInDirectConversation = capability
            availabilityFeedback = nil
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, generation == capabilityGeneration else { return }
            availabilityFeedback = "无法更新发送权限，请稍后重试。"
        }
    }

    private(set) var pendingResourceSends: [V2DurableConversationSendService.Pending] = []
    private(set) var pendingResourceSendPage=0
    private(set) var hasNextPendingResourceSendPage=false
    func nextPendingResourceSendPage() { guard hasNextPendingResourceSendPage else { return }; pendingResourceSends=[]; hasNextPendingResourceSendPage=false; pendingResourceSendPage += 1 }
    func previousPendingResourceSendPage() { guard pendingResourceSendPage > 0 else { return }; pendingResourceSends=[]; hasNextPendingResourceSendPage=false; pendingResourceSendPage -= 1 }

    func applyPendingPage(_ result: V2DurableConversationSendService.PendingPage) {
        pendingResourceSends = result.items
        hasNextPendingResourceSendPage = result.hasNext
    }

    func pendingObservationFailed() {
        sendFeedback = "发送进度观察已暂停，重新进入会话后可继续查看。"
    }

    func observeResourceSends() async {
        guard let durable = resourceSender, let room = try? RoomID(roomID) else { return }
        do {
            let page=pendingResourceSendPage
            for try await result in durable.pendingPageUpdates(in:room,page:page) {
                try Task.checkCancellation()
                guard page == pendingResourceSendPage else { return }
                applyPendingPage(result)
            }
        } catch is CancellationError { return }
        catch {
            guard !Task.isCancelled else { return }
            pendingObservationFailed()
        }
    }
    func retryResourceSend(_ id: UUID) async {
        guard let durable = resourceSender else { return }
        do { try await durable.retry(intentID: id) }
        catch { sendFeedback = "暂时无法恢复上传。" }
    }
    func cancelResourceSend(_ id: UUID) async {
        guard let durable = resourceSender else { return }
        do { try await durable.cancel(intentID: id); pendingResourceSends.removeAll { $0.id == id } }
        catch is CancellationError { return }
        catch { sendFeedback = "暂时无法取消，原消息和附件仍保留。" }
    }

    func observeSendConfirmation() async {
        guard let id = trackedSendIntentID, let tracking = sender as? any V2ConversationSendTracking else { return }
        do {
            for try await execution in await tracking.sendConfirmations(intentID: id) {
                try Task.checkCancellation()
                guard trackedSendIntentID == id else { return }
                switch execution {
                case .committed: sendFeedback = nil; return
                case .rejected, .conflicted: sendFeedback = "消息发送失败，请查看待处理消息。"; return
                case .closed, .expiredUnsubmitted: sendFeedback = "消息未发送，请查看待处理消息。"; return
                default: break
                }
            }
        } catch is CancellationError { }
        catch { if trackedSendIntentID == id { sendFeedback = "暂时无法确认发送状态，请查看待处理消息。" } }
    }

    private(set) var attachmentImportsInFlight = 0

    func sendDraft() async -> SubmissionEffect {
        guard attachmentImportsInFlight == 0 else { return .none }
        guard await restoreDraft() else { return .none }
        guard attachmentImportsInFlight == 0, !isSending else { return .none }
        guard isGroupConversation || canSendInDirectConversation != false else {
            sendFeedback = "当前无法向此会话发送消息。"
            return .none
        }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return .none }
        guard let sender else {
            sendFeedback = "实时网关尚未可用，无法发送。"
            return .none
        }
        let frozenAttachments = attachments.map(\.attachment)
        guard frozenAttachments.allSatisfy({ $0.availability == .local }) else {
            sendFeedback = "部分附件原件不可用，请移除后重新选择。"; return .none
        }
        let frozenReplyTarget = replyTarget
        let submittedDraftRevision = draftRevision
        isSending = true
        defer { isSending = false }
        do {
            // Resolve all user-entered intent before any attachment transfer.
            // An invalid mention must not spend upload/scan work or alter the
            // staged attachment state.
            let mentions = try await resolvedMentions()
            try Task.checkCancellation()
            if !frozenAttachments.isEmpty {
                guard let durable = resourceSender else {
                    sendFeedback = "附件发送暂不可用。"
                    return .none
                }
                let frozenReply = try frozenReplyTarget.map { try V2MessageReplyReference(messageID: .init($0.id)) }
                try await durable.freezeSend(text: text, mentions: mentions, replyTo: frozenReply, roomID: .init(roomID), attachments: frozenAttachments)
                // The journal now owns these files, including across process death.
                attachments = []
                clearDraft(ifUnchangedSince: submittedDraftRevision)
                mentionHandlesText = ""
                replyTarget = nil
                // The durable pending bubble owns preparation and confirmation progress.
                sendFeedback = nil
                return .none
            }
            let replyTo = try frozenReplyTarget.map { try V2MessageReplyReference(messageID: .init($0.id)) }
            let outcome: V2ConversationSendOutcome
            if let tracking = sender as? any V2ConversationSendTracking {
                trackedSendIntentID = try await tracking.enqueueTracked(text: text, mentions: mentions, entities: [], replyTo: replyTo, roomID: roomID)
                outcome = .queuedForRetry
            } else {
                outcome = try await sender.send(text: text, media: [], mentions: mentions, entities: [], replyTo: replyTo, in: roomID)
            }
            try Task.checkCancellation()
            switch outcome {
            case .accepted:
                sendFeedback = "已发送，正在同步。"
                await discardAttachmentsAfterDurableSend()
                clearDraft(ifUnchangedSince: submittedDraftRevision)
                mentionHandlesText = ""
                replyTarget = nil
            case .queuedForRetry:
                // Tracked sends display their progress on the pending message row.
                sendFeedback = sender is any V2ConversationSendTracking ? nil : "已安全保存，连接恢复后会重试。"
                await discardAttachmentsAfterDurableSend()
                clearDraft(ifUnchangedSince: submittedDraftRevision)
                mentionHandlesText = ""
                replyTarget = nil
            case .rejected(let code):
                sendFeedback = Self.sendRejectionFeedback(for: code)
            }
            return .refreshTimeline
        } catch is CancellationError {
            return .none
        } catch is V2ConversationMentionInputError {
            return .none
        } catch V2ResourceCapabilityError.fileTooLarge(let maximumBytes) {
            sendFeedback = "当前服务支持的附件上限为 \(ByteCountFormatter.string(fromByteCount: maximumBytes, countStyle: .file))。"
        } catch V2ResourceCapabilityError.usageUnavailable {
            sendFeedback = "当前服务暂未开放这种资源用途。"
        } catch V2ResourceCapabilityError.uploadModeUnavailable {
            sendFeedback = "当前服务暂不支持此设备的上传方式。"
        } catch V2ResourceJournalError.capacityExceeded {
            sendFeedback = "待处理附件已达上限，请先完成或取消部分任务。当前输入和附件已保留。"
        } catch {
            sendFeedback = "无法保存待发送消息。"
        }
        return .none
    }

    private func clearDraft(ifUnchangedSince revision: UInt64) {
        // A durable save may suspend while the focused input accepts the next draft.
        guard draftRevision == revision else { return }
        draft = ""
    }

    func beginReply(to message: V2ConversationMessageItem) {
        guard !message.isWithdrawn else { return }
        replyTarget = message
    }

    func cancelReply() {
        replyTarget = nil
    }

    private func resolvedMentions() async throws -> [V2MentionTarget] {
        let handles = mentionHandlesText
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !handles.isEmpty else { return [] }
        guard isGroupConversation else {
            sendFeedback = "仅群聊支持提及成员。"
            throw V2ConversationMentionInputError.invalidInput
        }
        guard handles.count <= V2MessageCommandLimits.maxMentions else {
            sendFeedback = "每条消息最多提及 \(V2MessageCommandLimits.maxMentions) 个目标。"
            throw V2ConversationMentionInputError.invalidInput
        }
        var mentions: [V2MentionTarget] = []
        for handle in handles {
            if handle.lowercased() == "@all" {
                mentions.append(.everyone)
                continue
            }
            // `@all` is a protocol-level target and needs no directory
            // lookup. Only exact member handles depend on that availability.
            guard let publicIdentityResolver else {
                sendFeedback = "身份目录暂不可用，无法解析提及对象。"
                throw V2ConversationMentionInputError.invalidInput
            }
            do {
                let identity = try await publicIdentityResolver.resolve(handle: handle)
                mentions.append(.user(identity.userID))
                try Task.checkCancellation()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Exact-handle lookup is deliberately opaque: do not reveal
                // whether the target is absent, blocked, or unavailable.
                sendFeedback = "无法解析提及对象，请检查公开 ID 后重试。"
                throw V2ConversationMentionInputError.invalidInput
            }
        }
        guard Set(mentions).count == mentions.count else {
            sendFeedback = "提及对象不能重复。"
            throw V2ConversationMentionInputError.invalidInput
        }
        return mentions
    }

    private static func sendRejectionFeedback(for code: String) -> String {
        switch code {
        case "RATE_LIMITED":
            return "发送失败：发送频率已达上限，请稍后再试。"
        case "FORBIDDEN", "DIRECT_MESSAGE_RESTRICTED":
            // Do not disclose whether the receiver disabled stranger messages,
            // blocked the sender, or a separate room policy denied the action.
            return "当前无法向此会话发送消息。"
        case "MEDIA_UNAVAILABLE":
            return "附件暂不可用，请重新上传后再试。"
        case "NOT_FOUND":
            return "此会话已不可用，请返回会话列表刷新后再试。"
        default:
            return "发送被拒绝（\(code)）。"
        }
    }

    var canAddAttachment: Bool {
        !isSending
            && attachmentImportsInFlight == 0
            && (isGroupConversation || canSendInDirectConversation != false)
            && attachments.count < V2MessageCommandLimits.maxMediaAttachments
            && !attachments.contains(where: { $0.state == .uploading })
    }

    func stageAttachment(from sourceURL: URL) async {
        await stageAttachment(.file(sourceURL))
    }

    func stageAttachment(photo: V2NormalizedPhoto) async {
        await stageAttachment(.photo(photo))
    }

    private enum AttachmentImportSource { case file(URL), photo(V2NormalizedPhoto) }

    private func stageAttachment(_ source: AttachmentImportSource) async {
        guard await restoreDraft() else { return }
        guard canAddAttachment else {
            sendFeedback = "每条消息最多可添加 \(V2MessageCommandLimits.maxMediaAttachments) 个附件。"
            return
        }
        guard let attachmentStager else {
            sendFeedback = "附件暂不可用。"
            return
        }
        attachmentImportsInFlight += 1
        defer { attachmentImportsInFlight -= 1 }
        do {
            let purpose = V2LocalResourceAssetPurpose.messageDraft(try .init(roomID))
            let attachment: V2StagedConversationAttachment
            switch source {
            case .file(let url): attachment = try await attachmentStager.stageImportedFile(at: url, purpose: purpose)
            case .photo(let photo): attachment = try await attachmentStager.stageNormalizedPhoto(photo, purpose: purpose)
            }
            if Task.isCancelled {
                await attachmentStager.discard(attachment)
                return
            }
            attachments.append(.init(attachment: attachment, state: .staged))
            sendFeedback = nil
        } catch is CancellationError {
            return
        } catch V2ConversationAttachmentStagingError.notRegularFile {
            sendFeedback = "只能添加普通文件。"
        } catch V2ConversationAttachmentStagingError.invalidByteCount {
            sendFeedback = "无法添加空文件。"
        } catch V2ConversationAttachmentStagingError.fileTooLarge {
            sendFeedback = "附件不能超过 50 MB。"
        } catch V2ConversationAttachmentStagingError.stagingQuotaExceeded {
            sendFeedback = "设备上的待上传附件过多，请移除部分附件后重试。"
        } catch {
            sendFeedback = "无法准备附件。"
        }
    }

    @discardableResult
    func restoreDraft() async -> Bool {
        if didRestoreAttachmentDraft { return true }
        guard let attachmentStager else { didRestoreAttachmentDraft = true; return true }
        do {
            let selected = try await attachmentStager.selectedAttachments(purpose: .messageDraft(try .init(roomID)))
            try Task.checkCancellation()
            guard !didRestoreAttachmentDraft else { return true }
            let known = Set(attachments.map { $0.attachment.localAssetID })
            attachments.append(contentsOf: selected.filter { !known.contains($0.localAssetID) }.map {
                .init(attachment: $0, state: $0.availability == .local ? .staged : .failed)
            })
            didRestoreAttachmentDraft = true
            if selected.contains(where: { $0.availability != .local }) { sendFeedback = "部分附件原件不可用，请移除后重新选择。" }
            return true
        } catch is CancellationError { return false }
        catch { sendFeedback = "无法读取本机附件草稿，请重试。"; return false }
    }

    func borrowAttachment(id: UUID) async throws -> V2ResourceFileLease {
        guard let item = attachments.first(where: { $0.id == id }), let attachmentStager else { throw V2ResourceStorageError.unavailable }
        let lease = try await attachmentStager.borrow(.selection(item.attachment.localAssetID))
        guard !Task.isCancelled, attachments.contains(where: { $0.id == id }) else { await lease.release(); throw CancellationError() }
        return lease
    }

    func borrowPendingImage(jobID: UUID) async throws -> V2ResourceFileLease {
        guard pendingResourceSends.contains(where: { $0.images.contains(where: { $0.jobID == jobID }) }),
              let attachmentStager else { throw V2ResourceStorageError.unavailable }
        let lease = try await attachmentStager.borrow(.upload(jobID))
        guard !Task.isCancelled else { await lease.release(); throw CancellationError() }
        return lease
    }

    func removeAttachment(id: UUID) async {
        guard !isSending else { return }
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        let attachment = attachments.remove(at: index).attachment
        await attachmentStager?.discard(attachment)
    }

    private func discardAttachmentsAfterDurableSend() async {
        let staged = attachments.map(\.attachment)
        attachments = []
        for attachment in staged {
            await attachmentStager?.discard(attachment)
        }
    }


}

private enum V2ConversationMentionInputError: Error, Sendable {
    case invalidInput
}
