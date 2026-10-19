import Foundation
import IMV2ClientKit
import IMV2Core
import Observation

@MainActor
@Observable
final class V2ConversationDetailStore {
    private static let initialTimelinePageSize = 80
    private static let timelinePageSize = 80
    /// 混合大群恢复宽限期。
    ///
    /// 仅含元数据的修复唤醒与完整前台载荷可能来自不同的网关发布者。
    /// 一个短且有界的宽限期可以让有序载荷追上来，
    /// 而不至于把这种无害的顺序颠倒变成一次房间日志查询；
    /// 若载荷确实缺失，则仍会在 100 毫秒后回退。
    private static let hybridGroupRecoveryGrace: Duration = .milliseconds(100)
    /// 时间线保留上限。
    ///
    /// 它让 SwiftUI 的差异计算与重复渲染模型保持有界，
    /// 同时仍通过滑动键集窗口允许任意久远的历史。
    private static let maximumRetainedTimelineItems = 800

    enum State: Equatable {
        case loading
        case loaded
        case failed
    }

    private let dataSource: any V2ConversationDataSource
    private let sendingCapabilityReader: (any V2ConversationSendingCapabilityReading)?
    private let messageSearcher: (any V2ConversationMessageSearching)?
    private let sender: (any V2ConversationSending)?
    private let messageWithdrawer: (any V2MessageWithdrawing)?
    private let messageReactionChanger: (any V2MessageReactionChanging)?
    private let messageEditor: (any V2MessageEditing)?
    private let readReceiptReporter: (any V2ConversationReadReporting)?
    private let messageFavoriter: (any V2MessageFavoriting)?
    private let messageModerator: V2MessageModerationOperationService?
    private let groupMessagePinner: (any V2GroupMessagePinning)?
    private let messageForwarder: (any V2MessageForwarding)?
    let forwardTargets: [V2ConversationForwardTarget]
    private let groupAnnouncementReader: (any V2GroupAnnouncementReading)?
    private let groupAnnouncementManager: (any V2GroupAnnouncementManaging)?
    private let groupAvatarManager: (any V2GroupAvatarManaging)?
    private let nameOperations: V2NameOperationService?
    private let groupMemberRoleChanger: (any V2GroupMemberRoleChanging)?
    private let groupRolePolicyReader: (any V2GroupRolePolicyAccessing)?
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
    private let resourceSender: (any V2DurableConversationSending)?
    private let mediaDownloader: (any V2ConversationMediaDownloading)?
    private let projectionChangeNotifier: V2ProjectionChangeNotifier?
    private let roomSubscriptions: V2RoomSubscriptionCoordinator?
    private let activeHybridGroupSynchronizer: (any V2ActiveHybridGroupSynchronizing)?
    let roomID: String
    let presentationKey: V2ProfileViewLookupKey?
    private(set) var title: String
    let kind: V2ConversationKind
    var isGroupConversation: Bool { kind.isGroup }
    var directAccountKind: V2AccountKind? { kind.directAccountKind }

    var authorPresentationContext: V2AuthorPresentationPageScope.Context? {
        guard let roomID = try? RoomID(roomID) else { return nil }
        switch kind {
        case .group: return .group(roomID)
        case .direct:
            guard let actor = try? UserID(userID), let presentationKey else { return nil }
            return .direct(roomID: roomID, actorUserID: actor, peerUserID: presentationKey.userID)
        case .unknown: return nil
        }
    }

    func authorPresentationKey(for message: V2ConversationMessageItem) -> V2ProfileViewLookupKey? {
        guard let sender = message.senderUserID else { return nil }
        return authorPresentationContext?.key(for: sender)
    }
    private(set) var messages: [V2ConversationMessageItem] = []
    private(set) var timeline: [V2ConversationTimelineItem] = []
    private(set) var timelineRevision: UInt64 = 0
    private(set) var canLoadOlderTimeline = false
    /// 该房间的历史是否已被服务端保留裁剪掉一段。
    ///
    /// 缺口永久存在，界面据此在时间线顶部明确告知"更早的消息已不可用"。
    private(set) var isHistoryIncomplete = false
    private(set) var isLoadingOlderTimeline = false
    private(set) var isBrowsingHistoricalTimeline = false
    private(set) var isReturningToLatestTimeline = false
    private(set) var canSendInDirectConversation: Bool?
    private(set) var state: State = .loading
    private(set) var trackedSendIntentID: UUID?
    private(set) var sendFeedback: String?
    private(set) var isSending = false
    private(set) var messageActionFeedback: String?
    private(set) var groupMembers: [V2GroupMemberItem] = []
    private(set) var hasEarlierGroupMembers = false
    private(set) var groupMemberRevision: UInt64?
    private(set) var groupMemberDirectoryIsStale = true
    enum GroupMemberRefreshReason { case userInitiated, authorizationChanged }
    private(set) var groupActorRole: String?
    private(set) var canLoadMoreGroupMembers = false
    private(set) var groupMemberFeedback: String?
    private(set) var isLoadingGroupMembers = false
    private(set) var isChangingGroupMembership = false
    private(set) var isApplyingGroupModeration = false
    private(set) var attachments: [V2ConversationAttachmentItem] = []
    private(set) var mediaDownloadStates: [MediaID: V2ConversationMediaDownloadState] = [:]
    private(set) var groupReadReceiptPage: V2ReadReceiptReadersPage?
    private(set) var hasEarlierGroupReadReceipts = false
    private(set) var isLoadingGroupReadReceipts = false
    private(set) var groupReadReceiptFeedback: String?
    private var groupReadReceiptMessageID: String?
    private var groupReadReceiptDemand = UUID()
    private var groupReadReceiptFlight: (id: UUID, task: Task<V2ReadReceiptReadersPage, Error>)?
    private var typingLeaseTask: Task<Void, Never>?
    private var typingLeaseID: UUID?
    private var activityConsumerID: UUID?
    private var activityConnectionID: UUID?
    /// 每个远端用户各一个到期任务。
    ///
    /// 线路上的到期时间才是权威：连接中断可能丢掉收尾的 `isTyping = false` 事件。
    private var typingExpiryTasks: [UserID: Task<Void, Never>] = [:]
    private var typingExpiryDates: [UserID: Date] = [:]
    private(set) var peerPresence: V2PresenceState?
    private(set) var typingUserIDs: Set<UserID> = []
    private var nextGroupMemberCursor: String?
    private var groupMemberReloadPending = false
    private var refreshGeneration = 0
    private var newerTimelineBoundary: V2ConversationTimelineCursor?
    private var timelineLocationID: UUID?
    private var refreshAfterTimelineLocation = false
    private var inFlightMessageActionIDs: Set<String> = []
    private(set) var isSelectingMessagesForForward = false
    private struct SelectedForwardSource {
        let reference: V2ForwardMessageReference
        let roomSequence: UInt64
    }
    private var selectedForwardSources: [String: SelectedForwardSource] = [:]
    var selectedForwardMessageIDs: Set<String> { Set(selectedForwardSources.keys) }
    private(set) var isForwardingMessages = false
    private(set) var groupAnnouncement: V2ClientGroupAnnouncement?
    private(set) var isSavingGroupAnnouncement = false
    private(set) var groupRolePolicyState = V2ClientGroupRolePolicyState(policies: [], recovery: .needed)
    var groupRolePolicies: [V2ClientGroupRolePolicy] { groupRolePolicyState.policies }
    enum PolicyRecoveryAction: Equatable { case idle, requesting, failed }
    private(set) var policyRecoveryAction = PolicyRecoveryAction.idle
    private var rolePolicyReadGeneration: UInt64 = 0
    private(set) var isLoadingGroupRolePolicies = false
    private(set) var isSavingGroupRolePolicy = false
    var draft = ""
    var mentionHandlesText = ""
    private(set) var replyTarget: V2ConversationMessageItem?

    private(set) var readSyncArchiveCandidate: UUID?
    private(set) var readSyncArchives: [V2ReadReceiptArchive] = []
    private(set) var readSyncNeedsAttention = false
    private(set) var isResumingReadSync = false
    private(set) var readSyncFeedback: String?
    func observeReadSync() async {
        guard let manager = readReceiptReporter as? any V2ConversationReadSyncManaging else { return }
        do {
            for try await snapshot in try await manager.readSyncUpdates(roomID:roomID) {
                try Task.checkCancellation()
                let work = snapshot.work
                readSyncNeedsAttention = work?.scheduling == .needsAttention
                let canArchive = work?.lastErrorCode == "READ_RECEIPT_CURRENT_UNAVAILABLE"
                    || work?.lastErrorCode == "READ_RECEIPT_CONTROL_CAPACITY_REQUIRED"
                readSyncArchiveCandidate = readSyncNeedsAttention && work?.submissionStarted == true
                    && canArchive ? work?.id : nil
                readSyncArchives = snapshot.archives
                if !readSyncNeedsAttention {
                    readSyncFeedback = nil
                } else if work?.lastErrorCode == "READ_RECEIPT_CONTROL_CAPACITY_REQUIRED" {
                    readSyncFeedback = "待同步任务已满，原记录仍保留。你可以稍后继续核对，或重新归档。"
                }
            }
        } catch is CancellationError { }
        catch { readSyncFeedback = "无法读取已读同步状态。" }
    }
    func resumeReadSync() async {
        guard readSyncNeedsAttention, !isResumingReadSync,
              let manager = readReceiptReporter as? any V2ConversationReadSyncManaging else { return }
        isResumingReadSync = true
        defer { isResumingReadSync = false }
        do { try await manager.resumeReadConfirmation(roomID:roomID); readSyncFeedback = nil }
        catch { readSyncFeedback = "无法继续确认已读状态，请稍后重试。" }
    }

