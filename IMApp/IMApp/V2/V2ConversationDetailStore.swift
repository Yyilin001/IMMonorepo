import Foundation
import IMV2ClientKit
import IMV2Core
import Observation

@MainActor
@Observable
final class V2ConversationDetailStore {
    enum State: Equatable {
        case loading
        case loaded
        case failed
    }

    private let dataSource: any V2ConversationDataSource
    private let messageSearcher: (any V2ConversationMessageSearching)?
    private let sender: (any V2ConversationSending)?
    private let messageWithdrawer: (any V2MessageWithdrawing)?
    private let messageReactionChanger: (any V2MessageReactionChanging)?
    private let messageEditor: (any V2MessageEditing)?
    private let readReceiptReporter: (any V2ConversationReadReporting)?
    private let messageFavoriter: (any V2MessageFavoriting)?
    private let groupMessagePinner: (any V2GroupMessagePinning)?
    private let messageForwarder: (any V2MessageForwarding)?
    let forwardTargets: [V2ConversationForwardTarget]
    private let groupAnnouncementReader: (any V2GroupAnnouncementReading)?
    private let groupAnnouncementManager: (any V2GroupAnnouncementManaging)?
    private let groupMemberRoleChanger: (any V2GroupMemberRoleChanging)?
    private let groupRolePolicyReader: (any V2GroupRolePolicyReading)?
    private let groupRolePolicyChanger: (any V2GroupRolePolicyChanging)?
    private let groupReadReceiptReader: (any V2GroupReadReceiptReading)?
    private let conversationLiveActivity: (any V2ConversationLiveActivityManaging)?
    private let userID: String
    private let groupMemberDirectory: (any V2GroupMemberDirectoryReading)?
    private let groupMembershipChanger: (any V2GroupMembershipChanging)?
    private let groupMemberMuter: (any V2GroupMemberMuting)?
    private let moderatedGroupMemberRemover: (any V2ModeratedGroupMemberRemoving)?
    private let publicIdentityResolver: (any V2ConversationPublicIdentityResolving)?
    private let attachmentStager: (any V2ConversationAttachmentStaging)?
    private let attachmentUploader: (any V2ConversationAttachmentUploading)?
    private let mediaDownloader: (any V2ConversationMediaDownloading)?
    private let projectionChangeNotifier: V2ProjectionChangeNotifier?
    private let activeHybridGroupSynchronizer: (any V2ActiveHybridGroupSynchronizing)?
    let roomID: String
    let title: String
    let isGroupConversation: Bool
    private(set) var messages: [V2ConversationMessageItem] = []
    private(set) var state: State = .loading
    private(set) var sendFeedback: String?
    private(set) var isSending = false
    private(set) var messageActionFeedback: String?
    private(set) var groupMembers: [V2GroupMemberItem] = []
    private(set) var groupMemberRevision: UInt64?
    private(set) var groupActorRole: String?
    private(set) var canLoadMoreGroupMembers = false
    private(set) var groupMemberFeedback: String?
    private(set) var isLoadingGroupMembers = false
    private(set) var isChangingGroupMembership = false
    private(set) var isApplyingGroupModeration = false
    private(set) var attachments: [V2ConversationAttachmentItem] = []
    private(set) var mediaDownloadStates: [MediaID: V2ConversationMediaDownloadState] = [:]
    private(set) var groupReadReceiptPage: V2ReadReceiptReadersPage?
    private(set) var isLoadingGroupReadReceipts = false
    private(set) var groupReadReceiptFeedback: String?
    private var groupReadReceiptMessageID: String?
    private var typingLeaseTask: Task<Void, Never>?
    /// One expiry task per remote user.  The wire expiry is authoritative: a
    /// disconnect can lose the trailing `isTyping = false` event.
    private var typingExpiryTasks: [UserID: Task<Void, Never>] = [:]
    private var typingExpiryDates: [UserID: Date] = [:]
    private(set) var peerPresence: V2PresenceState?
    private(set) var typingUserIDs: Set<UserID> = []
    private var nextGroupMemberCursor: String?
    private var refreshGeneration = 0
    private var inFlightMessageActionIDs: Set<String> = []
    private(set) var isSelectingMessagesForForward = false
    private(set) var selectedForwardMessageIDs: Set<String> = []
    private(set) var isForwardingMessages = false
    private(set) var groupAnnouncement: V2ClientGroupAnnouncement?
    private(set) var isSavingGroupAnnouncement = false
    private(set) var groupRolePolicies: [V2ClientGroupRolePolicy] = []
    private(set) var isLoadingGroupRolePolicies = false
    private(set) var isSavingGroupRolePolicy = false
    var draft = ""
    var mentionHandlesText = ""
    private(set) var replyTarget: V2ConversationMessageItem?

    let reactionPresets = ["👍", "❤️", "😂", "🎉", "😢", "😡"]

