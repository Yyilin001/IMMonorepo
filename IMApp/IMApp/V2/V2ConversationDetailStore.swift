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
    private let groupMessagePinner: (any V2GroupMessagePinning)?
    private let messageForwarder: (any V2MessageForwarding)?
    let forwardTargets: [V2ConversationForwardTarget]
    private let groupAnnouncementReader: (any V2GroupAnnouncementReading)?
    private let groupAnnouncementManager: (any V2GroupAnnouncementManaging)?
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
    private let attachmentUploader: (any V2ConversationAttachmentUploading)?
    private let mediaDownloader: (any V2ConversationMediaDownloading)?
    private let projectionChangeNotifier: V2ProjectionChangeNotifier?
    private let roomSubscriptions: V2RoomSubscriptionCoordinator?
    private let activeHybridGroupSynchronizer: (any V2ActiveHybridGroupSynchronizing)?
    let roomID: String
    let title: String
    let kind: V2ConversationKind
    var isGroupConversation: Bool { kind.isGroup }
    var directAccountKind: V2AccountKind? { kind.directAccountKind }
    private(set) var messages: [V2ConversationMessageItem] = []
    private(set) var timeline: [V2ConversationTimelineItem] = []
    private(set) var timelineRevision: UInt64 = 0
    private(set) var canLoadOlderTimeline = false
    private(set) var isLoadingOlderTimeline = false
    private(set) var isBrowsingHistoricalTimeline = false
    private(set) var isReturningToLatestTimeline = false
    private(set) var canSendInDirectConversation: Bool?
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
        groupMessagePinner = environment.messages.groupPinner
        messageForwarder = environment.messages.forwarder
        forwardTargets = context.forwardTargets
        groupAnnouncementReader = environment.projections.groupAnnouncementReader
            ?? (environment.projections.dataSource as? any V2GroupAnnouncementReading)
        groupAnnouncementManager = environment.groups.announcementManager
        groupMemberRoleChanger = environment.groups.memberRoleChanger
        groupRolePolicyReader = environment.projections.groupRolePolicyReader
            ?? (environment.projections.dataSource as? any V2GroupRolePolicyAccessing)
        groupRolePolicyChanger = environment.groups.rolePolicyChanger
        groupReadReceiptReader = environment.groups.readReceiptReader
        conversationLiveActivity = environment.runtime.liveActivity
        userID = environment.userID
        roomID = context.roomID
        title = context.title
        kind = context.kind
        groupMemberDirectory = environment.groups.memberDirectory
        groupMembershipChanger = environment.groups.membershipChanger
        groupMemberMuter = environment.groups.memberMuter
        moderatedGroupMemberRemover = environment.groups.moderatedMemberRemover
        publicIdentityResolver = environment.discovery.publicIdentityResolver
        attachmentStager = environment.media.attachmentStager
        attachmentUploader = environment.media.attachmentUploader
        mediaDownloader = environment.media.downloader
        projectionChangeNotifier = environment.runtime.projectionChangeNotifier
        activeHybridGroupSynchronizer = environment.runtime.activeHybridGroupSynchronizer
        roomSubscriptions = environment.runtime.roomSubscriptions
        draft = context.initialDraft ?? ""
        mentionHandlesText = context.initialMentionHandles ?? ""
    }

    func messageSearchStore() -> V2ConversationSearchStore? {
        guard let messageSearcher, let roomID = try? RoomID(roomID) else { return nil }
        return .init(searcher: messageSearcher, scope: .room(roomID))
    }

    func refresh() async {
        if timelineLocationID != nil { refreshAfterTimelineLocation = true; return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        if timeline.isEmpty { state = .loading }
        do {
            // Preserve only the window the user explicitly loaded. The normal
            // path remains a small page, while edits/withdrawals inside the
            // visible window are refreshed from one SQLite snapshot.
            let page = try await dataSource.timelinePage(
                in: roomID,
                for: userID,
                before: newerTimelineBoundary,
                limit: min(
                    Self.maximumRetainedTimelineItems,
                    max(Self.initialTimelinePageSize, timeline.count)
                )
            )
            try Task.checkCancellation()
            guard generation == refreshGeneration else { return }
            let refreshedTimeline = page.items
            let refreshedMessages = Self.messages(in: refreshedTimeline)
            let refreshedCanSend: Bool? = if !isGroupConversation, let sendingCapabilityReader {
                try await sendingCapabilityReader.directSendingCapability(in: roomID)
            } else {
                nil
            }
            try Task.checkCancellation()
            guard generation == refreshGeneration else { return }
            let refreshedAnnouncement: V2ClientGroupAnnouncement? = if isGroupConversation, let groupAnnouncementReader {
                try await groupAnnouncementReader.groupAnnouncement(in: roomID)
            } else {
                nil
            }
            try Task.checkCancellation()
            guard generation == refreshGeneration else { return }
            rolePolicyReadGeneration &+= 1
            let policyReadGeneration = rolePolicyReadGeneration
            let refreshedPolicies: V2ClientGroupRolePolicyState = if isGroupConversation, let groupRolePolicyReader {
                try await groupRolePolicyReader.groupRolePolicyState(in: roomID)
            } else { .init(policies: [], recovery: .unavailable) }
            try Task.checkCancellation()
            guard generation == refreshGeneration else { return }
            await discardMediaRevokedByRedaction(previous: messages, refreshed: refreshedMessages)
            try Task.checkCancellation()
            guard generation == refreshGeneration else { return }
            messages = refreshedMessages
            timeline = refreshedTimeline
            timelineRevision &+= 1
            canLoadOlderTimeline = page.olderCursor != nil
            isBrowsingHistoricalTimeline = newerTimelineBoundary != nil
            canSendInDirectConversation = refreshedCanSend
            groupAnnouncement = refreshedAnnouncement
            if policyReadGeneration == rolePolicyReadGeneration { updateGroupRolePolicyState(refreshedPolicies) }
            let visibleMediaIDs = Set(refreshedMessages.lazy
                .filter { !$0.isWithdrawn }
                .flatMap(\.media)
                .map(\.mediaID))
            mediaDownloadStates = mediaDownloadStates.filter { visibleMediaIDs.contains($0.key) }
            state = .loaded
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
        await V2ProjectionRefreshObserver.run(await projectionChangeNotifier.updates(scopes: .conversationDetails)) { [self] in
            await refresh()
        }
    }

    /// 轮询可见的混合大群事件。
    ///
    /// 该任务由详情视图的 `.task` 修饰符持有，因此用户离开会话或场景销毁时会自动停止。
    /// 生产房间在既有 TLS 连接上等待服务端唤醒；30 秒一次的游标拉取仅作为丢消息后的恢复手段。
    func pollVisibleHybridGroupEvents() async {
        guard isGroupConversation,
              let activeHybridGroupSynchronizer
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
            if requiresDurablePull {
                let shouldContinue = await synchronizeHybridGroupUntilIdle(synchronizer)
                guard shouldContinue else { return }
            }
            do {
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
                await waitAfterRealtimeWakeFailure()
            }
        }
    }

    /// 在混合大群恢复宽限期内等待，并判断是否应当改为拉取。
    ///
    /// 这里只等待仅含元数据的唤醒。畸形或不连续的实时载荷仍会立即进入持久化恢复流程，
    /// 绝不能用于推进游标。即使不断有更新的元数据唤醒到达，总等待时间仍有截止上限。
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
        guard initialWake.liveEvents.isEmpty else { return true }
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

    private func waitAfterRealtimeWakeFailure() async {
        do {
            try await Task.sleep(for: .seconds(1))
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
                messageID: message.id,
                cursor: cursor
            )
            try Task.checkCancellation()
            guard page.roomID.rawValue == roomID, page.messageID.rawValue == message.id else {
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
                    messageID: page.messageID,
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
            updateGroupRolePolicyState(.init(policies: [], recovery: .unavailable))
            messageActionFeedback = "群权限策略暂不可用。"
            return
        }
        rolePolicyReadGeneration &+= 1
        let generation = rolePolicyReadGeneration
        isLoadingGroupRolePolicies = true
        defer { isLoadingGroupRolePolicies = false }
        do {
            let policies = try await groupRolePolicyReader.groupRolePolicyState(in: roomID)
            try Task.checkCancellation()
            guard generation == rolePolicyReadGeneration else { return }
            updateGroupRolePolicyState(policies)
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
        var cursor = reset ? nil : nextGroupMemberCursor
        if !reset, cursor == nil, !groupMembers.isEmpty { return }
        var replaceCurrentRoster = reset
        isLoadingGroupMembers = true
        defer { isLoadingGroupMembers = false }
        for attempt in 0..<2 {
            do {
                let page = try await groupMemberDirectory.members(in: roomID, cursor: cursor)
                try Task.checkCancellation()
                // A defensive client-side fence protects older or mixed
                // server deployments too. Restart once instead of ever
                // appending pages from different membership revisions.
                if cursor != nil,
                   let loadedRevision = groupMemberRevision,
                   loadedRevision != page.membershipRevision,
                   attempt == 0 {
                    cursor = nil
                    replaceCurrentRoster = true
                    continue
                }
                if replaceCurrentRoster {
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
                return
            } catch is CancellationError {
                return
            } catch V2RealtimeTransportError.server(let code, _, _, _) where code == "REVISION_CONFLICT" && cursor != nil && attempt == 0 {
                cursor = nil
                replaceCurrentRoster = true
                continue
            } catch {
                groupMemberFeedback = "无法读取群成员，请检查网络后重试。"
                return
            }
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

    /// 禁言一名群成员。
    ///
    /// 审核保留独立的持久化命令与审计轨迹，而不复用普通成员移除；
    /// 权限与目标资格仍由服务端在受理命令时裁决。
    ///
    /// - Parameters:
    ///   - member: 目标成员。
    ///   - duration: 禁言时长秒数。
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