    func archiveUnavailableReadSync() async {
        guard let id = readSyncArchiveCandidate, !isResumingReadSync,
              let manager = readReceiptReporter as? any V2ConversationReadSyncManaging else { return }
        isResumingReadSync = true
        defer { isResumingReadSync = false }
        do {
            try await manager.archiveUnavailableRead(workID: id)
            readSyncFeedback = nil
        } catch V2OperationWorkError.capacityExceeded {
            readSyncFeedback = "归档空间已满，原操作仍保留。请恢复已有归档继续核对。"
        } catch { readSyncFeedback = "无法归档，原操作仍保留。" }
    }
    func restoreReadSyncArchive(_ id: UUID) async {
        guard !isResumingReadSync,
              let manager = readReceiptReporter as? any V2ConversationReadSyncManaging else { return }
        isResumingReadSync = true
        defer { isResumingReadSync = false }
        do {
            try await manager.restoreReadArchive(workID: id)
            readSyncFeedback = nil
        } catch V2OperationWorkError.capacityExceeded {
            readSyncFeedback = "核对队列已满，归档记录仍保留。请先处理已有核对任务。"
        } catch { readSyncFeedback = "暂时无法恢复核对，归档记录仍保留。" }
    }

    var hasGroupAvatarManagement: Bool { isGroupConversation && groupAvatarManager != nil && attachmentStager != nil }
    private(set) var messageMutations:[V2MessageMutationSnapshot] = []
    private(set) var mutationSyncFeedback:String?
    private(set) var resumingMutationID:UUID?
    func observeMessageMutations() async {
        guard let manager=messageEditor as? any V2MessageMutationManaging else { return }
        do {
            for try await snapshots in try await manager.mutationUpdates(roomID:roomID) {
                try Task.checkCancellation()
                messageMutations=snapshots
                mutationSyncFeedback=nil
            }
        } catch is CancellationError { }
        catch { mutationSyncFeedback="无法读取消息修改的确认状态。" }
    }
    func resumeMessageMutation(_ workID:UUID) async {
        guard resumingMutationID==nil,let snapshot=messageMutations.first(where:{$0.work.id==workID}),
            snapshot.work.scheduling == .needsAttention,
            let manager=messageEditor as? any V2MessageMutationManaging else { return }
        resumingMutationID=workID
        defer { resumingMutationID=nil }
        do { try await manager.resumeMutationConfirmation(workID:workID) }
        catch { mutationSyncFeedback="无法继续确认原消息操作，请稍后重试。" }
    }
    private(set) var forwardPlans:[V2ForwardPlanSnapshot] = []
    private(set) var forwardSyncFeedback:String?
    private(set) var changingForwardPlanID:UUID?
    func observeForwardPlans() async {
        guard let manager=messageForwarder as? any V2ForwardPlanManaging,let room=try? RoomID(roomID) else { return }
        do {
            for try await plans in await manager.updates(sourceRoomID:room) {
                try Task.checkCancellation();forwardPlans=plans;forwardSyncFeedback=nil
            }
        } catch is CancellationError { }
        catch { forwardSyncFeedback="无法读取已保存的转发进度。" }
    }
    func resumeForwardPlan(_ id:UUID) async {
        guard changingForwardPlanID==nil,forwardPlans.contains(where:{$0.work.id==id && $0.work.scheduling == .needsAttention}),
            let manager=messageForwarder as? any V2ForwardPlanManaging else { return }
        changingForwardPlanID=id;defer { changingForwardPlanID=nil }
        do { try await manager.resumeConfirmation(workID:id) }
        catch { forwardSyncFeedback="无法继续确认原转发计划。" }
    }
    func cancelRemainingForwardPlan(_ id:UUID) async {
        guard changingForwardPlanID==nil,forwardPlans.contains(where:{$0.work.id==id && !$0.work.execution.isTerminal}),
            let manager=messageForwarder as? any V2ForwardPlanManaging else { return }
        changingForwardPlanID=id;defer { changingForwardPlanID=nil }
        do { try await manager.cancelRemaining(workID:id) }
        catch { forwardSyncFeedback="无法保存停止剩余转发的请求。" }
    }
    private(set) var pendingReactions:[V2MessageReactionPending] = []
    private(set) var reactionSyncFeedback:String?
    func observeReactionIntents() async {
        guard let manager=messageReactionChanger as? any V2MessageReactionManaging else { return }
        do {
            for try await pending in try await manager.reactionUpdates(roomID:roomID) {
                try Task.checkCancellation();pendingReactions=pending;reactionSyncFeedback=nil
            }
        } catch is CancellationError { }
        catch { reactionSyncFeedback="无法读取已保存的反应目标。" }
    }
    func resumeReactionIntent(_ id:UUID) async {
        guard let pending=pendingReactions.first(where:{$0.intent.id==id}),!pending.expiredUnsubmitted,
            pending.preparationPaused || pending.work?.scheduling == .needsAttention,
            let manager=messageReactionChanger as? any V2MessageReactionManaging else { return }
        do { try await manager.resumeReactionConfirmation(intentID:id) }
        catch { reactionSyncFeedback="无法继续确认原反应，请稍后重试。" }
    }
    var canEditOwnGroupNickname: Bool { isGroupConversation && nameOperations != nil }
    func ownGroupNicknameEditor() -> V2NameEditorStore? {
        guard isGroupConversation, let nameOperations, let room = try? RoomID(roomID) else { return nil }
        return .init(target: .group(room), service: nameOperations)
    }

    func groupAvatarManagementStore() -> V2GroupAvatarManagementStore? {
        guard isGroupConversation, let groupAvatarManager, let attachmentStager, let room = try? RoomID(roomID) else { return nil }
        return .init(roomID: room, manager: groupAvatarManager, stager: attachmentStager, notifier: projectionChangeNotifier)
    }

    let reactionPresets = ["👍", "❤️", "😂", "🎉", "😢", "😡"]

    init(environment: V2ConversationFeatureEnvironment, context: V2ConversationDetailContext) {
        dataSource = environment.projections.dataSource
        sendingCapabilityReader = environment.projections.dataSource as? any V2ConversationSendingCapabilityReading
        messageSearcher = environment.projections.messageSearcher
        sender = environment.messages.sender
        messageWithdrawer = environment.messages.withdrawer
        messageReactionChanger = environment.messages.reactionChanger
        messageEditor = environment.messages.editor
        readReceiptReporter = environment.messages.readReceiptReporter
        messageFavoriter = environment.messages.favoriter
        messageModerator = environment.messages.moderator
        groupMessagePinner = environment.messages.groupPinner
        messageForwarder = environment.messages.forwarder
        forwardTargets = context.forwardTargets
        groupAnnouncementReader = environment.projections.groupAnnouncementReader
            ?? (environment.projections.dataSource as? any V2GroupAnnouncementReading)
        groupAnnouncementManager = environment.groups.announcementManager
        groupAvatarManager = environment.groups.avatarManager
        nameOperations = environment.groups.nameOperations
        groupMemberRoleChanger = environment.groups.memberRoleChanger
        groupRolePolicyReader = environment.projections.groupRolePolicyReader
            ?? (environment.projections.dataSource as? any V2GroupRolePolicyAccessing)
        groupRolePolicyChanger = environment.groups.rolePolicyChanger
        groupReadReceiptReader = environment.groups.readReceiptReader
        conversationLiveActivity = environment.runtime.liveActivity
        userID = environment.userID
        roomID = context.roomID
        title = context.title
        // A cached identity selects the lookup context; only the repository's
        // current lease permits display. Unknown rooms cannot infer a context.
        if case .direct = context.kind, let key = context.presentationKey, let actor = try? UserID(environment.userID),
           key.context == .directConversation, key.userID != actor {
            presentationKey = key
        } else {
            presentationKey = nil
        }
        kind = context.kind
        groupMemberDirectory = environment.groups.memberDirectory
        groupMembershipChanger = environment.groups.membershipChanger
        groupMemberMuter = environment.groups.memberMuter
        moderatedGroupMemberRemover = environment.groups.moderatedMemberRemover
        publicIdentityResolver = environment.discovery.publicIdentityResolver
        attachmentStager = environment.media.attachmentStager
        resourceSender = environment.media.resourceSender
        mediaDownloader = environment.media.downloader
        projectionChangeNotifier = environment.runtime.projectionChangeNotifier
        activeHybridGroupSynchronizer = environment.runtime.activeHybridGroupSynchronizer
        roomSubscriptions = environment.runtime.roomSubscriptions
        draft = context.initialDraft ?? ""
        mentionHandlesText = context.initialMentionHandles ?? ""
    }

    func messageSearchStore() -> V2ConversationSearchStore? {
        guard let messageSearcher, let roomID = try? RoomID(roomID) else { return nil }
        return .init(searcher: messageSearcher, scope: .room(roomID), actorUserID: try? .init(userID))
    }