    init(dataSource: any V2ConversationDataSource, messageSearcher: (any V2ConversationMessageSearching)? = nil, sender: (any V2ConversationSending)?, messageWithdrawer: (any V2MessageWithdrawing)? = nil, messageReactionChanger: (any V2MessageReactionChanging)? = nil, messageEditor: (any V2MessageEditing)? = nil, readReceiptReporter: (any V2ConversationReadReporting)? = nil, messageFavoriter: (any V2MessageFavoriting)? = nil, groupMessagePinner: (any V2GroupMessagePinning)? = nil, messageForwarder: (any V2MessageForwarding)? = nil, forwardTargets: [V2ConversationForwardTarget] = [], groupAnnouncementReader: (any V2GroupAnnouncementReading)? = nil, groupAnnouncementManager: (any V2GroupAnnouncementManaging)? = nil, groupMemberRoleChanger: (any V2GroupMemberRoleChanging)? = nil, groupRolePolicyReader: (any V2GroupRolePolicyReading)? = nil, groupRolePolicyChanger: (any V2GroupRolePolicyChanging)? = nil, groupReadReceiptReader: (any V2GroupReadReceiptReading)? = nil, conversationLiveActivity: (any V2ConversationLiveActivityManaging)? = nil, userID: String, roomID: String, title: String = "会话", isGroupConversation: Bool = false, groupMemberDirectory: (any V2GroupMemberDirectoryReading)? = nil, groupMembershipChanger: (any V2GroupMembershipChanging)? = nil, groupMemberMuter: (any V2GroupMemberMuting)? = nil, moderatedGroupMemberRemover: (any V2ModeratedGroupMemberRemoving)? = nil, publicIdentityResolver: (any V2ConversationPublicIdentityResolving)? = nil, attachmentStager: (any V2ConversationAttachmentStaging)? = nil, attachmentUploader: (any V2ConversationAttachmentUploading)? = nil, mediaDownloader: (any V2ConversationMediaDownloading)? = nil, projectionChangeNotifier: V2ProjectionChangeNotifier? = nil, activeHybridGroupSynchronizer: (any V2ActiveHybridGroupSynchronizing)? = nil, initialDraft: String? = nil, initialMentionHandles: String? = nil) {
        self.dataSource = dataSource
        self.messageSearcher = messageSearcher
        self.sender = sender
        self.messageWithdrawer = messageWithdrawer
        self.messageReactionChanger = messageReactionChanger
        self.messageEditor = messageEditor
        self.readReceiptReporter = readReceiptReporter
        self.messageFavoriter = messageFavoriter
        self.groupMessagePinner = groupMessagePinner
        self.messageForwarder = messageForwarder
        self.forwardTargets = forwardTargets
        self.groupAnnouncementReader = groupAnnouncementReader
        self.groupAnnouncementManager = groupAnnouncementManager
        self.groupMemberRoleChanger = groupMemberRoleChanger
        self.groupRolePolicyReader = groupRolePolicyReader
        self.groupRolePolicyChanger = groupRolePolicyChanger
        self.groupReadReceiptReader = groupReadReceiptReader
        self.conversationLiveActivity = conversationLiveActivity
        self.userID = userID
        self.roomID = roomID
        self.title = title
        self.isGroupConversation = isGroupConversation
        self.groupMemberDirectory = groupMemberDirectory
        self.groupMembershipChanger = groupMembershipChanger
        self.groupMemberMuter = groupMemberMuter
        self.moderatedGroupMemberRemover = moderatedGroupMemberRemover
        self.publicIdentityResolver = publicIdentityResolver
        self.attachmentStager = attachmentStager
        self.attachmentUploader = attachmentUploader
        self.mediaDownloader = mediaDownloader
        self.projectionChangeNotifier = projectionChangeNotifier
        self.activeHybridGroupSynchronizer = activeHybridGroupSynchronizer
        draft = initialDraft ?? ""
        mentionHandlesText = initialMentionHandles ?? ""
    }

    func messageSearchStore() -> V2ConversationSearchStore? {
        guard let messageSearcher, let roomID = try? RoomID(roomID) else { return nil }
        return .init(searcher: messageSearcher, scope: .room(roomID))
    }

