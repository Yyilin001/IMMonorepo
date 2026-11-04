import Foundation
import IMV2ClientKit
import IMV2Core
import Observation
import UIKit

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
    private let messageSearcher: (any V2ConversationMessageSearching)?
    private let messageWithdrawer: (any V2MessageWithdrawing)?
    private let messageReactionChanger: (any V2MessageReactionChanging)?
    private let messageEditor: (any V2MessageEditing)?
    private let readReceiptReporter: (any V2ConversationReadReporting)?
    private let messageFavoriter: (any V2MessageFavoriting)?
    private let messageForwarder: (any V2MessageForwarding)?
    let forwardTargets: [V2ConversationForwardTarget]
    private let groupAvatarManager: (any V2GroupAvatarManaging)?
    private let nameOperations: V2NameOperationService?
    private let userID: String
    private let attachmentStager: (any V2ConversationAttachmentStaging)?
    private let resourceSender: (any V2DurableConversationSending)?
    private let mediaDownloader: (any V2ConversationMediaDownloading)?
    private let mediaThumbnails: V2LocalMediaThumbnailCache?
    private let projectionChangeNotifier: V2ProjectionChangeNotifier?
    private let roomSubscriptions: V2RoomSubscriptionCoordinator?
    private let activeHybridGroupSynchronizer: (any V2ActiveHybridGroupSynchronizing)?
    let liveActivity: V2ConversationActivityStore
    let groupReadReceipts: V2GroupReadReceiptStore
    let groupManagement: V2GroupManagementStore
    let composer: V2ConversationComposerStore
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
    private(set) var state: State = .loading
    private(set) var messageActionFeedback: String?
    private(set) var mediaDownloadStates: [MediaID: V2ConversationMediaDownloadState] = [:]
    private(set) var initialImagePreviews: [MediaID: V2SendableImage] = [:]
    private var refreshGeneration = 0
    private var newerTimelineBoundary: V2ConversationTimelineCursor?
    private var timelineLocationID: UUID?
    private var refreshAfterTimelineLocation = false
    private let messageActions: V2ConversationMessageActionActivity
    private(set) var isSelectingMessagesForForward = false
    private struct SelectedForwardSource {
        let reference: V2ForwardMessageReference
        let roomSequence: UInt64
    }
    private var selectedForwardSources: [String: SelectedForwardSource] = [:]
    var selectedForwardMessageIDs: Set<String> { Set(selectedForwardSources.keys) }
    private(set) var isForwardingMessages = false

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
        composer = V2ConversationComposerStore(
            roomID: context.roomID, kind: context.kind, sender: environment.messages.sender,
            attachmentStager: environment.media.attachmentStager, resourceSender: environment.media.resourceSender,
            publicIdentityResolver: environment.discovery.publicIdentityResolver,
            sendingCapabilityReader: environment.projections.dataSource as? any V2ConversationSendingCapabilityReading,
            initialDraft: context.initialDraft, initialMentionHandles: context.initialMentionHandles)
        let messageActions = V2ConversationMessageActionActivity()
        self.messageActions = messageActions
        groupManagement = V2GroupManagementStore(
            roomID: context.roomID, userID: environment.userID, kind: context.kind,
            groups: environment.groups,
            announcementReader: environment.projections.groupAnnouncementReader
                ?? (environment.projections.dataSource as? any V2GroupAnnouncementReading),
            policyReader: environment.projections.groupRolePolicyReader
                ?? (environment.projections.dataSource as? any V2GroupRolePolicyAccessing),
            messagePinner: environment.messages.groupPinner, messageModerator: environment.messages.moderator,
            publicIdentityResolver: environment.discovery.publicIdentityResolver, messageActions: messageActions)
        messageSearcher = environment.projections.messageSearcher
        messageWithdrawer = environment.messages.withdrawer
        messageReactionChanger = environment.messages.reactionChanger
        messageEditor = environment.messages.editor
        readReceiptReporter = environment.messages.readReceiptReporter
        messageFavoriter = environment.messages.favoriter
        messageForwarder = environment.messages.forwarder
        forwardTargets = context.forwardTargets
        groupAvatarManager = environment.groups.avatarManager
        nameOperations = environment.groups.nameOperations
        liveActivity = V2ConversationActivityStore(
            roomID: context.roomID, userID: environment.userID, kind: context.kind,
            activity: environment.runtime.liveActivity, roomSubscriptions: environment.runtime.roomSubscriptions)
        groupReadReceipts = V2GroupReadReceiptStore(
            roomID: context.roomID, kind: context.kind, reader: environment.groups.readReceiptReader)
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
        attachmentStager = environment.media.attachmentStager
        resourceSender = environment.media.resourceSender
        mediaDownloader = environment.media.downloader
        mediaThumbnails = environment.media.thumbnails
        projectionChangeNotifier = environment.runtime.projectionChangeNotifier
        activeHybridGroupSynchronizer = environment.runtime.activeHybridGroupSynchronizer
        roomSubscriptions = environment.runtime.roomSubscriptions
    }

    var canSearchMessages: Bool { messageSearcher != nil && (try? RoomID(roomID)) != nil }

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
            let refreshedTimeline = page?.items ?? timeline
            let refreshedMessages = refreshTimeline ? Self.messages(in: refreshedTimeline) : messages
            // Publish the local timeline before unrelated profile/policy reads.
            // Redaction cleanup still precedes publication of image pixels.
            if refreshTimeline { await discardMediaRevokedByRedaction(previous: messages, refreshed: refreshedMessages) }
            try Task.checkCancellation()
            guard generation == refreshGeneration else { return }
            if refreshTimeline, timeline.isEmpty {
                await seedDecodedImagePreviews(from: refreshedMessages, generation: generation)
                try Task.checkCancellation()
                guard generation == refreshGeneration else { return }
            }
            let timelineChanged = refreshTimeline && refreshedTimeline != timeline
            if refreshTimeline {
                if timelineChanged {
                    messages = refreshedMessages
                    timeline = refreshedTimeline
                    timelineRevision &+= 1
                }
                canLoadOlderTimeline = page?.olderCursor != nil
            }
            if refreshTimeline {
                let visibleMediaIDs = Set(refreshedMessages.lazy
                    .filter { !$0.isWithdrawn }
                    .flatMap(\.media)
                    .map(\.mediaID))
                mediaDownloadStates = mediaDownloadStates.filter { visibleMediaIDs.contains($0.key) }
                imagePreviewStates = imagePreviewStates.filter { visibleMediaIDs.contains($0.key) }
                initialImagePreviews = initialImagePreviews.filter { visibleMediaIDs.contains($0.key) }
            }
            if refreshTimeline { state = .loaded }
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
            if refreshMetadata { await composer.refreshSendingCapability() }
            try Task.checkCancellation()
            guard generation == refreshGeneration else { return }
            if refreshMetadata {
                await groupManagement.refreshMetadata()
                try Task.checkCancellation()
                guard generation == refreshGeneration else { return }
            }
            // 标记只增不减：一旦确认缺过历史，就不因一次读失败或旧快照而"变完整"。
            isHistoryIncomplete = isHistoryIncomplete || refreshedHistoryIncomplete
            isBrowsingHistoricalTimeline = newerTimelineBoundary != nil
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
        let cache = mediaDownloader as? any V2ConversationMediaCacheDiscarding
        let withdrawnIDs = Set(refreshed.lazy.filter(\.isWithdrawn).map(\.id))
        for message in previous where !message.isWithdrawn && withdrawnIDs.contains(message.id) {
            for media in message.media {
                guard !Task.isCancelled else { return }
                outgoingPreviews.removeObject(forKey: media.mediaID.rawValue as NSString)
                await cache?.discard(media)
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

    func sendDraft() async {
        guard case .refreshTimeline = await composer.sendDraft() else { return }
        await refresh()
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

    func replyPreview(for reference: V2MessageReplyReference) -> String {
        guard let target = messages.first(where: { $0.id == reference.messageID.rawValue }) else {
            return "原消息不可用"
        }
        return target.text.isEmpty ? "附件" : target.text
    }

    func mediaDownloadState(for media: V2MediaReference) -> V2ConversationMediaDownloadState {
        mediaDownloadStates[media.mediaID] ?? .notDownloaded
    }

    private(set) var imagePreviewStates: [MediaID: V2ConversationMediaDownloadState] = [:]
    @ObservationIgnored private var imagePreviewRequestIDs: [MediaID: UUID] = [:]

    /// Strict cache-only first snapshot: no authorization request, file read,
    /// decode, shared-flight wait or network operation is admitted here.
    private func seedDecodedImagePreviews(from snapshot: [V2ConversationMessageItem], generation: Int) async {
        guard let mediaDownloader, let mediaThumbnails else { return }
        var inspected = 0
        for message in snapshot.reversed() where !message.isWithdrawn {
            for media in message.media {
                guard !Task.isCancelled, generation == refreshGeneration, inspected < 8 else { return }
                guard message.mediaPresentations.contains(where: {
                    $0.mediaID == media.mediaID && ($0.kind == .image || $0.kind == .animatedImage)
                }) else { continue }
                inspected += 1
                do {
                    let location = try V2MediaMessageLocation(roomID: RoomID(roomID), messageID: MessageID(message.id))
                    guard let file = try await mediaDownloader.cachedImagePreview(media, message: location),
                          let image = await mediaThumbnails.cachedThumbnail(fileURL: file.fileURL, maximumPixelSize: 1280)
                    else { continue }
                    try Task.checkCancellation()
                    guard generation == refreshGeneration else { return }
                    let cost = image.image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
                    guard retainedImagePreviewBytes + cost <= 16 * 1_024 * 1_024 else { return }
                    retainImagePreview(image, for: media.mediaID)
                    imagePreviewStates[media.mediaID] = .downloaded(file)
                } catch is CancellationError { return }
                catch { continue }
            }
        }
    }

    // Owned by this conversation; pending and confirmed rows have different lifetimes.
    @ObservationIgnored private let outgoingPreviews: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 24 * 1024 * 1024
        cache.countLimit = 32
        return cache
    }()

    func rememberOutgoingPreview(_ image: UIImage, for mediaID: MediaID) {
        guard let pixels = image.cgImage else { return }
        outgoingPreviews.setObject(image, forKey: mediaID.rawValue as NSString, cost: pixels.bytesPerRow * pixels.height)
    }

    func outgoingPreview(for mediaID: MediaID) -> UIImage? {
        outgoingPreviews.object(forKey: mediaID.rawValue as NSString)
    }

    private var retainedImagePreviewBytes: Int {
        initialImagePreviews.values.reduce(0) { $0 + ($1.image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0) }
    }

    private func retainImagePreview(_ image: V2SendableImage, for mediaID: MediaID) {
        let seedBudget = 16 * 1_024 * 1_024
        let cost = image.image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        initialImagePreviews[mediaID] = nil
        while retainedImagePreviewBytes + cost > seedBudget || initialImagePreviews.count >= 32 {
            guard let oldest = initialImagePreviews.keys.first else { break }
            initialImagePreviews[oldest] = nil
        }
        if cost <= seedBudget { initialImagePreviews[mediaID] = image }
    }

    func loadImagePreview(_ media: V2MediaReference, from message: V2ConversationMessageItem) async {
        guard !message.isWithdrawn, message.media.contains(media), let mediaDownloader, let mediaThumbnails,
              !Task.isCancelled else { return }
        if case .downloaded = imagePreviewStates[media.mediaID] { return }
        let requestID = UUID()
        imagePreviewRequestIDs[media.mediaID] = requestID
        defer { if imagePreviewRequestIDs[media.mediaID] == requestID { imagePreviewRequestIDs[media.mediaID] = nil } }
        imagePreviewStates[media.mediaID] = .downloading
        do {
            let location = try V2MediaMessageLocation(roomID: RoomID(roomID), messageID: MessageID(message.id))
            let file = try await mediaDownloader.imagePreview(media, message: location)
            let lease = try await file.borrowFile()
            let image = await mediaThumbnails.thumbnail(fileURL: lease.fileURL, maximumPixelSize: 1280)
            await lease.release()
            try Task.checkCancellation()
            guard imagePreviewRequestIDs[media.mediaID] == requestID else { return }
            guard messages.contains(where: { $0.id == message.id && $0.revision == message.revision && !$0.isWithdrawn && $0.media.contains(media) }),
                  let image else { throw V2MediaFileAccessError.unavailable }
            // Keep only a small seed window; row-owned pixels and the account
            // thumbnail cache handle older rows without retaining the whole history.
            retainImagePreview(image, for: media.mediaID)
            imagePreviewStates[media.mediaID] = .downloaded(file)
            outgoingPreviews.removeObject(forKey: media.mediaID.rawValue as NSString)
        } catch is CancellationError {
            if imagePreviewRequestIDs[media.mediaID] == requestID { imagePreviewStates[media.mediaID] = nil }
        } catch {
            if imagePreviewRequestIDs[media.mediaID] == requestID { imagePreviewStates[media.mediaID] = .failed }
        }
    }

    func imagePreviewUnavailable(_ file: V2DownloadedConversationMedia) {
        guard imagePreviewStates[file.mediaID] == .downloaded(file) else { return }
        imagePreviewStates[file.mediaID] = .failed
        initialImagePreviews[file.mediaID] = nil
    }

    func originalImage(_ media: V2MediaReference, from message: V2ConversationMessageItem) async -> UIImage? {
        await downloadMedia(media, from: message)
        guard case .downloaded(let file) = mediaDownloadState(for: media), let mediaThumbnails else { return nil }
        do {
            let lease = try await file.borrowFile()
            let image = await mediaThumbnails.thumbnail(fileURL: lease.fileURL, maximumPixelSize: 2048)
            await lease.release()
            guard !Task.isCancelled, messages.contains(where: { $0.id == message.id && !$0.isWithdrawn && $0.media.contains(media) }) else { return nil }
            return image?.image
        } catch { return nil }
    }

    func restoreCachedMedia(_ media: V2MediaReference, from message: V2ConversationMessageItem) async {
        guard !message.isWithdrawn, message.media.contains(media), let mediaDownloader,
              mediaDownloadState(for: media) == .notDownloaded else { return }
        do {
            guard let file = try await mediaDownloader.cachedFile(media,
                message: .init(roomID: RoomID(roomID), messageID: MessageID(message.id))) else { return }
            try Task.checkCancellation()
            guard mediaDownloadState(for: media) == .notDownloaded,
                  messages.contains(where: { $0.id == message.id && $0.revision == message.revision && !$0.isWithdrawn && $0.media.contains(media) }) else { return }
            mediaDownloadStates[media.mediaID] = .downloaded(file)
        } catch {
            // A passive cache lookup never overrides an explicit download or
            // turns an offline/unauthorized cache miss into a failed transfer.
        }
    }

    func mediaFileUnavailable(_ downloaded: V2DownloadedConversationMedia) {
        guard mediaDownloadStates[downloaded.mediaID] == .downloaded(downloaded) else { return }
        mediaDownloadStates[downloaded.mediaID] = .notDownloaded
        initialImagePreviews[downloaded.mediaID] = nil
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
        messageActions.contains(message.id)
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

    private func beginMessageAction(for message: V2ConversationMessageItem) -> Bool {
        messageActions.begin(message.id)
    }

    private func finishMessageAction(for message: V2ConversationMessageItem) {
        messageActions.finish(message.id)
    }


}