    func refresh(scopes: V2ProjectionScopes = .all) async {
        if timelineLocationID != nil { refreshAfterTimelineLocation = true; return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let refreshTimeline = scopes.contains(.conversationDetails) || scopes.contains(.conversationTimeline)
        let refreshMetadata = scopes.contains(.conversationDetails) || scopes.contains(.conversationMetadata)
        if refreshTimeline, timeline.isEmpty { state = .loading }
        do {
            // Preserve only the window the user explicitly loaded. The normal
            // path remains a small page, while edits/withdrawals inside the
            // visible window are refreshed from one SQLite snapshot.
            let page: V2ConversationTimelinePage?
            if refreshTimeline {
                page = try await dataSource.timelinePage(
                    in: roomID,
                    for: userID,
                    before: newerTimelineBoundary,
                    limit: min(
                        Self.maximumRetainedTimelineItems,
                        max(Self.initialTimelinePageSize, timeline.count)
                    )
                )
            } else { page = nil }
            try Task.checkCancellation()
            guard generation == refreshGeneration else { return }
            let refreshedHistoryIncomplete = refreshTimeline ? ((try? await dataSource.roomLogHistoryIsIncomplete(roomID: roomID)) ?? isHistoryIncomplete) : isHistoryIncomplete
            try Task.checkCancellation()
            guard generation == refreshGeneration else { return }
            if refreshMetadata, let titles = dataSource as? any V2ConversationTitleReading,
               let updatedTitle = try await titles.currentTitle(in: RoomID(roomID)) {
                try Task.checkCancellation()
                guard generation == refreshGeneration else { return }
                title = updatedTitle
            }
            let refreshedTimeline = page?.items ?? timeline
            let refreshedMessages = refreshTimeline ? Self.messages(in: refreshedTimeline) : messages
            let refreshedCanSend: Bool? = if refreshMetadata, !isGroupConversation, let sendingCapabilityReader {
                try await sendingCapabilityReader.directSendingCapability(in: roomID)
            } else {
                canSendInDirectConversation
            }
            try Task.checkCancellation()
            guard generation == refreshGeneration else { return }
            let refreshedAnnouncement: V2ClientGroupAnnouncement? = if refreshMetadata, isGroupConversation, let groupAnnouncementReader {
                try await groupAnnouncementReader.groupAnnouncement(in: roomID)
            } else {
                groupAnnouncement
            }
            try Task.checkCancellation()
            guard generation == refreshGeneration else { return }
            if refreshMetadata { rolePolicyReadGeneration &+= 1 }
            let policyReadGeneration = rolePolicyReadGeneration
            let refreshedPolicies: V2ClientGroupRolePolicyState? = if refreshMetadata, isGroupConversation, let groupRolePolicyReader {
                try await groupRolePolicyReader.groupRolePolicyState(in: roomID)
            } else { nil }
            try Task.checkCancellation()
            guard generation == refreshGeneration else { return }
            if refreshTimeline { await discardMediaRevokedByRedaction(previous: messages, refreshed: refreshedMessages) }
            try Task.checkCancellation()
            guard generation == refreshGeneration else { return }
            let timelineChanged = refreshTimeline && refreshedTimeline != timeline
            if refreshTimeline {
                if timelineChanged {
                    messages = refreshedMessages
                    timeline = refreshedTimeline
                    timelineRevision &+= 1
                }
                canLoadOlderTimeline = page?.olderCursor != nil
            }
            // 标记只增不减：一旦确认缺过历史，就不因一次读失败或旧快照而"变完整"。
            isHistoryIncomplete = isHistoryIncomplete || refreshedHistoryIncomplete
            isBrowsingHistoricalTimeline = newerTimelineBoundary != nil
            if refreshMetadata {
                canSendInDirectConversation = refreshedCanSend
                groupAnnouncement = refreshedAnnouncement
                if policyReadGeneration == rolePolicyReadGeneration, let refreshedPolicies { updateGroupRolePolicyState(refreshedPolicies) }
            }
            if refreshTimeline {
                let visibleMediaIDs = Set(refreshedMessages.lazy
                    .filter { !$0.isWithdrawn }
                    .flatMap(\.media)
                    .map(\.mediaID))
                mediaDownloadStates = mediaDownloadStates.filter { visibleMediaIDs.contains($0.key) }
            }
            state = .loaded
            // The applied room cursor can advance for invisible or metadata-only
            // events even when the rendered timeline is unchanged.
            await advanceReadLineWhenAtLatestEnd()
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, generation == refreshGeneration else { return }
            if timeline.isEmpty {
                state = .failed
            } else {
                state = .loaded
                messageActionFeedback = "无法刷新当前会话。"
            }
        }
    }

    func loadOlderTimeline() async {
        guard timelineLocationID == nil, !isLoadingOlderTimeline, !isReturningToLatestTimeline,
              canLoadOlderTimeline,
              let first = timeline.first
        else { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        isLoadingOlderTimeline = true
        defer { isLoadingOlderTimeline = false }
        do {
            let page = try await dataSource.timelinePage(
                in: roomID,
                for: userID,
                before: first.cursor,
                limit: Self.timelinePageSize
            )
            try Task.checkCancellation()
            guard generation == refreshGeneration else { return }
            let existingIDs = Set(timeline.map(\.id))
            let older = page.items.filter { !existingIDs.contains($0.id) }
            let combined = older + timeline
            if combined.count > Self.maximumRetainedTimelineItems {
                let boundaryItem = combined[Self.maximumRetainedTimelineItems]
                newerTimelineBoundary = boundaryItem.cursor
                timeline = Array(combined.prefix(Self.maximumRetainedTimelineItems))
                isBrowsingHistoricalTimeline = true
            } else {
                timeline = combined
            }
            messages = Self.messages(in: timeline)
            timelineRevision &+= 1
            canLoadOlderTimeline = page.olderCursor != nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, generation == refreshGeneration else { return }
            messageActionFeedback = "无法加载更早的消息。"
        }
    }

    func returnToLatestTimeline() async {
        guard !isLoadingOlderTimeline, !isReturningToLatestTimeline,
              let previousBoundary = newerTimelineBoundary
        else { return }
        isReturningToLatestTimeline = true
        defer { isReturningToLatestTimeline = false }
        timelineLocationID = nil
        refreshAfterTimelineLocation = false
        newerTimelineBoundary = nil
        await refresh()
        if isBrowsingHistoricalTimeline {
            // A failed/cancelled latest-page read keeps the historical window
            // and its retry boundary coherent.
            newerTimelineBoundary = previousBoundary
        }
    }

    /// 读取包含目标消息的时间线。
    ///
    /// 搜索与收藏可以直接跳到目标附近的有界快照，
    /// 包括位于历史窗口之外的更新目标。
    ///
    /// - Parameter messageID: 目标消息标识。
    func loadTimeline(containing messageID: String) async {
        guard !Task.isCancelled else { return }
        let id = UUID()
        timelineLocationID = id
        refreshGeneration &+= 1
        let generation = refreshGeneration
        do {
            let location = try await dataSource.timelineWindow(in: roomID, for: userID, around: messageID, before: 40, after: 39)
            try Task.checkCancellation()
            guard timelineLocationID == id, generation == refreshGeneration else { return }
            switch location {
            case .unavailable:
                if timeline.isEmpty { state = .failed }
                messageActionFeedback = "这条消息已不可用。"
            case .withdrawn:
                if timeline.isEmpty { state = .failed }
                messageActionFeedback = "这条消息已撤回。"
            case .found(let page, let boundary):
                let refreshedMessages = Self.messages(in: page.items)
                await discardMediaRevokedByRedaction(previous: messages, refreshed: refreshedMessages)
                try Task.checkCancellation()
                guard timelineLocationID == id, generation == refreshGeneration else { return }
                timeline = page.items
                messages = refreshedMessages
                newerTimelineBoundary = boundary
                isBrowsingHistoricalTimeline = boundary != nil
                canLoadOlderTimeline = page.olderCursor != nil
                timelineRevision &+= 1
                state = .loaded
                messageActionFeedback = nil
            }
        } catch is CancellationError { }
        catch {
            if timelineLocationID == id, !Task.isCancelled {
                if timeline.isEmpty { state = .failed }
                messageActionFeedback = "暂时无法定位这条消息，请重试。"
            }
        }
        guard timelineLocationID == id else { return }
        timelineLocationID = nil
        if refreshAfterTimelineLocation {
            refreshAfterTimelineLocation = false
            await refresh()
        }
    }

    private static func messages(
        in timeline: [V2ConversationTimelineItem]
    ) -> [V2ConversationMessageItem] {
        timeline.compactMap { item in
            guard case .message(let message, _) = item else { return nil }
            return message
        }
    }

    private func discardMediaRevokedByRedaction(
        previous: [V2ConversationMessageItem],
        refreshed: [V2ConversationMessageItem]
    ) async {
        guard let cache = mediaDownloader as? any V2ConversationMediaCacheDiscarding else { return }
        let withdrawnIDs = Set(refreshed.lazy.filter(\.isWithdrawn).map(\.id))
        for message in previous where !message.isWithdrawn && withdrawnIDs.contains(message.id) {
            for media in message.media {
                guard !Task.isCancelled else { return }
                await cache.discard(media)
            }
        }
    }

    func observeProjectionChanges() async {
        guard let projectionChangeNotifier else {
            await refresh()
            return
        }
        await V2ProjectionRefreshObserver.run(await projectionChangeNotifier.updates(
            scopes: [.conversationDetails, .conversationTimeline, .conversationMetadata], roomID: roomID
        )) { [self] request in
            await refresh(scopes: request.scopes)
        }
    }

    /// 轮询当前可见房间的持久化事件（合同 §3：按房间游标恢复）。
    ///
    /// 该任务由详情视图的 `.task` 修饰符持有，因此用户离开会话或场景销毁时会自动停止。
    /// 生产房间在既有 TLS 连接上等待服务端唤醒；30 秒一次的游标拉取仅作为丢消息后的恢复手段。
    ///
    /// 私聊与群聊均按房间游标补齐未读尾部。同步实现根据成员权限决定能否补拉，
    /// 房间容量等级不改变公共内容的恢复来源。
    func pollVisibleHybridGroupEvents() async {
        guard let activeHybridGroupSynchronizer
        else { return }
        if let roomSubscriptions, let parsedRoom = try? RoomID(roomID) {
            let scoped = V2ScopedActiveRoomSynchronizer(roomID: parsedRoom, owner: roomSubscriptions, base: activeHybridGroupSynchronizer)
            await observeActiveRoom(scoped)
            await scoped.close()
            return
        }
        await observeActiveRoom(activeHybridGroupSynchronizer)
    }

    private func observeActiveRoom(_ activeHybridGroupSynchronizer: any V2ActiveHybridGroupSynchronizing) async {
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
        var requiresDurablePull = true
        while !Task.isCancelled {
            do {
                if requiresDurablePull {
                    let shouldContinue = try await synchronizeHybridGroupUntilIdle(synchronizer)
                    guard shouldContinue else { return }
                }
                let wake = try await nextHybridWakeOrFallback(synchronizer)
                if let wake, wake.roomID != roomID {
                    continue
                }
                if let wake {
                    if try await synchronizer.applyLiveEvent(wake) {
                        requiresDurablePull = false
                    } else {
                        requiresDurablePull = try await shouldPullAfterHybridGroupRecoveryGrace(
                            initialWake: wake,
                            synchronizer: synchronizer
                        )
                    }
                } else {
                    // The low-frequency fallback is deliberately a durable
                    // pull, because it has no event payload to apply.
                    requiresDurablePull = true
                }
            } catch is CancellationError {
                return
            } catch {
                // A broken connection may fail immediately. Slow only this
                // failure path so it cannot become a hot sync loop; normal
                // foreground delivery still waits for a TLS wake.
                requiresDurablePull = true
                await waitAfterRealtimeWakeFailure(error)
            }
        }
    }

    /// 在混合大群恢复宽限期内等待，并判断是否应当改为拉取。
    ///
    /// 正文可能只覆盖已知水位的一部分，短暂缺口与元数据提示共享同一个有界等待。
    /// 只有经过验证的连续正文可以推进游标；新提示不会延长截止时间。
    ///
    /// - Parameters:
    ///   - initialWake: 首次收到的唤醒信息。
    ///   - synchronizer: 当前混合大群同步实现。
    /// - Returns: 宽限期结束后需要按游标拉取时为 `true`。
    /// - Throws: 任务取消或同步实现失败时抛出。
    private func shouldPullAfterHybridGroupRecoveryGrace(
        initialWake: V2ActiveHybridGroupWake,
        synchronizer: any V2ActiveHybridGroupSynchronizing
    ) async throws -> Bool {
        var requiredHighWatermark = initialWake.highWatermark
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.hybridGroupRecoveryGrace)

        while !Task.isCancelled, clock.now < deadline {
            let remaining = clock.now.duration(to: deadline)
            guard let wake = try await nextHybridWake(
                synchronizer,
                timeout: remaining
            ) else { return true }
            guard wake.roomID == roomID else { continue }
            requiredHighWatermark = max(
                requiredHighWatermark,
                wake.highWatermark
            )
            if try await synchronizer.applyLiveEvent(wake),
               wake.highWatermark >= requiredHighWatermark {
                return false
            }
        }
        try Task.checkCancellation()
        return true
    }

    /// 混合大群的低频兜底轮询。
    ///
    /// 已注入的测试替身与刻意不可用的实时路径都会以远低的频率使用同一套持久化同步引擎；
    /// 它绝不是常规在线混合大群的投递路径。
    ///
    /// - Parameter synchronizer: 当前混合大群同步实现。
    private func pollHybridGroupFallback(_ synchronizer: any V2ActiveHybridGroupSynchronizing) async {
        while !Task.isCancelled {
            do {
                let shouldContinue = try await synchronizeHybridGroupUntilIdle(synchronizer)
                guard shouldContinue else { return }
                try await Task.sleep(for: .seconds(30))
            } catch is CancellationError {
                return
            } catch {
                await waitAfterRealtimeWakeFailure(error)
            }
        }
    }

    private func synchronizeHybridGroupUntilIdle(_ synchronizer: any V2ActiveHybridGroupSynchronizing) async throws -> Bool {
        while !Task.isCancelled {
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
        }
        return false
    }

    /// 等待下一次混合大群唤醒或兜底超时。
    ///
    /// 代理唤醒提供常规的前台延迟；计时器只用于恢复丢失的尽力而为唤醒，
    /// 刻意不做成一秒一次的轮询。
    ///
    /// - Parameter synchronizer: 当前混合大群同步实现。
    /// - Returns: 本次唤醒信息；无唤醒时返回 `nil`。
    /// - Throws: 任务取消或同步实现失败时抛出。
    private func nextHybridWakeOrFallback(_ synchronizer: any V2ActiveHybridGroupSynchronizing) async throws -> V2ActiveHybridGroupWake? {
        if synchronizer.usesRuntimeRecoveryClock { return try await synchronizer.nextWake() }
        return try await withThrowingTaskGroup(of: V2ActiveHybridGroupWake?.self) { group in
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

    private func nextHybridWake(
        _ synchronizer: any V2ActiveHybridGroupSynchronizing,
        timeout: Duration
    ) async throws -> V2ActiveHybridGroupWake? {
        guard timeout > .zero else { return nil }
        return try await withThrowingTaskGroup(
            of: V2ActiveHybridGroupWake?.self
        ) { group in
            group.addTask { try await synchronizer.nextWake() }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return result
        }
    }

    private func waitAfterRealtimeWakeFailure(_ error: any Error) async {
        var seconds = 1
        if case .server(_, true, let retryAfter, _) = error as? V2RealtimeTransportError {
            seconds = max(seconds, Int(retryAfter))
        }
        do {
            try await Task.sleep(for: .seconds(seconds))
        } catch {
            // The owning detail-view task will exit on cancellation.
        }
    }

    /// 上报一条可见消息。
    ///
    /// 仅由惰性渲染的行在进入可见滚动区域之后调用；持久化发件箱会合并重复出现。
    ///
    /// - Parameter message: 已进入可见区域的消息。
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

    /// 处于最新端时按合同 §5.4 推进已读线。
    ///
    /// 只上报最后一条**可见消息**的序号是不够的：服务端未读是
    /// `head − max(已读线, 自己最新消息序号)`，而房间头还包含编辑、撤回、reaction、
    /// 置顶、公告、角色变更这些非消息事件。房间尾部一旦是非消息事件，未读就会永久停在
    /// 1 —— 用户打开房间、看完全部内容也无法清零。
    ///
    /// 因此这里推进到**本设备已应用到的房间序号**（它包含非消息事件），并只在确认已经
    /// 追平服务端房间头时直接推进到 head。本地落后于 head（还有未收到的事件）时只上报
    /// 真实已应用位置，既不虚报未读，也不假装已经读完没看到的内容。
    ///
    /// - Note: 可靠房间日志（私聊与混合大群）由本地游标精确回答；标准扇出群没有持久化
    ///   游标，只按投影自带的来源序号尽力逼近，尾部非消息事件仍需按 §9 第 3 步切到
    ///   读模型后才会完全消失。
    private func advanceReadLineWhenAtLatestEnd() async {
        guard newerTimelineBoundary == nil, let readReceiptReporter else { return }
        guard let checkpoint = try? await dataSource.roomReadCheckpoint(roomID: roomID) else { return }
        let applied = checkpoint.appliedRoomSequence
        let target: UInt64?
        switch (checkpoint.knownHead, applied) {
        case let (head?, applied?):
            // 已应用序号 ≥ 房间头：进入即推进到 head，无需任何往返；本地落后：只上报
            // 真实已应用位置。
            target = applied >= head ? head : applied
        case (_, let applied?):
            // 房间头未知（目录还没轮转到该房间）：只推进到本设备真实应用到的位置。
            target = applied
        case (_?, nil), (nil, nil):
            // 不知道本地应用到哪：保持现状，宁可不推进也不虚报。
            target = nil
        }
        // 零不是合法的已读线：没有任何本地证据时保持现状，服务端也会拒绝。
        guard let target, target > 0 else { return }
        do {
            _ = try await readReceiptReporter.recordReadThrough(roomID: roomID, roomSequence: target)
        } catch is CancellationError {
            return
        } catch {
            // 进入房间的本地效果必须保留：已读回执队列接不下时，下一次刷新会再试。
        }
    }

    /// 观察实时活动状态。
    ///
    /// 该任务由详情视图持有。实时活动是瞬时状态，视图消失时必须停止；
    /// 消息刷新是另一条独立路径。
    func observeLiveActivity() async {
        if let roomSubscriptions {
            await observeSharedLiveActivity(roomSubscriptions)
            return
        }
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

    private func observeSharedLiveActivity(_ owner: V2RoomSubscriptionCoordinator) async {
        guard let room = try? RoomID(roomID) else { return }
        var channels: Set<V2RoomSubscriptionChannel> = [.typing]
        if !isGroupConversation { channels.insert(.presence) }
        do {
            let lease = try await owner.acquire(roomID: room, channels: channels)
            activityConsumerID = lease.id
            var observedConnectionID: UUID?
            for await snapshot in lease.updates {
                guard !Task.isCancelled else { break }
                if observedConnectionID != snapshot.connectionID || snapshot.state == .offline || snapshot.state == .revoked {
                    observedConnectionID = snapshot.connectionID
                    typingLeaseTask?.cancel()
                    typingLeaseTask = nil
                    typingLeaseID = nil
                }
                activityConnectionID = snapshot.state == .subscribed ? snapshot.connectionID : nil
                // Each snapshot replaces all transient facts, including when
                // an intermediate offline value was coalesced away.
                clearTypingStates()
                setPeerPresence(snapshot.presence)
                for typing in snapshot.typing { applyTypingState(typing) }
            }
            await owner.release(roomID: room, consumerID: lease.id)
        } catch {
            // Registration is bounded; local history remains available.
        }
        activityConsumerID = nil
        activityConnectionID = nil
        setPeerPresence(nil)
        clearTypingStates()
        typingLeaseTask?.cancel()
        typingLeaseTask = nil
    }

    private var presenceExpiryTask: Task<Void, Never>?
    private func setPeerPresence(_ presence: V2PresenceState?) {
        presenceExpiryTask?.cancel()
        presenceExpiryTask = nil
        guard let presence, presence.expiresAt > Date() else { peerPresence = nil; return }
        peerPresence = presence
        presenceExpiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, presence.expiresAt.timeIntervalSinceNow))) }
            catch { return }
            guard let self, self.peerPresence == presence else { return }
            self.peerPresence = nil
            self.presenceExpiryTask = nil
        }
    }

    /// 应用一次线路事件并负责接收端的到期处理。
    ///
    /// 它与流循环分离，使测试无需真实套接字即可覆盖租约边界。
    ///
    /// - Parameters:
    ///   - typing: 正在输入状态。
    ///   - now: 本次判定时刻。
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
        let sendTyping: @Sendable (Bool) async throws -> Void
        if let roomSubscriptions {
            guard let consumerID = activityConsumerID, let connectionID = activityConnectionID,
                  let room = try? RoomID(roomID) else { return }
            sendTyping = { value in
                try await roomSubscriptions.setTyping(roomID: room, consumerID: consumerID, connectionID: connectionID, isTyping: value)
            }
        } else if let activity = conversationLiveActivity {
            let room = roomID
            sendTyping = { value in try await activity.setTyping(roomID: room, isTyping: value) }
        } else { return }
        let shouldType = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if shouldType, typingLeaseTask == nil {
            let leaseID = UUID()
            typingLeaseID = leaseID
            typingLeaseTask = Task { [weak self] in
                defer {
                    if self?.typingLeaseID == leaseID {
                        self?.typingLeaseTask = nil
                        self?.typingLeaseID = nil
                    }
                }
                while !Task.isCancelled {
                    do {
                        try await sendTyping(true)
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
            typingLeaseID = nil
            Task { try? await sendTyping(false) }
        }
    }

    func loadGroupReadReceipts(for message: V2ConversationMessageItem, reset: Bool = false) async {
        guard isGroupConversation, message.isOutgoing, !message.isWithdrawn,
              let groupReadReceiptReader, !Task.isCancelled
        else { return }
        let isNewMessage = groupReadReceiptMessageID != message.id
        if !reset, !isNewMessage, groupReadReceiptPage?.nextCursor == nil { return }
        if !reset, !isNewMessage, isLoadingGroupReadReceipts { return }
        let demand = UUID()
        groupReadReceiptDemand = demand
        if reset || isNewMessage {
            groupReadReceiptMessageID = message.id
            groupReadReceiptPage = nil
            groupReadReceiptFeedback = nil
            hasEarlierGroupReadReceipts = false
        }
        // A superseding message/reset owns the next read only after the old
        // transport actually returns. Multiple resets retain only the latest.
        if let previous = groupReadReceiptFlight {
            previous.task.cancel()
            _ = await previous.task.result
            guard !Task.isCancelled, demand == groupReadReceiptDemand else { return }
        }
        let cursor = reset || isNewMessage ? nil : groupReadReceiptPage?.nextCursor
        let roomID = self.roomID
        let task = Task {
            try Task.checkCancellation()
            return try await groupReadReceiptReader.readers(roomID: roomID, messageID: message.id, cursor: cursor)
        }
        groupReadReceiptFlight = (demand, task)
        isLoadingGroupReadReceipts = true
        defer {
            if groupReadReceiptFlight?.id == demand {
                groupReadReceiptFlight = nil
                isLoadingGroupReadReceipts = false
            }
        }
        do {
            let page = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard demand == groupReadReceiptDemand else { return }
            guard page.roomID.rawValue == roomID, page.messageID.rawValue == message.id,
                  page.readers.count <= 100, page.nextCursor == nil || page.nextCursor != cursor else {
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
                let readers = existing.readers + page.readers
                if readers.count > 1_000 { hasEarlierGroupReadReceipts = true }
                groupReadReceiptPage = try .init(
                    roomID: page.roomID,
                    messageID: page.messageID,
                    readers: Array(readers.suffix(1_000)),
                    nextCursor: page.nextCursor
                )
            }
            groupReadReceiptFeedback = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, demand == groupReadReceiptDemand else { return }
            groupReadReceiptFeedback = "无法读取已读详情，请检查网络后重试。"
        }
    }

    func groupPresentationKey(for target: UserID) -> V2ProfileViewLookupKey? {
        guard isGroupConversation, let room = try? RoomID(roomID) else { return nil }
        return .init(userID: target, context: .room(room))
    }

    private(set) var pendingResourceSends: [V2DurableConversationSendService.Pending] = []
    private(set) var pendingResourceSendPage=0
    private(set) var hasNextPendingResourceSendPage=false
    func nextPendingResourceSendPage() { guard hasNextPendingResourceSendPage else { return }; pendingResourceSends=[]; hasNextPendingResourceSendPage=false; pendingResourceSendPage += 1 }
    func previousPendingResourceSendPage() { guard pendingResourceSendPage > 0 else { return }; pendingResourceSends=[]; hasNextPendingResourceSendPage=false; pendingResourceSendPage -= 1 }

    func observeResourceSends() async {
        guard let durable = resourceSender, let room = try? RoomID(roomID) else { return }
        do {
            let page=pendingResourceSendPage
            for try await result in durable.pendingPageUpdates(in:room,page:page) {
                try Task.checkCancellation()
                guard page == pendingResourceSendPage else { return }
                pendingResourceSends = result.items
                hasNextPendingResourceSendPage = result.hasNext
            }
        } catch is CancellationError { return }
        catch {
            guard !Task.isCancelled else { return }
            sendFeedback = "附件进度观察已暂停，重新进入会话后可继续查看。"
        }
    }
    func copyAttachments(_ message: V2ConversationMessageItem, to targetRoomID: String) async -> Bool {
        guard !message.isWithdrawn, !message.media.isEmpty,
              let durable = resourceSender else {
            messageActionFeedback = "暂时无法复制附件。"
            return false
        }
        do {
            let source = try V2MediaMessageLocation(roomID: .init(roomID), messageID: .init(message.id))
            let sources = message.media.map { V2ResourceImportSource.message(location: source, mediaID: $0.mediaID, variantID: nil) }
            try await durable.copyAttachments(sources: sources, to: .init(targetRoomID))
            messageActionFeedback = "已保存附件复制意图，准备完成后发送到目标会话。"
            return true
        } catch is CancellationError { return false }
        catch { messageActionFeedback = "暂时无法复制附件。"; return false }
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

    func sendDraft() async {
        guard !isSending else { return }
        guard isGroupConversation || canSendInDirectConversation != false else {
            sendFeedback = "当前无法向此会话发送消息。"
            return
        }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        guard let sender else {
            sendFeedback = "实时网关尚未可用，无法发送。"
            return
        }
        let frozenAttachments = attachments.map(\.attachment)
        let frozenReplyTarget = replyTarget
        isSending = true
        defer { isSending = false }
        do {
            // Resolve all user-entered intent before any attachment transfer.
            // An invalid mention must not spend upload/scan work or alter the
            // staged attachment state.
            let mentions = try await resolvedMentions()
            try Task.checkCancellation()
            if !attachments.isEmpty {
                guard let durable = resourceSender else {
                    sendFeedback = "附件发送暂不可用。"
                    return
                }
                let frozenReply = try frozenReplyTarget.map { try V2MessageReplyReference(messageID: .init($0.id)) }
                try await durable.freezeSend(text: text, mentions: mentions, replyTo: frozenReply, roomID: .init(roomID), attachments: frozenAttachments)
                // The journal now owns these files, including across process death.
                attachments = []
                draft = ""
                mentionHandlesText = ""
                replyTarget = nil
                sendFeedback = "已保存发送意图，附件准备完成后自动发送。"
                return
            }
            let replyTo = replyTarget.flatMap { try? V2MessageReplyReference(messageID: .init($0.id)) }
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
                draft = ""
                mentionHandlesText = ""
                replyTarget = nil
            case .queuedForRetry:
                // Tracked sends display their progress on the pending message row.
                sendFeedback = sender is any V2ConversationSendTracking ? nil : "已安全保存，连接恢复后会重试。"
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
            && (isGroupConversation || canSendInDirectConversation != false)
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
        } catch V2ConversationAttachmentStagingError.fileTooLarge {
            sendFeedback = "附件不能超过 50 MB。"
        } catch V2ConversationAttachmentStagingError.stagingQuotaExceeded {
            sendFeedback = "设备上的待上传附件过多，请移除部分附件后重试。"
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

    func mediaFileUnavailable(_ downloaded: V2DownloadedConversationMedia) {
        guard mediaDownloadStates[downloaded.mediaID] == .downloaded(downloaded) else { return }
        mediaDownloadStates[downloaded.mediaID] = .notDownloaded
        messageActionFeedback = "本地附件已不可用，请重新下载。"
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
            let location = try V2MediaMessageLocation(roomID: RoomID(roomID), messageID: MessageID(message.id))
            let downloaded = try await mediaDownloader.download(media, message: location)
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

    /// 编辑一条消息，并返回编辑器是否可以安全关闭。
    ///
    /// 被拒绝的命令会保留输入文本，便于用户修改或重试。
    ///
    /// - Parameters:
    ///   - message: 目标消息。
    ///   - text: 编辑后的正文。
    /// - Returns: 编辑器可以关闭时为 `true`。
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
        } catch V2MessageMutationAdmissionError.confirmationRequired {
            messageActionFeedback = "上一份编辑结果尚未确认。请先继续确认原编辑，草稿仍可保留。"
            return false
        } catch {
            messageActionFeedback = "无法保存编辑。"
            return false
        }
    }

    func changeReaction(_ reaction: String, on message: V2ConversationMessageItem, action:V2MessageReactionAction = .add) async {
        guard canReactToMessage(message) else { return }
        guard beginMessageAction(for: message) else { return }
        defer { finishMessageAction(for: message) }
        guard let messageReactionChanger else {
            messageActionFeedback = "反应暂不可用。"
            return
        }
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

    func setFavorite(_ message: V2ConversationMessageItem, desired: Bool? = nil) async {
        guard !message.isWithdrawn, beginMessageAction(for: message) else { return }
        defer { finishMessageAction(for: message) }
        guard let messageFavoriter else { messageActionFeedback = "收藏暂不可用。"; return }
        do {
            var current = message.isFavorited
            if desired == nil, let manager = messageFavoriter as? any V2PersonalPreferenceManaging,
               case .favorite(_, _, let saved) = try await manager.desiredPreferenceTarget(.favorite(roomID: .init(roomID), messageID: .init(message.id), isFavorited: current)) { current = saved }
            let target = desired ?? !current
            let outcome = try await messageFavoriter.setFavorite(roomID: roomID, messageID: message.id, isFavorited: target)
            try Task.checkCancellation()
            switch outcome {
            case .accepted: messageActionFeedback = target ? "已收藏，正在同步。" : "已取消收藏，正在同步。"; await refresh()
            case .queuedForRetry: messageActionFeedback = "收藏操作已安全保存，连接恢复后会重试。"
            case .rejected(let code): messageActionFeedback = "收藏被拒绝（\(code)）。"
            }
        } catch is CancellationError { return }
        catch { messageActionFeedback = "无法保存收藏操作。" }
    }

    private(set) var groupCapabilityPending:[V2GroupCapabilityPending]=[]
    func observeGroupCapabilities() async {
        guard let manager=groupMessagePinner as? any V2GroupCapabilityManaging,let room=try? RoomID(roomID) else { return }
        do {
            for try await pending in await manager.service.updates(roomID:room) {
                try Task.checkCancellation()
                let completedIDs = Set(groupCapabilityPending.compactMap { $0.work?.scheduling == .finished ? $0.work?.id : nil })
                if pending.contains(where: { value in
                    guard let work = value.work, work.scheduling == .finished,
                          !completedIDs.contains(work.id) else { return false }
                    return work.execution == .rejected || work.execution == .conflicted
                }) {
                    // A rejected authority/CAS attempt cannot keep an earlier
                    // member editing baseline valid for the next user proposal.
                    groupMemberDirectoryIsStale = true
                    groupCapabilityReconfirmation = nil
                }
                groupCapabilityPending=pending
            }
        } catch is CancellationError {} catch { messageActionFeedback="群操作状态暂不可读，已保存的请求不会撤销。" }
    }
    func continueGroupCapability(_ pending:V2GroupCapabilityPending) async {
        guard pending.work != nil,let manager=groupMessagePinner as? any V2GroupCapabilityManaging else { return }
        do { try await manager.service.resumeConfirmation(id:pending.id) }
        catch { messageActionFeedback="暂时无法核对原操作，请稍后继续。" }
    }
    struct GroupCapabilityReconfirmation:Identifiable {
        let id:UUID
        let action:V2GroupCapabilityAction
    }
    var groupCapabilityReconfirmation:GroupCapabilityReconfirmation?
    func prepareGroupCapabilityReconfirmation(_ pending:V2GroupCapabilityPending) async {
        guard pending.work==nil,pending.confirmationRequired,
            let manager=groupMessagePinner as? any V2GroupCapabilityManaging else { return }
        do {
            let action:V2GroupCapabilityAction
            switch pending.intent.action {
            case .pin(let messageID,let desired,_):
                let baseline=try await manager.service.pinBaseline(roomID:.init(roomID),messageID:messageID)
                action = .pin(messageID:messageID,isPinned:desired,expectedRoomSequence:baseline.roomSequence)
            case .announcement(let body,_):
                await refresh()
                action = .announcement(body:body,expectedRevision:groupAnnouncement?.revision ?? 0)
            case .rolePermissions(let role,let permissions,_):
                await loadGroupRolePolicies()
                guard let policy=groupRolePolicies.first(where:{$0.role==role}) else { throw V2GroupCapabilityAdmissionError.confirmationRequired }
                action = .rolePermissions(role:role,permissions:permissions,expectedRevision:policy.revision)
            case .memberRole(let target,let role,_):
                await loadGroupMembers(reset:true,reason:.authorizationChanged)
                guard let revision=groupMemberRevision,let member=groupMembers.first(where:{$0.id==target.rawValue}),canChangeGroupMemberRole(member) else { throw V2GroupCapabilityAdmissionError.confirmationRequired }
                action = .memberRole(targetUserID:target,role:role,expectedMembershipRevision:revision)
            }
            try Task.checkCancellation()
            groupCapabilityReconfirmation = .init(id:pending.id,action:action)
        } catch is CancellationError {} catch { messageActionFeedback="无法读取确认所需的群状态，请稍后重试。" }
    }
    func confirmGroupCapability(_ proposal:GroupCapabilityReconfirmation) async {
        guard let manager=groupMessagePinner as? any V2GroupCapabilityManaging else { return }
        groupCapabilityReconfirmation=nil
        do {
            let confirmation=try manager.service.confirmationWindow(roomID:.init(roomID),action:proposal.action)
            _ = try await manager.service.reconfirmDraft(id:proposal.id,confirmation:confirmation)
            messageActionFeedback="新的确认已保存，服务器仍会校验当前权限与版本。"
        } catch is CancellationError {} catch { messageActionFeedback="原操作状态已变化，无法重新确认，请查看最新状态。" }
    }
    func discardGroupCapability(_ pending:V2GroupCapabilityPending) async {
        guard pending.work==nil,let manager=groupMessagePinner as? any V2GroupCapabilityManaging else { return }
        do { try await manager.service.discardDraft(id:pending.id) }
        catch { messageActionFeedback="无法取消未提交的群操作。" }
    }
    struct MessageRemovalProposal {
        let id: UUID
        let baseline: V2MessageModerationBaseline
        let generation: UUID
        let expires: ContinuousClock.Instant
        let confirmedUntil: Date
        let policies: [V2ClientGroupRolePolicy]
        let membershipRevision: UInt64?
    }
    var messageRemovalProposal: MessageRemovalProposal?
    private(set) var messageRemovalPending: [V2MessageModerationPending] = []
    private var removalPolicyIsCurrent = false
    private var removalPageActive = false
    private var removalGeneration = UUID()
    private var removalIsPreparing = false
    private var removalIsSaving = false
    private var consumedRemovalProposalID: UUID?
    var canManageMessages: Bool {
        guard isGroupConversation, messageModerator != nil, !groupMemberDirectoryIsStale,
              !isLoadingGroupMembers, removalPolicyIsCurrent, groupRolePolicyState.recovery == .ready, let roleName = groupActorRole else { return false }
        let role: V2RoomMembershipRole = roleName == "群主" ? .owner : roleName == "管理员" ? .admin : .member
        return V2GroupPermissionDefaults.allows(role: role, permission: .moderateMessages,
            configured: groupRolePolicies.first(where: { $0.role == role })?.permissions)
    }
    func endMessageRemovalPage() {
        removalPageActive = false; removalGeneration = UUID(); messageRemovalProposal = nil
    }
    func messageRemovalStatus(_ pending: V2MessageModerationPending) -> String {
        if let receipt = pending.receipt {
            switch receipt.outcome {
            case .redacted, .alreadySatisfied: return "消息已被管理移除"
            case .rejected: return "原移除操作被拒绝，请重新读取状态后确认"
            case .closed: return "原移除操作已确认未执行"
            }
        }
        if pending.work.execution == .expiredUnsubmitted { return "尚未提交的移除确认已过期" }
        return pending.work.scheduling == .needsAttention ? "移除结果未知，已暂停核对" : "正在核对原消息移除操作"
    }
    func observeMessageRemoval() async {
        guard let messageModerator, isGroupConversation else { return }
        removalPageActive = true
        removalGeneration = UUID()
        let generation = removalGeneration
        defer {
            if removalGeneration == generation { removalPageActive = false; messageRemovalProposal = nil }
        }
        do {
            for try await values in await messageModerator.updates() {
                try Task.checkCancellation()
                guard removalPageActive, removalGeneration == generation else { return }
                messageRemovalPending = values.filter { $0.intent.roomID.rawValue == roomID }
            }
        } catch is CancellationError {} catch {
            if removalPageActive, removalGeneration == generation { messageActionFeedback = "移除状态暂不可读，原操作仍保留。" }
        }
    }
    func prepareMessageRemoval(_ message: V2ConversationMessageItem) async {
        guard removalPageActive, !removalIsPreparing, !removalIsSaving, canManageMessages, !message.isWithdrawn, let messageModerator,
              let room = try? RoomID(roomID), let id = try? MessageID(message.id) else { return }
        removalIsPreparing = true
        defer { removalIsPreparing = false }
        messageRemovalProposal = nil
        let generation = removalGeneration
        let expires = ContinuousClock.now.advanced(by: .seconds(120))
        let end = Date().addingTimeInterval(120)
        do {
            let baseline = try await messageModerator.baseline(roomID: room, messageID: id)
            try Task.checkCancellation()
            guard removalPageActive, removalGeneration == generation, canManageMessages, expires > .now else { return }
            messageRemovalProposal = .init(id: UUID(), baseline: baseline, generation: generation, expires: expires, confirmedUntil: end,
                policies: groupRolePolicies, membershipRevision: groupMemberRevision)
        } catch is CancellationError {} catch {
            if removalPageActive, removalGeneration == generation { messageActionFeedback = "无法读取当前消息管理基线。" }
        }
    }
    func confirmMessageRemoval(_ proposal: MessageRemovalProposal) async {
        guard let messageModerator, !removalIsSaving, consumedRemovalProposalID != proposal.id else { return }
        guard removalPageActive, removalGeneration == proposal.generation, canManageMessages, proposal.expires > .now,
              proposal.policies == groupRolePolicies, proposal.membershipRevision == groupMemberRevision else {
            if removalPageActive { messageActionFeedback = "确认已过期或权限变化，请重新读取消息状态。" }; return
        }
        consumedRemovalProposalID = proposal.id
        removalIsSaving = true
        messageRemovalProposal = nil
        defer { removalIsSaving = false }
        let generation = removalGeneration
        do {
            _ = try await messageModerator.enqueue(baseline: proposal.baseline,
                reason: .init("moderation_removal"), confirmedUntil: proposal.confirmedUntil)
            guard !Task.isCancelled, removalPageActive, removalGeneration == generation else { return }
            messageActionFeedback = "管理移除已保存，正在核对原操作。"
        } catch is CancellationError {} catch {
            if removalPageActive, removalGeneration == generation { messageActionFeedback = "无法保存管理移除确认。" }
        }
    }
    func resumeMessageRemoval(_ id: UUID) async {
        guard let messageModerator, messageRemovalPending.contains(where: { $0.work.id == id && $0.work.scheduling == .needsAttention }) else { return }
        let generation = removalGeneration
        do { try await messageModerator.resume(id: id) }
        catch is CancellationError {} catch {
            if removalPageActive, removalGeneration == generation { messageActionFeedback = "暂时无法继续核对原移除操作。" }
        }
    }

    var pendingPinBaseline:V2PinnedMessageBaseline?
    func pinInGroup(_ message: V2ConversationMessageItem) async {
        guard isGroupConversation,!message.isWithdrawn,beginMessageAction(for:message) else { return }
        defer { finishMessageAction(for:message) }
        guard let groupMessagePinner else { messageActionFeedback="置顶消息暂不可用。";return }
        do {
            let baseline=try await groupMessagePinner.pinBaseline(roomID:roomID,messageID:message.id)
            try Task.checkCancellation()
            pendingPinBaseline=baseline
        } catch is CancellationError {} catch { messageActionFeedback="无法读取最新置顶状态，请稍后重试。" }
    }
    func confirmPinInGroup(_ baseline:V2PinnedMessageBaseline) async {
        guard let groupMessagePinner else { return }
        pendingPinBaseline=nil
        do {
            _ = try await groupMessagePinner.setPinned(roomID:roomID,messageID:baseline.messageID.rawValue,isPinned:!baseline.isPinned,expectedRoomSequence:baseline.roomSequence)
            messageActionFeedback="置顶确认已保存；两分钟内核对，状态变化或超时需重新确认。"
        } catch is CancellationError {} catch { messageActionFeedback="无法保存置顶确认。" }
    }

    func beginForwardSelection(with message: V2ConversationMessageItem? = nil) {
        isSelectingMessagesForForward = true
        if let message { toggleForwardSelection(for: message) }
    }

    func endForwardSelection() {
        isSelectingMessagesForForward = false
        selectedForwardSources.removeAll()
    }

    func toggleForwardSelection(for message: V2ConversationMessageItem) {
        guard !message.isWithdrawn else { return }
        if selectedForwardMessageIDs.contains(message.id) {
            selectedForwardSources.removeValue(forKey: message.id)
        } else if selectedForwardMessageIDs.count < V2ForwardMessagesCommand.maximumSourceMessages {
            do {
                let reference = V2ForwardMessageReference(roomID: try .init(roomID), messageID: try .init(message.id), revision: try .init(message.revision))
                selectedForwardSources[message.id] = .init(reference: reference, roomSequence: message.roomSequence)
            } catch {
                messageActionFeedback = "此消息暂不能转发，请刷新后重新选择。"
            }
        } else {
            messageActionFeedback = "一次最多转发 \(V2ForwardMessagesCommand.maximumSourceMessages) 条消息。"
        }
    }

    func selectedForForward(_ message: V2ConversationMessageItem) -> Bool {
        selectedForwardMessageIDs.contains(message.id)
    }

    /// 转发选中的消息，并返回目标选择页是否可以安全关闭。
    ///
    /// 已排队的命令是持久化的，因此此时离开页面同样是安全的。
    ///
    /// - Parameter targetRoomIDs: 目标房间标识列表。
    /// - Returns: 可以关闭目标选择页时为 `true`。
    func forwardSelectedMessages(to targetRoomIDs: [String]) async -> Bool {
        guard !isForwardingMessages else { return false }
        let sources = selectedForwardSources.values.sorted {
            if $0.roomSequence != $1.roomSequence { return $0.roomSequence < $1.roomSequence }
            return $0.reference.messageID.rawValue < $1.reference.messageID.rawValue
        }.map(\.reference)
        guard !sources.isEmpty else {
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
            switch try await messageForwarder.forward(sources: sources, targetRoomIDs: targetRoomIDs) {
            case .completed(let succeeded, let failed):
                if failed == 0 {
                    messageActionFeedback = "已转发 \(succeeded) 条消息，正在同步。"
                } else {
                    messageActionFeedback = "已转发 \(succeeded) 条；\(failed) 条未能发送。"
                }
                endForwardSelection()
                await refresh()
                return true
            case .queued:
                messageActionFeedback = "转发任务已保存，剩余消息会继续处理。"
                endForwardSelection()
                return true
            case .rejected(let code):
                messageActionFeedback = "转发被拒绝（\(code)）。"
                return false
            }
        } catch is CancellationError {
            return false
        } catch V2ForwardPlanAdmissionError.confirmationRequired {
            messageActionFeedback = "原转发结果仍待确认，请继续原计划，避免重复发送。"
            return false
        } catch V2OperationWorkError.capacityExceeded {
            messageActionFeedback = "待处理任务已达上限，已选择的消息和目标仍保留。"
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
                messageActionFeedback = "群公告确认已保存；两分钟内核对，超时需重新确认。"
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
            updateGroupRolePolicyState(.init(policies: [], recovery: .unavailable))
            messageActionFeedback = "群权限策略暂不可用。"
            return
        }
        removalPolicyIsCurrent = false
        messageRemovalProposal = nil
        rolePolicyReadGeneration &+= 1
        let generation = rolePolicyReadGeneration
        isLoadingGroupRolePolicies = true
        defer { isLoadingGroupRolePolicies = false }
        do {
            let policies = try await groupRolePolicyReader.groupRolePolicyState(in: roomID)
            try Task.checkCancellation()
            guard generation == rolePolicyReadGeneration else { return }
            updateGroupRolePolicyState(policies)
            removalPolicyIsCurrent = policies.recovery == .ready
        } catch is CancellationError {
            return
        } catch {
            guard generation == rolePolicyReadGeneration else { return }
            messageActionFeedback = "无法读取群权限策略。"
        }
    }

    func retryGroupRolePolicyRecovery() async {
        guard policyRecoveryAction != .requesting else { return }
        guard let groupRolePolicyReader else {
            updateGroupRolePolicyState(.init(policies: [], recovery: .unavailable))
            return
        }
        switch groupRolePolicyState.recovery {
        case .paused, .needed: break
        default: return
        }
        rolePolicyReadGeneration &+= 1
        let generation = rolePolicyReadGeneration
        policyRecoveryAction = .requesting
        do {
            let state = try await groupRolePolicyReader.retryGroupRolePolicyRecovery(in: roomID)
            try Task.checkCancellation()
            if generation == rolePolicyReadGeneration { updateGroupRolePolicyState(state) }
            policyRecoveryAction = .idle
        } catch is CancellationError {
            policyRecoveryAction = .idle
        } catch {
            policyRecoveryAction = generation == rolePolicyReadGeneration ? .failed : .idle
        }
    }

    private func updateGroupRolePolicyState(_ state: V2ClientGroupRolePolicyState) {
        if policyRecoveryAction == .failed, groupRolePolicyState.recovery != state.recovery {
            policyRecoveryAction = .idle
        }
        groupRolePolicyState = state
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
                messageActionFeedback = "群权限确认已保存；两分钟内核对，超时需重新确认。"
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

    private func invalidateGroupMemberDirectory() {
        groupMemberDirectoryIsStale = true
        groupMembers = []
        hasEarlierGroupMembers = false
        groupMemberRevision = nil
        groupActorRole = nil
        nextGroupMemberCursor = nil
        canLoadMoreGroupMembers = false
    }

    func loadGroupMembers(reset: Bool = false, reason: GroupMemberRefreshReason = .userInitiated) async {
        guard !Task.isCancelled else { return }
        if reset {
            groupMemberDirectoryIsStale = true
            groupActorRole = nil
            if reason == .authorizationChanged { invalidateGroupMemberDirectory() }
            if isLoadingGroupMembers {
                // Keep one network owner, but never publish a response that
                // predates a requested refresh (for example a role change).
                groupMemberReloadPending = true
                return
            }
        }
        guard !isLoadingGroupMembers else { return }
        guard let groupMemberDirectory else {
            groupMemberFeedback = "成员目录暂不可用。"
            return
        }
        var cursor = reset ? nil : nextGroupMemberCursor
        if !reset, cursor == nil, !groupMembers.isEmpty { return }
        var revisionRestarts = 0
        isLoadingGroupMembers = true
        defer { isLoadingGroupMembers = false; groupMemberReloadPending = false }
        while !Task.isCancelled {
            if groupMemberReloadPending {
                groupMemberReloadPending = false
                cursor = nil
                revisionRestarts = 0
            }
            do {
                let page = try await groupMemberDirectory.members(in: roomID, cursor: cursor)
                try Task.checkCancellation()
                if groupMemberReloadPending { continue }
                if cursor != nil, let loadedRevision = groupMemberRevision,
                   loadedRevision != page.membershipRevision || groupActorRole != page.actorRole {
                    invalidateGroupMemberDirectory()
                    guard revisionRestarts == 0 else {
                        groupMemberFeedback = "成员目录已变化，请刷新后重试。"
                        return
                    }
                    revisionRestarts += 1
                    cursor = nil
                    continue
                }
                let known = cursor == nil ? Set<String>() : Set(groupMembers.map(\.id))
                let incoming = Set(page.members.map(\.id))
                guard incoming.count == page.members.count, known.isDisjoint(with: incoming),
                      page.nextCursor == nil || page.nextCursor != cursor
                else {
                    invalidateGroupMemberDirectory()
                    groupMemberFeedback = "成员目录返回了无效分页，请刷新后重试。"
                    return
                }
                if cursor == nil {
                    groupMembers = page.members
                    hasEarlierGroupMembers = false
                } else { groupMembers += page.members }
                if groupMembers.count > 1_000 {
                    groupMembers.removeFirst(groupMembers.count - 1_000)
                    hasEarlierGroupMembers = true
                }
                groupMemberDirectoryIsStale = false
                groupMemberRevision = page.membershipRevision
                groupActorRole = page.actorRole
                nextGroupMemberCursor = page.nextCursor
                canLoadMoreGroupMembers = page.nextCursor != nil
                groupMemberFeedback = nil
                return
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                if groupMemberReloadPending { continue }
                groupMemberDirectoryIsStale = true
                groupActorRole = nil
                if (error as? V2HTTPFailure)?.statusCode == 403
                    || (error as? V2AuthSessionError) == .sessionInvalidated
                    || (error as? V2AuthSessionError) == .unauthenticated { invalidateGroupMemberDirectory() }
                if case V2RealtimeTransportError.server(let code, _, _, _) = error {
                    if code == "REVISION_CONFLICT" {
                        invalidateGroupMemberDirectory()
                        if cursor != nil, revisionRestarts == 0 {
                            revisionRestarts += 1
                            cursor = nil
                            continue
                        }
                    } else if code == "FORBIDDEN" || code == "NOT_FOUND" {
                        invalidateGroupMemberDirectory()
                    }
                }
                groupMemberFeedback = groupMembers.isEmpty
                    ? "无法读取群成员，请检查网络后重试。"
                    : "刷新失败，显示上次成员目录；刷新成功后可继续管理。"
                return
            }
        }
    }

    var canAddGroupMembers: Bool {
        !groupMemberDirectoryIsStale && !isLoadingGroupMembers && (groupActorRole == "群主" || groupActorRole == "管理员")
    }

    var canLeaveGroup: Bool {
        !groupMemberDirectoryIsStale && !isLoadingGroupMembers && groupMemberRevision != nil
            && (groupActorRole == "成员" || groupActorRole == "管理员")
    }

    private func canConfirmMembership(target: String, action: V2RoomMembershipAction) -> Bool {
        if action == .add { return canAddGroupMembers }
        if target == userID { return canLeaveGroup }
        return groupMembers.first(where: { $0.id == target }).map(canRemoveGroupMember) ?? false
    }

    @discardableResult func leaveGroup() async -> Bool {
        await changeGroupMembership(targetUserID: userID, action: .remove)
    }

    func canRemoveGroupMember(_ member: V2GroupMemberItem) -> Bool {
        guard !groupMemberDirectoryIsStale, !isLoadingGroupMembers, member.id != userID, member.role != "群主" else { return false }
        return groupActorRole == "群主" || groupActorRole == "管理员"
    }

    func canChangeGroupMemberRole(_ member: V2GroupMemberItem) -> Bool {
        !groupMemberDirectoryIsStale && !isLoadingGroupMembers && groupActorRole == "群主" && member.id != userID && member.role != "群主"
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
                await loadGroupMembers(reset: true, reason: .authorizationChanged)
            case .queuedForRetry:
                groupMemberFeedback = "角色确认已保存；两分钟内核对，超时需重新确认。"
            case .rejected(let code):
                groupMemberFeedback = "成员角色变更被拒绝（\(code)）。"
            }
        } catch is CancellationError {
            return
        } catch {
            groupMemberFeedback = "无法保存成员角色变更。"
        }
    }

    /// 禁言一名群成员。
    ///
    /// 审核保留独立的持久化命令与审计轨迹，而不复用普通成员移除；
    /// 权限与目标资格仍由服务端在受理命令时裁决。
    ///
    /// - Parameters:
    ///   - member: 目标成员。
    ///   - duration: 禁言时长秒数。
    private(set) var memberAdministrationPending:[V2MemberAdministrationPending]=[]
    func observeMemberAdministration() async {
        guard let manager=groupMemberMuter as? any V2MemberAdministrationManaging,let room=try? RoomID(roomID) else { return }
        do {
            for try await pending in await manager.administrationUpdates(roomID:room) {
                try Task.checkCancellation()
                let completedIDs = Set(memberAdministrationPending.compactMap { $0.work?.scheduling == .finished ? $0.work?.id : nil })
                if pending.contains(where: { value in
                    guard let work = value.work, work.scheduling == .finished,
                          !completedIDs.contains(work.id) else { return false }
                    return work.execution == .rejected || work.execution == .conflicted
                }) {
                    // A rejected authority/CAS attempt cannot keep an earlier
                    // member editing baseline valid for the next user proposal.
                    groupMemberDirectoryIsStale = true
                }
                memberAdministrationPending=pending
            }
        } catch is CancellationError {} catch { groupMemberFeedback="管理操作状态暂不可读，已保存的请求不会撤销。" }
    }
    func continueMemberAdministration(_ pending:V2MemberAdministrationPending) async {
        guard let manager=groupMemberMuter as? any V2MemberAdministrationManaging else { return }
        do {
            if pending.work != nil { try await manager.resumeAdministration(id:pending.id) }
            else {
                guard let revision=groupMemberRevision,let member=groupMembers.first(where:{$0.id==pending.intent.targetUserID.rawValue}),canRemoveGroupMember(member) else {
                    groupMemberFeedback="请先刷新成员与管理权限，再重新确认。";return
                }
                try await manager.reconfirmAdministration(id:pending.id,revision:revision)
            }
        } catch { groupMemberFeedback="无法继续；请刷新成员状态，或取消未提交的确认。" }
    }
    func discardMemberAdministration(_ pending:V2MemberAdministrationPending) async {
        guard pending.work==nil,let manager=groupMemberMuter as? any V2MemberAdministrationManaging else { return }
        do { try await manager.discardAdministration(id:pending.id) } catch { groupMemberFeedback="无法取消确认。" }
    }

    func muteGroupMember(_ member: V2GroupMemberItem, for duration: TimeInterval = 60 * 60) async {
        guard !isLoadingGroupMembers, !isChangingGroupMembership, !isApplyingGroupModeration,
              canRemoveGroupMember(member)
        else { return }
        guard duration > 0, let revision=groupMemberRevision, let groupMemberMuter else {
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
                reasonCode: try .init("ADMIN_ACTION"),
                expectedMembershipRevision:revision
            )
            try Task.checkCancellation()
            switch outcome {
            case .accepted:
                groupMemberFeedback = "禁言已提交，正在同步。"
            case .queuedForRetry:
                groupMemberFeedback = "禁言确认已保存；将在两分钟确认窗口内核对权限，超时需重新确认。"
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
        guard let revision=groupMemberRevision, let moderatedGroupMemberRemover else {
            groupMemberFeedback = "管理员移除暂不可用。"
            return
        }
        isApplyingGroupModeration = true
        defer { isApplyingGroupModeration = false }
        do {
            let outcome = try await moderatedGroupMemberRemover.removeMemberByModerator(
                roomID: roomID,
                targetUserID: member.id,
                reasonCode: try .init("ADMIN_ACTION"),
                expectedMembershipRevision:revision
            )
            try Task.checkCancellation()
            switch outcome {
            case .accepted:
                groupMemberFeedback = "管理员移除已提交，正在同步。"
                await loadGroupMembers(reset: true, reason: .authorizationChanged)
            case .queuedForRetry:
                groupMemberFeedback = "移除确认已保存；将在两分钟确认窗口内核对权限，超时需重新确认。"
            case .rejected:
                groupMemberFeedback = "无法完成群管理操作。"
            }
        } catch is CancellationError {
            return
        } catch {
            groupMemberFeedback = "无法保存管理员移除请求。"
        }
    }

    private(set) var membershipPending:[V2MembershipPending]=[]
    func observeMembership() async {
        guard let manager=groupMembershipChanger as? any V2MembershipManaging,let room=try? RoomID(roomID) else { return }
        var observed:Set<UUID>=[]
        do {
            for try await pending in await manager.membershipUpdates(roomID:room) {
                try Task.checkCancellation();membershipPending=pending
                let committed=Set(pending.filter{$0.work?.execution == .committed}.map(\.id))
                let observedBefore = observed
                let changed = !committed.subtracting(observedBefore).isEmpty
                observed=committed
                if changed {
                    let selfExitCommitted = pending.contains {
                        $0.work?.execution == .committed && $0.intent.action == .remove
                            && $0.intent.targetUserID.rawValue == userID
                            && !observedBefore.contains($0.id)
                    }
                    if selfExitCommitted {
                        invalidateGroupMemberDirectory()
                        groupMemberFeedback = "已退出群聊。"
                    } else { await loadGroupMembers(reset:true,reason:.authorizationChanged) }
                }
            }
        } catch is CancellationError {} catch { groupMemberFeedback="成员操作状态暂不可读，已保存的请求不会撤销。" }
    }
    func continueMembership(_ pending:V2MembershipPending) async {
        guard let changer=groupMembershipChanger,let manager=changer as? any V2MembershipManaging else { return }
        do {
            if pending.work != nil { try await manager.resumeMembership(id:pending.id) }
            else {
                guard !groupMemberDirectoryIsStale,let revision=groupMemberRevision,
                    canConfirmMembership(target: pending.intent.targetUserID.rawValue, action: pending.intent.action)
                else { groupMemberFeedback="请先刷新成员与权限，再重新确认此操作。";return }
                let confirmation=try changer.membershipConfirmation(roomID:roomID,action:pending.intent.action,expectedMembershipRevision:revision)
                try await manager.reconfirmMembership(id:pending.id,confirmation:confirmation)
            }
        } catch { groupMemberFeedback="无法继续成员操作；请刷新权限，或取消未提交的确认。" }
    }
    func discardMembership(_ pending:V2MembershipPending) async {
        guard pending.work==nil,let manager=groupMembershipChanger as? any V2MembershipManaging else { return }
        do { try await manager.discardMembership(id:pending.id) } catch { groupMemberFeedback="无法取消成员确认。" }
    }

    @discardableResult func changeGroupMembership(targetUserID: String, action: V2RoomMembershipAction) async -> Bool {
        guard !isLoadingGroupMembers, !isChangingGroupMembership, !isApplyingGroupModeration else {
            return false
        }
        let input = targetUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            groupMemberFeedback = action == .add ? "请输入成员公开 ID。" : "请输入成员。"
            return false
        }
        guard !groupMemberDirectoryIsStale, let revision = groupMemberRevision else {
            groupMemberFeedback = "请先刷新成员目录。"
            return false
        }
        guard let groupMembershipChanger else {
            groupMemberFeedback = "成员变更暂不可用。"
            return false
        }
        guard canConfirmMembership(target: input, action: action) else {
            groupMemberFeedback="当前成员权限不可用，请刷新后确认。";return false
        }
        isChangingGroupMembership = true
        defer { isChangingGroupMembership = false }
        do {
            let confirmation=try groupMembershipChanger.membershipConfirmation(roomID:roomID,action:action,expectedMembershipRevision:revision)
            let target: String
            if action == .add {
                guard let publicIdentityResolver else {
                    groupMemberFeedback = "身份目录暂不可用，无法解析成员公开 ID。"
                    return false
                }
                target = try await V2HTTPRequestDeadline.run(until:min(confirmation.deadline,.now.advanced(by:.seconds(15))),service:"accountAPI") { try await publicIdentityResolver.resolve(handle:input).userID.rawValue }
                try Task.checkCancellation()
            } else {
                target = input
            }
            guard !groupMemberDirectoryIsStale,groupMemberRevision==revision else { groupMemberFeedback="成员版本已变化，请刷新后重新确认。";return false }
            let outcome = try await groupMembershipChanger.changeMembership(targetUserID:target,confirmation:confirmation)
            try Task.checkCancellation()
            switch outcome {
            case .accepted:
                if action == .remove && target == userID {
                    invalidateGroupMemberDirectory()
                    groupMemberFeedback = "已退出群聊。"
                } else {
                    groupMemberFeedback = nil
                    await loadGroupMembers(reset: true, reason: .authorizationChanged)
                }
            case .queuedForRetry:
                groupMemberFeedback = action == .remove && target == userID
                    ? "退出确认已保存；正在核对原操作结果，尚未确认退出。"
                    : "成员确认已保存；两分钟窗口内核对权限，超时需重新确认。"
            case .rejected(let code):
                groupMemberFeedback = "成员变更被拒绝（\(code)），请刷新后重试。"
                return false
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            groupMemberFeedback = "无法保存成员变更，当前输入已保留。"
            return false
        }
    }
}

private enum V2ConversationMentionInputError: Error, Sendable {
    case invalidInput
}