    func refresh() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        state = .loading
        do {
            let refreshedMessages = try await dataSource.messages(in: roomID, for: userID)
            let refreshedAnnouncement: V2ClientGroupAnnouncement? = if isGroupConversation, let groupAnnouncementReader {
                try await groupAnnouncementReader.groupAnnouncement(in: roomID)
            } else {
                nil
            }
            try Task.checkCancellation()
            guard generation == refreshGeneration else { return }
            messages = refreshedMessages
            groupAnnouncement = refreshedAnnouncement
            let visibleMediaIDs = Set(refreshedMessages.lazy
                .filter { !$0.isWithdrawn }
                .flatMap(\.media)
                .map(\.mediaID))
            mediaDownloadStates = mediaDownloadStates.filter { visibleMediaIDs.contains($0.key) }
            state = .loaded
        } catch is CancellationError {
            return
        } catch {
            guard generation == refreshGeneration else { return }
            state = .failed
        }
    }

    func observeProjectionChanges() async {
        guard let projectionChangeNotifier else {
            await refresh()
            return
        }
        for await _ in await projectionChangeNotifier.updates() {
            await refresh()
        }
    }

    /// This task is owned by the detail view's `.task` modifier, so it stops
    /// automatically when the user leaves the conversation or the scene tears
    /// down. Production rooms wait for a server wake on the existing TLS
    /// connection; a 30-second cursor pull remains only as loss recovery.
    func pollVisibleHybridGroupEvents() async {
        guard isGroupConversation,
              let activeHybridGroupSynchronizer
        else { return }
        let subscription: V2ActiveHybridGroupSubscriptionOutcome
        do {
            subscription = try await activeHybridGroupSynchronizer.subscribe(roomID: roomID)
        } catch is CancellationError {
            return
        } catch {
            // The transient recovery path below still preserves local history
            // while the foreground connection is being re-established.
            await pollHybridGroupFallback(activeHybridGroupSynchronizer)
            return
        }
        switch subscription {
        case .notHybridRoom:
            return
        case .subscribed:
            await runSubscribedHybridGroup(activeHybridGroupSynchronizer)
            await activeHybridGroupSynchronizer.unsubscribe(roomID: roomID)
        }
    }

    private func runSubscribedHybridGroup(_ synchronizer: any V2ActiveHybridGroupSynchronizing) async {
        while !Task.isCancelled {
            let shouldContinue = await synchronizeHybridGroupUntilIdle(synchronizer)
            guard shouldContinue else { return }
            do {
                let wake = try await nextHybridWakeOrFallback(synchronizer)
                if let wake, wake.roomID != roomID {
                    continue
                }
            } catch is CancellationError {
                return
            } catch {
                // A broken connection may fail immediately. Slow only this
                // failure path so it cannot become a hot sync loop; normal
                // foreground delivery still waits for a TLS wake.
                await waitAfterRealtimeWakeFailure()
            }
        }
    }

    /// Existing injected fakes and deliberately unavailable realtime paths use
    /// the same durable sync engine at a much lower cadence. It is never the
    /// normal online Hybrid delivery path.
    private func pollHybridGroupFallback(_ synchronizer: any V2ActiveHybridGroupSynchronizing) async {
        while !Task.isCancelled {
            let shouldContinue = await synchronizeHybridGroupUntilIdle(synchronizer)
            guard shouldContinue else { return }
            do {
                try await Task.sleep(for: .seconds(30))
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func synchronizeHybridGroupUntilIdle(_ synchronizer: any V2ActiveHybridGroupSynchronizing) async -> Bool {
        while !Task.isCancelled {
            do {
                switch try await synchronizer.synchronizeOnePage(roomID: roomID) {
                case .notHybridRoom:
                    return false
                case .synchronized(let appliedEventCount, let hasMore):
                    if appliedEventCount > 0 {
                        await projectionChangeNotifier?.publish()
                    }
                    if hasMore {
                        await Task.yield()
                    } else {
                        return true
                    }
                }
            } catch is CancellationError {
                return false
            } catch {
                return true
            }
        }
        return false
    }

    /// A broker wake gives normal foreground latency. The timer only recovers
    /// a lost best-effort wake and is deliberately not a one-second poll.
    private func nextHybridWakeOrFallback(_ synchronizer: any V2ActiveHybridGroupSynchronizing) async throws -> V2ActiveHybridGroupWake? {
        try await withThrowingTaskGroup(of: V2ActiveHybridGroupWake?.self) { group in
            group.addTask { try await synchronizer.nextWake() }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                return nil
            }
            guard let result = try await group.next() else { throw CancellationError() }
            group.cancelAll()
            return result
        }
    }

    private func waitAfterRealtimeWakeFailure() async {
        do {
            try await Task.sleep(for: .seconds(1))
        } catch {
            // The owning detail-view task will exit on cancellation.
        }
    }

    /// Called by a lazily-rendered row only after it has entered the visible
    /// scroll viewport. The durable outbox coalesces repeated appearances.
    func reportVisibleMessage(_ message: V2ConversationMessageItem) async {
        guard let readReceiptReporter else { return }
        do {
            _ = try await readReceiptReporter.recordReadThrough(roomID: roomID, roomSequence: message.roomSequence)
        } catch is CancellationError {
            return
        } catch {
            // Reading local history must remain available even if the durable
            // receipt queue cannot currently accept an update.
        }
    }

    /// Owned by the detail view's task. Live activity is ephemeral and must
    /// be stopped when the view disappears; message refresh remains separate.
    func observeLiveActivity() async {
        guard let conversationLiveActivity else { return }
        let includesPresence = !isGroupConversation
        do {
            peerPresence = try await conversationLiveActivity.activate(roomID: roomID, includesPresence: includesPresence)
            while !Task.isCancelled {
                switch try await conversationLiveActivity.nextEvent() {
                case .presence(let presence):
                    guard presence.roomID.rawValue == roomID else { continue }
                    peerPresence = presence
                case .typing(let typing):
                    guard typing.roomID.rawValue == roomID, typing.userID.rawValue != userID else { continue }
                    applyTypingState(typing)
                }
            }
        } catch is CancellationError {
            // Fall through to stop this view's ephemeral subscriptions.
        } catch {
            // Live activity is intentionally best-effort. The detail view and
            // durable message sync remain usable if a transient stream fails.
            peerPresence = nil
            typingUserIDs = []
        }
        let hadTypingLease = typingLeaseTask != nil
        typingLeaseTask?.cancel()
        typingLeaseTask = nil
        clearTypingStates()
        if hadTypingLease {
            // Best effort only; the receiver-side TTL remains the recovery
            // mechanism when the socket is already gone.
            try? await conversationLiveActivity.setTyping(roomID: roomID, isTyping: false)
        }
        await conversationLiveActivity.deactivate(roomID: roomID, includesPresence: includesPresence)
    }

    /// Applies a wire event and owns the receiver-side expiry. Kept separate
    /// from the stream loop so tests can exercise the lease boundary without
    /// a real socket.
    func applyTypingState(_ typing: V2TypingState, now: Date = Date()) {
        guard typing.roomID.rawValue == roomID, typing.userID.rawValue != userID else { return }
        typingExpiryTasks[typing.userID]?.cancel()
        typingExpiryTasks.removeValue(forKey: typing.userID)
        typingExpiryDates.removeValue(forKey: typing.userID)
        guard typing.isTyping, typing.expiresAt > now else {
            typingUserIDs.remove(typing.userID)
            return
        }
        typingUserIDs.insert(typing.userID)
        let userID = typing.userID
        let expiry = typing.expiresAt
        typingExpiryDates[userID] = expiry
        typingExpiryTasks[userID] = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(max(0, expiry.timeIntervalSinceNow)))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.expireTypingState(for: userID, expectedExpiry: expiry)
        }
    }

    func expireTypingState(for userID: UserID, expectedExpiry: Date) {
        guard typingExpiryDates[userID] == expectedExpiry else { return }
        typingExpiryTasks[userID] = nil
        typingExpiryDates[userID] = nil
        typingUserIDs.remove(userID)
    }

    private func clearTypingStates() {
        for task in typingExpiryTasks.values { task.cancel() }
        typingExpiryTasks.removeAll()
        typingExpiryDates.removeAll()
        typingUserIDs.removeAll()
    }

    func updateTypingForDraft() {
        guard conversationLiveActivity != nil else { return }
        let shouldType = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if shouldType, typingLeaseTask == nil {
            let roomID = roomID
            let activity = conversationLiveActivity
            typingLeaseTask = Task {
                guard let activity else { return }
                while !Task.isCancelled {
                    do {
                        try await activity.setTyping(roomID: roomID, isTyping: true)
                        try await Task.sleep(for: .seconds(4))
                    } catch is CancellationError {
                        return
                    } catch {
                        return
                    }
                }
            }
        } else if !shouldType, let typingLeaseTask {
            typingLeaseTask.cancel()
            self.typingLeaseTask = nil
            let roomID = roomID
            let activity = conversationLiveActivity
            Task {
                try? await activity?.setTyping(roomID: roomID, isTyping: false)
            }
        }
    }

    func loadGroupReadReceipts(for message: V2ConversationMessageItem, reset: Bool = false) async {
        guard isGroupConversation, message.isOutgoing, !message.isWithdrawn,
              let groupReadReceiptReader, !isLoadingGroupReadReceipts
        else { return }
        let isNewMessage = groupReadReceiptMessageID != message.id
        if !reset, !isNewMessage, groupReadReceiptPage?.nextCursor == nil { return }
        isLoadingGroupReadReceipts = true
        defer { isLoadingGroupReadReceipts = false }
        do {
            let cursor = reset || isNewMessage ? nil : groupReadReceiptPage?.nextCursor
            let page = try await groupReadReceiptReader.readers(
                roomID: roomID,
                messageRoomSequence: message.roomSequence,
                cursor: cursor
            )
            try Task.checkCancellation()
            guard page.roomID.rawValue == roomID, page.messageRoomSequence == message.roomSequence else {
                groupReadReceiptFeedback = "已读详情返回异常，请稍后重试。"
                return
            }
            if reset || isNewMessage {
                groupReadReceiptMessageID = message.id
                groupReadReceiptPage = page
            } else if let existing = groupReadReceiptPage {
                let known = Set(existing.readers.map(\.userID))
                let incoming = Set(page.readers.map(\.userID))
                guard known.isDisjoint(with: incoming) else {
                    groupReadReceiptFeedback = "已读详情返回重复数据，请刷新后重试。"
                    return
                }
                groupReadReceiptPage = try .init(
                    roomID: page.roomID,
                    messageRoomSequence: page.messageRoomSequence,
                    readerCount: page.readerCount,
                    readers: existing.readers + page.readers,
                    nextCursor: page.nextCursor
                )
            }
            groupReadReceiptFeedback = nil
        } catch is CancellationError {
            return
        } catch {
            groupReadReceiptFeedback = "无法读取已读详情，请检查网络后重试。"
        }
    }

    func sendDraft() async {
        guard !isSending else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        guard let sender else {
            sendFeedback = "实时网关尚未可用，无法发送。"
            return
        }
        isSending = true
        defer { isSending = false }
        do {
            // Resolve all user-entered intent before any attachment transfer.
            // An invalid mention must not spend upload/scan work or alter the
            // staged attachment state.
            let mentions = try await resolvedMentions()
            try Task.checkCancellation()
            guard await uploadPendingAttachments() else { return }
            let media = attachments.compactMap { item -> V2MediaReference? in
                guard case .available(let reference) = item.state else { return nil }
                return reference
            }
            guard media.count == attachments.count else {
                sendFeedback = "附件尚未准备完成。"
                return
            }
            let replyTo = replyTarget.flatMap { try? V2MessageReplyReference(messageID: .init($0.id)) }
            let outcome = try await sender.send(text: text, media: media, mentions: mentions, entities: [], replyTo: replyTo, in: roomID)
            try Task.checkCancellation()
            switch outcome {
            case .accepted:
                sendFeedback = "已发送，正在同步。"
                await discardAttachmentsAfterDurableSend()
                draft = ""
                mentionHandlesText = ""
                replyTarget = nil
            case .queuedForRetry:
                sendFeedback = "已安全保存，连接恢复后会重试。"
                await discardAttachmentsAfterDurableSend()
                draft = ""
                mentionHandlesText = ""
                replyTarget = nil
            case .rejected(let code):
                sendFeedback = Self.sendRejectionFeedback(for: code)
            }
            await refresh()
        } catch is CancellationError {
            return
        } catch is V2ConversationMentionInputError {
            return
        } catch {
            sendFeedback = "无法保存待发送消息。"
        }
    }

    func beginReply(to message: V2ConversationMessageItem) {
        guard !message.isWithdrawn else { return }
        replyTarget = message
    }

    func cancelReply() {
        replyTarget = nil
    }

    func replyPreview(for reference: V2MessageReplyReference) -> String {
        guard let target = messages.first(where: { $0.id == reference.messageID.rawValue }) else {
            return "原消息不可用"
        }
        return target.text.isEmpty ? "附件" : target.text
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
        case "FORBIDDEN":
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
            && attachments.count < V2MessageCommandLimits.maxMediaAttachments
            && !attachments.contains(where: { $0.state == .uploading })
    }

    func stageAttachment(from sourceURL: URL) async {
        guard canAddAttachment else {
            sendFeedback = "每条消息最多可添加 \(V2MessageCommandLimits.maxMediaAttachments) 个附件。"
            return
        }
        guard let attachmentStager else {
            sendFeedback = "附件暂不可用。"
            return
        }
        do {
            let attachment = try await attachmentStager.stageImportedFile(at: sourceURL)
            try Task.checkCancellation()
            attachments.append(.init(attachment: attachment, state: .staged))
            sendFeedback = nil
        } catch is CancellationError {
            return
        } catch V2ConversationAttachmentStagingError.notRegularFile {
            sendFeedback = "只能添加普通文件。"
        } catch V2ConversationAttachmentStagingError.invalidByteCount {
            sendFeedback = "无法添加空文件。"
        } catch {
            sendFeedback = "无法准备附件。"
        }
    }

    func removeAttachment(id: UUID) async {
        guard !isSending else { return }
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        let attachment = attachments.remove(at: index).attachment
        await attachmentStager?.discard(attachment)
    }

    private func uploadPendingAttachments() async -> Bool {
        let pendingIDs = attachments.compactMap { item -> UUID? in
            switch item.state {
            case .staged, .failed: return item.id
            case .uploading, .available: return nil
            }
        }
        guard !pendingIDs.isEmpty else {
            return !attachments.contains(where: { $0.state == .uploading })
        }
        guard let attachmentUploader else {
            sendFeedback = "附件上传暂不可用。"
            return false
        }
        for id in pendingIDs {
            guard let index = attachments.firstIndex(where: { $0.id == id }) else { continue }
            let attachment = attachments[index].attachment
            attachments[index].state = .uploading
            do {
                let reference = try await attachmentUploader.upload(attachment)
                try Task.checkCancellation()
                guard let completedIndex = attachments.firstIndex(where: { $0.id == id }) else { continue }
                attachments[completedIndex].state = .available(reference)
            } catch is CancellationError {
                if let cancelledIndex = attachments.firstIndex(where: { $0.id == id }) {
                    attachments[cancelledIndex].state = .staged
                }
                return false
            } catch {
                if let failedIndex = attachments.firstIndex(where: { $0.id == id }) {
                    attachments[failedIndex].state = .failed
                }
                sendFeedback = "附件上传或安全扫描未完成，请稍后重试。"
                return false
            }
        }
        return true
    }

    private func discardAttachmentsAfterDurableSend() async {
        let staged = attachments.map(\.attachment)
        attachments = []
        for attachment in staged {
            await attachmentStager?.discard(attachment)
        }
    }

    func mediaDownloadState(for media: V2MediaReference) -> V2ConversationMediaDownloadState {
        mediaDownloadStates[media.mediaID] ?? .notDownloaded
    }

    func downloadMedia(_ media: V2MediaReference, from message: V2ConversationMessageItem) async {
        guard !message.isWithdrawn, message.media.contains(media) else { return }
        guard let mediaDownloader else {
            messageActionFeedback = "附件下载暂不可用。"
            return
        }
        guard mediaDownloadState(for: media) != .downloading else { return }
        mediaDownloadStates[media.mediaID] = .downloading
        do {
            let downloaded = try await mediaDownloader.download(media)
            try Task.checkCancellation()
            guard messages.contains(where: { !$0.isWithdrawn && $0.media.contains(media) }) else {
                mediaDownloadStates[media.mediaID] = .notDownloaded
                return
            }
            mediaDownloadStates[media.mediaID] = .downloaded(downloaded)
            messageActionFeedback = nil
        } catch is CancellationError {
            mediaDownloadStates[media.mediaID] = .notDownloaded
        } catch {
            mediaDownloadStates[media.mediaID] = .failed
            messageActionFeedback = "附件下载失败，请稍后重试。"
        }
    }

    func canWithdrawMessage(_ message: V2ConversationMessageItem) -> Bool {
        message.isOutgoing && !message.isWithdrawn && message.revision > 0 && !isMessageActionInFlight(message)
    }

    func isMessageActionInFlight(_ message: V2ConversationMessageItem) -> Bool {
        inFlightMessageActionIDs.contains(message.id)
    }

    func withdrawMessage(_ message: V2ConversationMessageItem) async {
        guard canWithdrawMessage(message) else { return }
        guard beginMessageAction(for: message) else { return }
        defer { finishMessageAction(for: message) }
        guard let messageWithdrawer else {
            messageActionFeedback = "撤回暂不可用。"
            return
        }
        do {
            let outcome = try await messageWithdrawer.withdraw(
                messageID: message.id,
                in: roomID,
                expectedMessageRevision: message.revision
            )
            try Task.checkCancellation()
            switch outcome {
            case .accepted:
                messageActionFeedback = "撤回已提交，正在同步。"
                await refresh()
            case .queuedForRetry:
                messageActionFeedback = "撤回请求已安全保存，连接恢复后会重试。"
            case .rejected(let code):
                messageActionFeedback = "撤回被拒绝（\(code)），请刷新后重试。"
            }
        } catch is CancellationError {
            return
        } catch {
            messageActionFeedback = "无法保存撤回请求。"
        }
    }

    func canReactToMessage(_ message: V2ConversationMessageItem) -> Bool {
        !message.isWithdrawn && !isMessageActionInFlight(message)
    }

    func canEditMessage(_ message: V2ConversationMessageItem) -> Bool {
        message.isOutgoing && !message.isWithdrawn && message.revision > 0 && !isMessageActionInFlight(message)
    }

    /// Returns whether it is safe for the editor to close. Rejected commands
    /// leave the text visible so the user can revise or retry it.
    func editMessage(_ message: V2ConversationMessageItem, text: String) async -> Bool {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canEditMessage(message), !trimmedText.isEmpty else { return false }
        guard beginMessageAction(for: message) else { return false }
        defer { finishMessageAction(for: message) }
        guard let messageEditor else {
            messageActionFeedback = "编辑暂不可用。"
            return false
        }
        do {
            let outcome = try await messageEditor.edit(
                messageID: message.id,
                in: roomID,
                expectedMessageRevision: message.revision,
                text: trimmedText
            )
            try Task.checkCancellation()
            switch outcome {
            case .accepted:
                messageActionFeedback = "编辑已提交，正在同步。"
                await refresh()
                return true
            case .queuedForRetry:
                messageActionFeedback = "编辑已安全保存，连接恢复后会重试。"
                return true
            case .rejected(let code):
                messageActionFeedback = "编辑被拒绝（\(code)），请刷新后重试。"
                return false
            }
        } catch is CancellationError {
            return false
        } catch {
            messageActionFeedback = "无法保存编辑。"
            return false
        }
    }

    func changeReaction(_ reaction: String, on message: V2ConversationMessageItem) async {
        guard canReactToMessage(message) else { return }
        guard beginMessageAction(for: message) else { return }
        defer { finishMessageAction(for: message) }
        guard let messageReactionChanger else {
            messageActionFeedback = "反应暂不可用。"
            return
        }
        let action: V2MessageReactionAction = message.reactions.first(where: { $0.reaction == reaction })?.includesCurrentUser == true ? .remove : .add
        do {
            let outcome = try await messageReactionChanger.changeReaction(
                messageID: message.id,
                in: roomID,
                reaction: reaction,
                action: action
            )
            try Task.checkCancellation()
            switch outcome {
            case .accepted:
                messageActionFeedback = "反应已提交，正在同步。"
                await refresh()
            case .queuedForRetry:
                messageActionFeedback = "反应已安全保存，连接恢复后会重试。"
            case .rejected(let code):
                messageActionFeedback = "反应被拒绝（\(code)）。"
            }
        } catch is CancellationError {
            return
        } catch {
            messageActionFeedback = "无法保存反应。"
        }
    }

    func setFavorite(_ message: V2ConversationMessageItem) async {
        guard !message.isWithdrawn, beginMessageAction(for: message) else { return }
        defer { finishMessageAction(for: message) }
        guard let messageFavoriter else { messageActionFeedback = "收藏暂不可用。"; return }
        do {
            let outcome = try await messageFavoriter.setFavorite(roomID: roomID, messageID: message.id, isFavorited: !message.isFavorited)
            try Task.checkCancellation()
            switch outcome {
            case .accepted: messageActionFeedback = message.isFavorited ? "已取消收藏，正在同步。" : "已收藏，正在同步。"; await refresh()
            case .queuedForRetry: messageActionFeedback = "收藏操作已安全保存，连接恢复后会重试。"
            case .rejected(let code): messageActionFeedback = "收藏被拒绝（\(code)）。"
            }
        } catch is CancellationError { return }
        catch { messageActionFeedback = "无法保存收藏操作。" }
    }

    func pinInGroup(_ message: V2ConversationMessageItem) async {
        guard isGroupConversation, !message.isWithdrawn, beginMessageAction(for: message) else { return }
        defer { finishMessageAction(for: message) }
        guard let groupMessagePinner else { messageActionFeedback = "置顶消息暂不可用。"; return }
        do {
            switch try await groupMessagePinner.setPinned(roomID: roomID, messageID: message.id, isPinned: !message.isPinnedInGroup) {
            case .accepted: messageActionFeedback = message.isPinnedInGroup ? "已取消置顶，正在同步。" : "消息已置顶，正在同步。"; await refresh()
            case .queuedForRetry: messageActionFeedback = "置顶操作已安全保存，连接恢复后会重试。"
            case .rejected(let code): messageActionFeedback = "置顶消息被拒绝（\(code)）。"
            }
        } catch is CancellationError { return }
        catch { messageActionFeedback = "无法置顶消息。" }
    }

    func beginForwardSelection(with message: V2ConversationMessageItem? = nil) {
        isSelectingMessagesForForward = true
        if let message { toggleForwardSelection(for: message) }
    }

    func endForwardSelection() {
        isSelectingMessagesForForward = false
        selectedForwardMessageIDs.removeAll()
    }

    func toggleForwardSelection(for message: V2ConversationMessageItem) {
        guard !message.isWithdrawn else { return }
        if selectedForwardMessageIDs.contains(message.id) {
            selectedForwardMessageIDs.remove(message.id)
        } else if selectedForwardMessageIDs.count < V2ForwardMessagesCommand.maximumSourceMessages {
            selectedForwardMessageIDs.insert(message.id)
        } else {
            messageActionFeedback = "一次最多转发 \(V2ForwardMessagesCommand.maximumSourceMessages) 条消息。"
        }
    }

    func selectedForForward(_ message: V2ConversationMessageItem) -> Bool {
        selectedForwardMessageIDs.contains(message.id)
    }

    /// Returns `true` once the destination sheet may safely dismiss.  A
    /// queued command is durable, so it is also safe to leave the sheet then.
    func forwardSelectedMessages(to targetRoomIDs: [String]) async -> Bool {
        guard !isForwardingMessages else { return false }
        let sourceMessageIDs = messages
            .filter { selectedForwardMessageIDs.contains($0.id) && !$0.isWithdrawn }
            .map(\.id)
        guard !sourceMessageIDs.isEmpty else {
            messageActionFeedback = "请选择要转发的消息。"
            return false
        }
        guard !targetRoomIDs.isEmpty else {
            messageActionFeedback = "请选择至少一个目标会话。"
            return false
        }
        guard let messageForwarder else {
            messageActionFeedback = "转发暂不可用。"
            return false
        }
        isForwardingMessages = true
        defer { isForwardingMessages = false }
        do {
            switch try await messageForwarder.forward(sourceMessageIDs: sourceMessageIDs, targetRoomIDs: targetRoomIDs) {
            case .completed(let succeeded, let failed):
                if failed == 0 {
                    messageActionFeedback = "已转发 \(succeeded) 条消息，正在同步。"
                } else {
                    messageActionFeedback = "已转发 \(succeeded) 条；\(failed) 条未能发送。"
                }
                endForwardSelection()
                await refresh()
                return true
            case .queuedForRetry:
                messageActionFeedback = "转发已安全保存，连接恢复后会重试。"
                endForwardSelection()
                return true
            case .rejected(let code):
                messageActionFeedback = "转发被拒绝（\(code)）。"
                return false
            }
        } catch is CancellationError {
            return false
        } catch {
            messageActionFeedback = "无法保存转发操作。"
            return false
        }
    }

    func saveGroupAnnouncement(_ body: String) async -> Bool {
        guard isGroupConversation, !isSavingGroupAnnouncement else { return false }
        guard let groupAnnouncementManager else {
            messageActionFeedback = "群公告暂不可用。"
            return false
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            messageActionFeedback = "群公告不能为空。"
            return false
        }
        guard trimmed.lengthOfBytes(using: .utf8) <= V2GroupAnnouncementCommand.maximumUTF8Bytes else {
            messageActionFeedback = "群公告不能超过 \(V2GroupAnnouncementCommand.maximumUTF8Bytes) 字节。"
            return false
        }
        isSavingGroupAnnouncement = true
        defer { isSavingGroupAnnouncement = false }
        do {
            switch try await groupAnnouncementManager.setAnnouncement(
                roomID: roomID,
                body: trimmed,
                expectedRevision: groupAnnouncement?.revision ?? 0
            ) {
            case .accepted:
                messageActionFeedback = "群公告已提交，正在同步。"
                await refresh()
                return true
            case .queuedForRetry:
                messageActionFeedback = "群公告已安全保存，连接恢复后会重试。"
                return true
            case .rejected(let code):
                messageActionFeedback = "群公告被拒绝（\(code)）。"
                return false
            }
        } catch is CancellationError {
            return false
        } catch {
            messageActionFeedback = "无法保存群公告。"
            return false
        }
    }

    func loadGroupRolePolicies() async {
        guard isGroupConversation, !isLoadingGroupRolePolicies else { return }
        guard let groupRolePolicyReader else {
            messageActionFeedback = "群权限策略暂不可用。"
            return
        }
        isLoadingGroupRolePolicies = true
        defer { isLoadingGroupRolePolicies = false }
        do {
            groupRolePolicies = try await groupRolePolicyReader.groupRolePolicies(in: roomID)
        } catch is CancellationError {
            return
        } catch {
            messageActionFeedback = "无法读取群权限策略。"
        }
    }

    func saveGroupRolePolicy(_ policy: V2ClientGroupRolePolicy, permissions: Set<V2GroupPermission>) async -> Bool {
        guard !isSavingGroupRolePolicy, policy.role != .owner else { return false }
        guard let groupRolePolicyChanger else {
            messageActionFeedback = "群权限策略暂不可用。"
            return false
        }
        isSavingGroupRolePolicy = true
        defer { isSavingGroupRolePolicy = false }
        do {
            switch try await groupRolePolicyChanger.setPolicy(
                roomID: roomID,
                role: policy.role,
                permissions: permissions,
                expectedRevision: policy.revision
            ) {
            case .accepted:
                messageActionFeedback = "群权限策略已提交，正在同步。"
                await loadGroupRolePolicies()
                return true
            case .queuedForRetry:
                messageActionFeedback = "群权限策略已安全保存，连接恢复后会重试。"
                return true
            case .rejected(let code):
                messageActionFeedback = "群权限策略被拒绝（\(code)）。"
                return false
            }
        } catch is CancellationError {
            return false
        } catch {
            messageActionFeedback = "无法保存群权限策略。"
            return false
        }
    }

    private func beginMessageAction(for message: V2ConversationMessageItem) -> Bool {
        inFlightMessageActionIDs.insert(message.id).inserted
    }

    private func finishMessageAction(for message: V2ConversationMessageItem) {
        inFlightMessageActionIDs.remove(message.id)
    }

    func loadGroupMembers(reset: Bool = false) async {
        guard !isLoadingGroupMembers else { return }
        guard let groupMemberDirectory else {
            groupMemberFeedback = "成员目录暂不可用。"
            return
        }
        let cursor = reset ? nil : nextGroupMemberCursor
        if !reset, cursor == nil, !groupMembers.isEmpty { return }
        isLoadingGroupMembers = true
        defer { isLoadingGroupMembers = false }
        do {
            let page = try await groupMemberDirectory.members(in: roomID, cursor: cursor)
            try Task.checkCancellation()
            if reset {
                groupMembers = []
                groupActorRole = nil
            }
            let known = Set(groupMembers.map(\.id))
            let incoming = Set(page.members.map(\.id))
            guard incoming.count == page.members.count, known.isDisjoint(with: incoming) else {
                groupMemberFeedback = "成员目录返回了重复数据。"
                return
            }
            groupMembers += page.members
            groupMemberRevision = page.membershipRevision
            groupActorRole = page.actorRole
            nextGroupMemberCursor = page.nextCursor
            canLoadMoreGroupMembers = page.nextCursor != nil
            groupMemberFeedback = nil
        } catch is CancellationError {
            return
        } catch {
            groupMemberFeedback = "无法读取群成员，请检查网络后重试。"
        }
    }

    var canAddGroupMembers: Bool {
        groupActorRole == "群主" || groupActorRole == "管理员"
    }

    func canRemoveGroupMember(_ member: V2GroupMemberItem) -> Bool {
        guard member.id != userID, member.role != "群主" else { return false }
        return groupActorRole == "群主" || groupActorRole == "管理员"
    }

    func canChangeGroupMemberRole(_ member: V2GroupMemberItem) -> Bool {
        groupActorRole == "群主" && member.id != userID && member.role != "群主"
    }

    func changeGroupMemberRole(_ member: V2GroupMemberItem, to role: V2RoomMembershipRole) async {
        guard canChangeGroupMemberRole(member),
              let expectedMembershipRevision = groupMemberRevision,
              !isChangingGroupMembership,
              let groupMemberRoleChanger
        else { return }
        let currentRole: V2RoomMembershipRole = member.role == "管理员" ? .admin : .member
        guard currentRole != role else { return }
        isChangingGroupMembership = true
        defer { isChangingGroupMembership = false }
        do {
            switch try await groupMemberRoleChanger.setRole(
                roomID: roomID,
                userID: member.id,
                role: role,
                expectedMembershipRevision: expectedMembershipRevision
            ) {
            case .accepted:
                groupMemberFeedback = "成员角色已提交，正在同步。"
                await loadGroupMembers(reset: true)
            case .queuedForRetry:
                groupMemberFeedback = "成员角色已安全保存，连接恢复后会重试。"
            case .rejected(let code):
                groupMemberFeedback = "成员角色变更被拒绝（\(code)）。"
            }
        } catch is CancellationError {
            return
        } catch {
            groupMemberFeedback = "无法保存成员角色变更。"
        }
    }

    /// Moderation retains its own durable command/audit trail rather than
    /// reusing normal member removal. The server still decides authority and
    /// target eligibility at command acceptance time.
    func muteGroupMember(_ member: V2GroupMemberItem, for duration: TimeInterval = 60 * 60) async {
        guard !isLoadingGroupMembers, !isChangingGroupMembership, !isApplyingGroupModeration,
              canRemoveGroupMember(member)
        else { return }
        guard duration > 0, let groupMemberMuter else {
            groupMemberFeedback = "禁言暂不可用。"
            return
        }
        isApplyingGroupModeration = true
        defer { isApplyingGroupModeration = false }
        do {
            let outcome = try await groupMemberMuter.muteMember(
                roomID: roomID,
                targetUserID: member.id,
                muteUntil: Date().addingTimeInterval(duration),
                reasonCode: try .init("ADMIN_ACTION")
            )
            try Task.checkCancellation()
            switch outcome {
            case .accepted:
                groupMemberFeedback = "禁言已提交，正在同步。"
            case .queuedForRetry:
                groupMemberFeedback = "禁言请求已安全保存，连接恢复后会继续。"
            case .rejected:
                groupMemberFeedback = "无法完成群管理操作。"
            }
        } catch is CancellationError {
            return
        } catch {
            groupMemberFeedback = "无法保存禁言请求。"
        }
    }

    func removeGroupMemberByModerator(_ member: V2GroupMemberItem) async {
        guard !isLoadingGroupMembers, !isChangingGroupMembership, !isApplyingGroupModeration,
              canRemoveGroupMember(member)
        else { return }
        guard let moderatedGroupMemberRemover else {
            groupMemberFeedback = "管理员移除暂不可用。"
            return
        }
        isApplyingGroupModeration = true
        defer { isApplyingGroupModeration = false }
        do {
            let outcome = try await moderatedGroupMemberRemover.removeMemberByModerator(
                roomID: roomID,
                targetUserID: member.id,
                reasonCode: try .init("ADMIN_ACTION")
            )
            try Task.checkCancellation()
            switch outcome {
            case .accepted:
                groupMemberFeedback = "管理员移除已提交，正在同步。"
                await loadGroupMembers(reset: true)
            case .queuedForRetry:
                groupMemberFeedback = "管理员移除已安全保存，连接恢复后会继续。"
            case .rejected:
                groupMemberFeedback = "无法完成群管理操作。"
            }
        } catch is CancellationError {
            return
        } catch {
            groupMemberFeedback = "无法保存管理员移除请求。"
        }
    }

    func changeGroupMembership(targetUserID: String, action: V2RoomMembershipAction) async {
        guard !isLoadingGroupMembers, !isChangingGroupMembership, !isApplyingGroupModeration else {
            return
        }
        let input = targetUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            groupMemberFeedback = action == .add ? "请输入成员公开 ID。" : "请输入成员。"
            return
        }
        guard let revision = groupMemberRevision else {
            groupMemberFeedback = "请先刷新成员目录。"
            return
        }
        guard let groupMembershipChanger else {
            groupMemberFeedback = "成员变更暂不可用。"
            return
        }
        isChangingGroupMembership = true
        defer { isChangingGroupMembership = false }
        do {
            let target: String
            if action == .add {
                guard let publicIdentityResolver else {
                    groupMemberFeedback = "身份目录暂不可用，无法解析成员公开 ID。"
                    return
                }
                target = try await publicIdentityResolver.resolve(handle: input).userID.rawValue
                try Task.checkCancellation()
            } else {
                target = input
            }
            let outcome = try await groupMembershipChanger.changeMembership(
                roomID: roomID,
                targetUserID: target,
                action: action,
                expectedMembershipRevision: revision
            )
            try Task.checkCancellation()
            switch outcome {
            case .accepted:
                groupMemberFeedback = nil
                await loadGroupMembers(reset: true)
            case .queuedForRetry:
                groupMemberFeedback = "成员变更已安全保存，连接恢复后会继续。"
            case .rejected(let code):
                groupMemberFeedback = "成员变更被拒绝（\(code)），请刷新后重试。"
            }
        } catch is CancellationError {
            return
        } catch {
            groupMemberFeedback = "无法保存成员变更。"
        }
    }
}

private enum V2ConversationMentionInputError: Error, Sendable {
    case invalidInput
}
