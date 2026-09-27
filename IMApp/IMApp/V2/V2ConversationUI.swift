import Foundation
import IMV2ClientKit
import IMV2Core
import Observation
import SwiftUI
import UIKit
import AVKit
import UniformTypeIdentifiers

/// 面向应用的值类型会话种类。
///
/// 界面不会直接读取 SQLite 行或同步事件载荷，从而使导航与渲染保持可测试。
enum V2ConversationKind: Hashable, Sendable {
    /// 已获得授权且有界公开身份投影的私聊房间。
    case direct(accountKind: V2AccountKind)
    /// 带精简房间资料投影的群房间。
    case group
    /// 消息先于其房间投影到达。
    ///
    /// 这类房间应当保持可读，但不得凭空赋予其私聊账号分类。
    case unknown

    var accessibilityIdentifierComponent: String {
        switch self {
        case .direct: "direct"
        case .group: "group"
        case .unknown: "unknown"
        }
    }

    var isGroup: Bool {
        if case .group = self { true } else { false }
    }

    var directAccountKind: V2AccountKind? {
        if case .direct(let accountKind) = self { accountKind } else { nil }
    }
}

struct V2ConversationListItem: Hashable, Identifiable, Sendable {
    let presentationKey: V2ProfileViewLookupKey?

    let id: String
    let title: String
    let preview: String
    let lastActivity: Date
    let isOutgoing: Bool
    let kind: V2ConversationKind
    let isPinned: Bool
    let isArchived: Bool
    let muteUntil: Date?
    /// 展示用未读数；服务端未读经本地已读水位收窄后的结果。
    ///
    /// 轮转还没覆盖到的房间为 0：界面不显示角标，也不用本地推算冒充服务端值。
    let unreadCount: UInt64?

    init(id: String, title: String, preview: String, lastActivity: Date, isOutgoing: Bool, kind: V2ConversationKind, isPinned: Bool = false, isArchived: Bool = false, muteUntil: Date? = nil, unreadCount: UInt64? = nil, presentationKey: V2ProfileViewLookupKey? = nil) {
        self.presentationKey = presentationKey
        self.id = id
        self.title = title
        self.preview = preview
        self.lastActivity = lastActivity
        self.isOutgoing = isOutgoing
        self.kind = kind
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.muteUntil = muteUntil
        self.unreadCount = unreadCount
    }
}

/// 转发选择器中展示的值类型目标。
///
/// 用户看到的是标题，不透明标识仍被限制在存储边界内部。
struct V2ConversationForwardTarget: Hashable, Identifiable, Sendable {
    let roomID: String
    let label: V2ConversationLabel

    var id: String { roomID }
}

struct V2ConversationMessageItem: Hashable, Identifiable, Sendable {
    let senderUserID: UserID?
    let id: String
    let roomSequence: UInt64
    let revision: UInt64
    let text: String
    /// 来自本地投影的不透明媒体标识。
    ///
    /// 界面可以据此显示消息带有附件，但绝不会在此拿到提供方地址。
    let media: [V2MediaReference]
    /// 针对 `media` 的、由服务端派生的非敏感展示事实。
    ///
    /// 视图据此选择图片或文件样式，无需读取对象存储元数据，也无需假设提供方地址。
    let mediaPresentations: [V2MediaPresentation]
    /// 协议层的提及目标。
    ///
    /// 界面保持标识不透明，消息气泡只暴露汇总后的提及语义。
    let mentions: [V2MentionTarget]
    let entities: [V2MessageEntity]
    let replyTo: V2MessageReplyReference?
    let createdAt: Date
    let isOutgoing: Bool
    /// 由对端持久化回执投影出的私聊已读状态。
    ///
    /// 群回执详情刻意按需查询，不会在常规时间线渲染时为每一行都填充。
    let isReadByPeer: Bool
    let isWithdrawn: Bool
    let isFavorited: Bool
    let isPinnedInGroup: Bool
    let isForwarded: Bool
    let reactions: [V2ConversationMessageReaction]

    init(id: String, roomSequence: UInt64 = 1, revision: UInt64, text: String, media: [V2MediaReference] = [], mediaPresentations: [V2MediaPresentation] = [], mentions: [V2MentionTarget] = [], entities: [V2MessageEntity] = [], replyTo: V2MessageReplyReference? = nil, createdAt: Date, isOutgoing: Bool, isWithdrawn: Bool, reactions: [V2ConversationMessageReaction] = [], isReadByPeer: Bool = false, isFavorited: Bool = false, isPinnedInGroup: Bool = false, isForwarded: Bool = false, senderUserID: UserID? = nil) {
        self.senderUserID = senderUserID
        self.id = id
        self.roomSequence = roomSequence
        self.revision = revision
        self.text = text
        self.media = media
        precondition(mediaPresentations.map(\.mediaID) == media.map(\.mediaID))
        self.mediaPresentations = mediaPresentations
        self.mentions = mentions
        self.entities = entities
        self.replyTo = replyTo
        self.createdAt = createdAt
        self.isOutgoing = isOutgoing
        self.isReadByPeer = isReadByPeer
        self.isWithdrawn = isWithdrawn
        self.isFavorited = isFavorited
        self.isPinnedInGroup = isPinnedInGroup
        self.isForwarded = isForwarded
        self.reactions = reactions
    }

    func presentation(for media: V2MediaReference) -> V2MediaPresentation {
        guard let presentation = mediaPresentations.first(where: { $0.mediaID == media.mediaID }) else {
            preconditionFailure("message media presentation is missing")
        }
        return presentation
    }
}

/// 会话流的纯渲染联合类型。
///
/// 把活动条目与 `V2ConversationMessageItem` 分开，可以避免本地系统提示
/// 意外变成可回复、可转发或可产生已读回执的对象。
enum V2ConversationTimelineItem: Hashable, Identifiable, Sendable {
    struct Activity: Hashable, Sendable {
        enum Kind: Hashable, Sendable { case directMessageRestricted; case systemAccountReadOnly }
        let id: String
        let timelineSequence: UInt64
        let kind: Kind
        let createdAt: Date
    }

    case message(V2ConversationMessageItem, timelineSequence: UInt64)
    case activity(Activity)

    var id: String {
        switch self {
        case .message(let message, _): "message-\(message.id)"
        case .activity(let activity): "activity-\(activity.id)"
        }
    }

    var timelineSequence: UInt64 {
        switch self {
        case .message(_, let sequence): sequence
        case .activity(let activity): activity.timelineSequence
        }
    }

    var cursor: V2ConversationTimelineCursor {
        let kind: V2ClientTimelineItemKind = switch self { case .message: .message; case .activity: .activity }
        return .init(timelineSequence: timelineSequence, itemID: storageItemID, kind: kind)
    }

    var storageItemID: String {
        switch self {
        case .message(let message, _): message.id
        case .activity(let activity): activity.id
        }
    }
}

struct V2ConversationTimelineCursor: Equatable, Sendable {
    let timelineSequence: UInt64
    let itemID: String
    var kind: V2ClientTimelineItemKind = .message
}

enum V2ConversationTimelineLocation: Sendable {
    case found(page: V2ConversationTimelinePage, newerBoundary: V2ConversationTimelineCursor?)
    case withdrawn
    case unavailable
}

struct V2ConversationTimelinePage: Equatable, Sendable {
    let items: [V2ConversationTimelineItem]
    let olderCursor: V2ConversationTimelineCursor?
}

/// 个人收藏页使用的跨会话紧凑条目。
///
/// 标识仅作为导航键使用；私聊名称在可见行中取得限期展示授权。
struct V2FavoriteConversationMessageItem: Hashable, Identifiable, Sendable {
    let id: String
    let roomID: String
    let label: V2ConversationLabel
    let text: String
    let createdAt: Date
}

/// 仅用于展示的表情聚合。
///
/// 单个互动者的标识留在本地投影边界内；消息气泡只暴露数量，
/// 以及当前登录用户是否属于该表情集合。
struct V2ConversationMessageReaction: Hashable, Identifiable, Sendable {
    let reaction: String
    let count: Int
    let includesCurrentUser: Bool

    var id: String { reaction }
}

struct V2ConversationAttachmentItem: Hashable, Identifiable, Sendable {
    enum State: Hashable, Sendable {
        case staged
        case uploading
        case available(V2MediaReference)
        case failed
    }

    let attachment: V2StagedConversationAttachment
    var state: State

    var id: UUID { attachment.id }
    var displayName: String { attachment.displayName }
    var byteCount: Int64 { attachment.byteCount }
}

enum V2ConversationMediaDownloadState: Hashable, Sendable {
    case notDownloaded
    case downloading
    case downloaded(V2DownloadedConversationMedia)
    case failed
}

struct V2ConversationListPage: Equatable, Sendable {
    let items: [V2ConversationListItem]
    let nextCursor: V2ClientConversationListCursor?
}

struct V2ConversationListWindow: Sendable {
    let page: V2ConversationListPage
    let anchorID: String?
    let hasEarlier: Bool
}

protocol V2ConversationWindowReading: Sendable {
    func conversationWindow(for userID: String, isArchived: Bool, around anchor: V2ClientConversationListCursor, limit: Int, precedingCount: Int) async throws -> V2ConversationListWindow
}

/// 进入房间推进已读线所需的本地事实。
///
/// 合同 §5.4 要推进到的是**房间头**，而不是最后一条可见消息的序号：房间头包含编辑、
/// 撤回、reaction、置顶、公告、角色变更这些非消息事件，只按可见消息上报会让未读永久
/// 停在 1。两个字段都是"知道多少说多少"：本地已应用序号缺失时不推进，房间头缺失时
/// 只推进到本地已应用位置，绝不凭空推进。
struct V2ConversationRoomReadCheckpoint: Equatable, Sendable {
    /// 服务端摘要给出的房间头；目录还没覆盖到该房间时为空。
    let knownHead: UInt64?
    /// 本设备已应用到本地的房间序号（含非消息事件）；没有本地证据时为空。
    let appliedRoomSequence: UInt64?

    /// 两件事都不知道：界面不推进已读线。
    static let unknown = Self(knownHead: nil, appliedRoomSequence: nil)
}

protocol V2ConversationDataSource: Sendable {
    func timelineWindow(in roomID: String, for userID: String, around messageID: String, before: Int, after: Int) async throws -> V2ConversationTimelineLocation
    /// 该房间是否已被服务端保留裁剪掉一段历史（缺口永久存在）。
    func roomLogHistoryIsIncomplete(roomID: String) async throws -> Bool
    /// 读取进入房间推进已读线所需的本地事实。
    func roomReadCheckpoint(roomID: String) async throws -> V2ConversationRoomReadCheckpoint
    /// 推进一次有界的未读轮转；未读不是列表渲染的前提，因此不抛错。
    func conversationSummaryPage(
        for userID: String,
        isArchived: Bool,
        before cursor: V2ClientConversationListCursor?,
        limit: Int
    ) async throws -> V2ConversationListPage
    func timelinePage(
        in roomID: String,
        for userID: String,
        before cursor: V2ConversationTimelineCursor?,
        limit: Int
    ) async throws -> V2ConversationTimelinePage
}

extension V2ConversationDataSource {
    /// 不支持未读目录的数据源保持列表可用。
    /// 不支持本地投影的数据源按"历史完整"处理。
    func roomLogHistoryIsIncomplete(roomID _: String) async throws -> Bool { false }
    /// 不支持本地投影的数据源无法回答"已经应用到哪"，因此不推进已读线。
    func roomReadCheckpoint(roomID _: String) async throws -> V2ConversationRoomReadCheckpoint { .unknown }
}

protocol V2ConversationSendingCapabilityReading: Sendable {
    /// 读取私聊房间当前的发送能力。
    ///
    /// 返回 `nil` 表示尚未投影出服务端裁决，此时输入框保持可用，
    /// 真正的发送命令仍是最终闸门。
    ///
    /// - Parameter roomID: 目标房间标识。
    /// - Returns: 允许发送为 `true`，不允许为 `false`，尚未裁决为 `nil`。
    /// - Throws: 数据源读取失败时抛出。
    func directSendingCapability(in roomID: String) async throws -> Bool?
}

protocol V2ConversationFavoritesReading: Sendable {
    func favoriteMessages(
        for userID: String,
        before cursor: V2ClientFavoriteMessageCursor?,
        limit: Int
    ) async throws -> V2ConversationFavoriteMessagesPage
}

struct V2ConversationFavoriteMessagesPage: Equatable, Sendable {
    let items: [V2FavoriteConversationMessageItem]
    let nextCursor: V2ClientFavoriteMessageCursor?
}

protocol V2GroupAnnouncementReading: Sendable {
    func groupAnnouncement(in roomID: String) async throws -> V2ClientGroupAnnouncement?
}

protocol V2GroupRolePolicyAccessing: Sendable {
    func groupRolePolicyState(in roomID: String) async throws -> V2ClientGroupRolePolicyState
    func retryGroupRolePolicyRecovery(in roomID: String) async throws -> V2ClientGroupRolePolicyState
}

/// 消息搜索边界。
///
/// 它与会话数据源把消息投影挡在视图之外的做法一致，
/// 把全文检索与 GRDB 边界挡在 SwiftUI 搜索状态之外。
protocol V2ConversationMessageSearching: Sendable {
    func searchMessages(_ request: V2MessageSearchRequest) async throws -> V2MessageSearchPage
    func searchConversationContext(roomID: RoomID) async throws -> V2ClientConversationLookupContext?
}

extension V2ConversationMessageSearching {
    func searchConversationContext(roomID: RoomID) async throws -> V2ClientConversationLookupContext? { nil }
}

protocol V2ConversationMessageSearchProgressReading: Sendable {
    func messageSearchIndexProgress() async throws -> V2MessageSearchIndexProgress
    func messageSearchIndexUpdates() async -> AsyncThrowingStream<V2MessageSearchIndexSnapshot, any Error>
}

extension V2ConversationMessageSearchProgressReading {
    func messageSearchIndexUpdates() async -> AsyncThrowingStream<V2MessageSearchIndexSnapshot, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// 当前打开的混合大群房间的前台专用边界。
///
/// 它不是成员通知通道：只有正在展示该房间的设备会去轮询，
/// 且每个返回的事件都必须先通过本地持久化游标提交，之后才刷新 SwiftUI。
enum V2ActiveHybridGroupSyncOutcome: Equatable, Sendable {
    case notHybridRoom
    case synchronized(appliedEventCount: Int, hasMore: Bool)
}

enum V2ActiveHybridGroupSubscriptionOutcome: Equatable, Sendable {
    case notHybridRoom
    case subscribed(highWatermark: UInt64)
}

struct V2ActiveHybridGroupWake: Equatable, Sendable {
    let roomID: String
    let highWatermark: UInt64
    let liveEvents: [V2ClientGroupEvent]
    let connectionID: UUID?

    init(
        roomID: String,
        highWatermark: UInt64,
        liveEvents: [V2ClientGroupEvent] = [],
        connectionID: UUID? = nil
    ) {
        self.roomID = roomID
        self.highWatermark = highWatermark
        self.liveEvents = liveEvents
        self.connectionID = connectionID
    }
}

protocol V2ActiveHybridGroupSynchronizing: Sendable {
    var usesRuntimeRecoveryClock: Bool { get }
    func synchronizeOnePage(roomID: String) async throws -> V2ActiveHybridGroupSyncOutcome
    func subscribe(roomID: String) async throws -> V2ActiveHybridGroupSubscriptionOutcome
    /// 应用一批实时事件。
    ///
    /// 只有当整批实时事件都被原子地投影到紧随其后的持久化游标位置上时才返回 `true`；
    /// 返回 `false` 表示需要走常规游标拉取。
    ///
    /// - Parameter wake: 本次实时唤醒信息。
    /// - Returns: 可以按实时载荷推进时为 `true`。
    /// - Throws: 任务取消或同步实现失败时抛出。
    func applyLiveEvent(_ wake: V2ActiveHybridGroupWake) async throws -> Bool
    func nextWake() async throws -> V2ActiveHybridGroupWake
    func unsubscribe(roomID: String) async
}

extension V2ActiveHybridGroupSynchronizing {
    var usesRuntimeRecoveryClock: Bool { false }
}

@MainActor
@Observable
final class V2ConversationListStore {
    static let maximumWindowCount = 300
    let viewport = V2ListViewport()
    enum State: Equatable {
        case loading
        case loaded
        case failed
    }

    private let environment: V2ConversationFeatureEnvironment
    private let dataSource: any V2ConversationDataSource
    private let windowReader: (any V2ConversationWindowReading)?
    private let favoritesReader: (any V2ConversationFavoritesReading)?
    private let messageSearcher: (any V2ConversationMessageSearching)?
    private let userID: String
    private let conversationStateChanger: (any V2ConversationStateChanging)?
    private let directConversationOpener: (any V2DirectConversationOpening)?
    private let publicIdentityResolver: (any V2ConversationPublicIdentityResolving)?
    private let groupConversationCreator: (any V2GroupConversationCreating)?
    private let projectionChangeNotifier: V2ProjectionChangeNotifier?
    private(set) var items: [V2ConversationListItem] = []
    private(set) var favoriteMessages: [V2FavoriteConversationMessageItem] = []
    private(set) var isLoadingFavorites = false
    private(set) var favoritesFeedback: String?
    private(set) var favoritesNextCursor: V2ClientFavoriteMessageCursor?
    private(set) var conversationNextCursor: V2ClientConversationListCursor?
    private var conversationPageOperation: UUID?
    var isLoadingMoreConversations: Bool { conversationPageOperation != nil }
    private var conversationRefreshOperation: UUID?
    private(set) var hasEarlierConversations = false
    /// 当前是否展示归档列表。
    ///
    /// 收件箱与归档是同一份持久化投影上的两个不同视图；
    /// 归档不能仅仅把条目降级到收件箱底部。
    private(set) var isShowingArchived = false
    var visibleItems: [V2ConversationListItem] {
        items.filter { $0.isArchived == isShowingArchived }
    }
    private(set) var state: State = .loading
    private(set) var directConversationFeedback: String?
    private(set) var groupConversationFeedback: String?
    private(set) var conversationStateFeedback: String?
    private(set) var isOpeningDirectConversation = false
    private(set) var isCreatingGroupConversation = false
    private(set) var pendingGroupConversationOperationID: String?
    private var explicitRoomTitles: [String: String] = [:]
    private var explicitRoomKinds: [String: V2ConversationKind] = [:]
    private var explicitDirectPresentationKeys: [String: V2ProfileViewLookupKey] = [:]
    private var refreshGeneration = 0

    init(environment: V2ConversationFeatureEnvironment) {
        self.environment = environment
        dataSource = environment.projections.dataSource
        windowReader = environment.projections.dataSource as? any V2ConversationWindowReading
        favoritesReader = environment.projections.dataSource as? any V2ConversationFavoritesReading
        messageSearcher = environment.projections.messageSearcher
        userID = environment.userID
        conversationStateChanger = environment.messages.stateChanger
        directConversationOpener = environment.discovery.directConversationOpener
        publicIdentityResolver = environment.discovery.publicIdentityResolver
        groupConversationCreator = environment.groups.conversationCreator
        projectionChangeNotifier = environment.runtime.projectionChangeNotifier
    }

    func createGroupConversation(title: String, memberHandlesText: String) async -> String? {
        let handles = memberHandlesText
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            groupConversationFeedback = "请输入群名称。"
            return nil
        }
        guard let canonicalHandles = try? handles.map({ try V2PublicHandle($0).rawValue }) else {
            groupConversationFeedback = "成员公开 ID 格式不正确。"
            return nil
        }
        guard Set(canonicalHandles).count == canonicalHandles.count else {
            groupConversationFeedback = "成员公开 ID 不能重复。"
            return nil
        }
        guard let groupConversationCreator else {
            groupConversationFeedback = "实时网关尚未可用，无法创建群聊。"
            return nil
        }
        guard !isCreatingGroupConversation else { return nil }
        isCreatingGroupConversation = true
        defer { isCreatingGroupConversation = false }
        do {
            let members: [String]
            if handles.isEmpty {
                members = []
            } else if let publicIdentityResolver {
                members = try await resolveGroupMemberHandles(
                    handles,
                    resolver: publicIdentityResolver,
                    maximumConcurrency: 8
                )
            } else {
                groupConversationFeedback = "身份目录暂不可用，无法解析成员公开 ID。"
                return nil
            }
            try Task.checkCancellation()
            let outcome = try await groupConversationCreator.createConversation(title: title, initialMemberUserIDs: members)
            try Task.checkCancellation()
            switch outcome {
            case .created(let roomID):
                pendingGroupConversationOperationID = nil
                explicitRoomTitles[roomID] = title.trimmingCharacters(in: .whitespacesAndNewlines)
                explicitRoomKinds[roomID] = .group
                groupConversationFeedback = nil
                return roomID
            case .queuedForRetry(let operationID):
                pendingGroupConversationOperationID = operationID
                groupConversationFeedback = "建群请求已安全保存；取消可阻止其在恢复连接后继续创建。"
                return nil
            case .rejected(let code):
                pendingGroupConversationOperationID = nil
                groupConversationFeedback = "无法创建群聊（\(code)）。"
                return nil
            }
        } catch is CancellationError {
            return nil
        } catch {
            groupConversationFeedback = "无法保存建群请求。"
            return nil
        }
    }

    private func resolveGroupMemberHandles(
        _ handles: [String],
        resolver: any V2ConversationPublicIdentityResolving,
        maximumConcurrency: Int
    ) async throws -> [String] {
        precondition(maximumConcurrency > 0)
        var resolved = Array<String?>(repeating: nil, count: handles.count)
        return try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var nextIndex = 0
            let initialCount = min(maximumConcurrency, handles.count)
            for index in 0..<initialCount {
                let handle = handles[index]
                group.addTask {
                    let identity = try await resolver.resolve(handle: handle)
                    return (index, identity.userID.rawValue)
                }
                nextIndex += 1
            }
            while let (index, userID) = try await group.next() {
                resolved[index] = userID
                if nextIndex < handles.count {
                    let index = nextIndex
                    let handle = handles[index]
                    group.addTask {
                        let identity = try await resolver.resolve(handle: handle)
                        return (index, identity.userID.rawValue)
                    }
                    nextIndex += 1
                }
            }
            guard resolved.allSatisfy({ $0 != nil }) else { throw CancellationError() }
            return resolved.compactMap { $0 }
        }
    }

    func cancelPendingGroupConversationCreation() async {
        guard let operationID = pendingGroupConversationOperationID else { return }
        guard let groupConversationCreator else {
            groupConversationFeedback = "无法取消已保存的建群请求，请恢复连接后重试。"
            return
        }
        do {
            switch try await groupConversationCreator.cancelConversationCreation(operationID: operationID) {
            case .cancelled:
                pendingGroupConversationOperationID = nil
                groupConversationFeedback = "建群请求已取消。"
            case .queuedForRetry:
                pendingGroupConversationOperationID = nil
                groupConversationFeedback = "建群请求正在取消；恢复连接后会完成取消。"
            case .finalizationAlreadyStarted:
                pendingGroupConversationOperationID = nil
                groupConversationFeedback = "群聊已进入创建阶段，无法取消；完成后会显示在会话列表。"
            }
        } catch {
            groupConversationFeedback = "无法取消建群请求，请稍后重试。"
        }
    }

    func refresh(resetWindow: Bool = false) async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let operation = UUID()
        conversationRefreshOperation = operation
        conversationPageOperation = nil
        defer { if conversationRefreshOperation == operation { conversationRefreshOperation = nil } }
        let retainedCount = resetWindow ? 50 : min(Self.maximumWindowCount, max(50, items.count))
        if resetWindow { items = []; conversationNextCursor = nil; hasEarlierConversations = false; viewport.reset() }
        if items.isEmpty { state = .loading }
        let archived = isShowingArchived
        do {
            while true {
                let capturedAnchorID = viewport.anchorID
                let anchorID = capturedAnchorID ?? (hasEarlierConversations ? items.first?.id : nil)
                if let windowReader, let index = items.firstIndex(where: { $0.id == anchorID }),
                   let anchor = Self.windowCursor(items[index]) {
                    let result = try await windowReader.conversationWindow(for: userID, isArchived: archived, around: anchor,
                        limit: retainedCount, precedingCount: min(50, index, retainedCount - 1))
                    try Task.checkCancellation()
                    guard generation == refreshGeneration, archived == isShowingArchived else { return }
                    guard case let .ready(restorationID) = viewport.resolveRead(capturedAnchorID: capturedAnchorID,
                        returnedIDs: result.page.items.map(\.id), fallback: result.anchorID) else { continue }
                    publishWindow(result, restoreTo: restorationID)
                    state = .loaded
                    await restoreDurableGroupCreationStatusIfNeeded()
                    return
                }
                var refreshed: [V2ConversationListItem] = []
                var seen = Set<String>()
                var cursor: V2ClientConversationListCursor?
                // Each read remains within the existing 100-row storage bound.
                // The captured loaded count bounds this refresh even if new data
                // arrives while the finite page sequence is being read.
                for offset in stride(from: 0, to: retainedCount, by: 100) {
                    let page = try await dataSource.conversationSummaryPage(
                        for: userID, isArchived: archived, before: cursor,
                        limit: min(100, retainedCount - offset)
                    )
                    try Task.checkCancellation()
                    guard generation == refreshGeneration, archived == isShowingArchived else { return }
                    guard page.nextCursor == nil || page.nextCursor != cursor else { throw V2ClientProjectionError.invalidMessagePayload }
                    refreshed.append(contentsOf: page.items.filter { seen.insert($0.id).inserted })
                    cursor = page.nextCursor
                    if cursor == nil { break }
                }
                // Fallback data sources do not implement anchored windows. Their
                // finite head read remains usable, but production can retarget.
                let restorationID: String?
                if case let .ready(target) = viewport.resolveRead(capturedAnchorID: capturedAnchorID,
                    returnedIDs: refreshed.map(\.id), fallback: nil) { restorationID = target }
                else if windowReader != nil { continue }
                else { restorationID = nil }
                items = refreshed
                viewport.reconcile(ids: items.map(\.id))
                viewport.restore(to: restorationID)
                hasEarlierConversations = false
                conversationNextCursor = cursor
                state = .loaded
                await restoreDurableGroupCreationStatusIfNeeded()
                return
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, generation == refreshGeneration else { return }
            state = .failed
        }
    }

    func toggleArchivedConversations() async {
        isShowingArchived.toggle()
        await refresh(resetWindow: true)
    }

    func loadMoreConversations() async {
        guard state == .loaded,
              let cursor = conversationNextCursor,
              conversationRefreshOperation == nil,
              !isLoadingMoreConversations
        else { return }
        let generation = refreshGeneration
        let archived = isShowingArchived
        let operation = UUID()
        conversationPageOperation = operation
        defer { if conversationPageOperation == operation { conversationPageOperation = nil } }
        do {
            let page = try await dataSource.conversationSummaryPage(
                for: userID,
                isArchived: archived,
                before: cursor,
                limit: 50
            )
            try Task.checkCancellation()
            guard generation == refreshGeneration, archived == isShowingArchived else { return }
            var existingIDs = Set(items.map(\.id))
            let anchorID = viewport.anchorID ?? items.last?.id
            let additions = page.items.filter { existingIDs.insert($0.id).inserted }
            let removedCount = max(0, items.count + additions.count - Self.maximumWindowCount)
            // The user may have scrolled back while the page was being read.
            // Keep both the window and its cursor when appending would evict
            // their current row; a later explicit load can retry this page.
            if let anchorID = viewport.anchorID, items.prefix(removedCount).contains(where: { $0.id == anchorID }) { return }
            items.append(contentsOf: additions)
            if removedCount > 0 {
                items.removeFirst(removedCount)
                hasEarlierConversations = true
            }
            viewport.reconcile(ids: items.map(\.id))
            if removedCount > 0 { viewport.restore(to: anchorID ?? items.first?.id) }
            conversationNextCursor = page.nextCursor
        } catch is CancellationError {
            return
        } catch {
            guard generation == refreshGeneration, archived == isShowingArchived else { return }
            conversationStateFeedback = "无法加载更多会话。"
        }
    }

    func loadEarlierConversations() async {
        guard let windowReader, hasEarlierConversations, conversationRefreshOperation == nil,
              conversationPageOperation == nil, let first = items.first, let anchor = Self.windowCursor(first) else { return }
        let operation = UUID(), generation = refreshGeneration
        let archived = isShowingArchived
        let capturedAnchorID = viewport.anchorID
        conversationPageOperation = operation
        defer { if conversationPageOperation == operation { conversationPageOperation = nil } }
        do {
            let result = try await windowReader.conversationWindow(for: userID, isArchived: archived, around: anchor,
                limit: Self.maximumWindowCount, precedingCount: Self.maximumWindowCount - 50)
            try Task.checkCancellation()
            guard generation == refreshGeneration, archived == isShowingArchived else { return }
            guard case let .ready(restorationID) = viewport.resolveRead(capturedAnchorID: capturedAnchorID,
                returnedIDs: result.page.items.map(\.id), fallback: result.page.items.first?.id) else { return }
            publishWindow(result, restoreTo: restorationID)
        } catch is CancellationError { return }
        catch {
            guard generation == refreshGeneration else { return }
            conversationStateFeedback = "无法加载前面的会话。"
        }
    }

    private func publishWindow(_ result: V2ConversationListWindow, restoreTo anchorID: String?) {
        items = result.page.items
        conversationNextCursor = result.page.nextCursor
        hasEarlierConversations = result.hasEarlier
        viewport.reconcile(ids: items.map(\.id))
        viewport.restore(to: anchorID)
    }

    private static func windowCursor(_ item: V2ConversationListItem) -> V2ClientConversationListCursor? {
        guard let roomID = try? RoomID(item.id) else { return nil }
        return .init(isPinned: item.isPinned, lastActivity: item.lastActivity, roomID: roomID)
    }

    func loadFavorites() async {
        guard let favoritesReader, !isLoadingFavorites else {
            if favoritesReader == nil { favoritesFeedback = "收藏暂不可用。" }
            return
        }
        isLoadingFavorites = true
        defer { isLoadingFavorites = false }
        do {
            let page = try await favoritesReader.favoriteMessages(for: userID, before: nil, limit: 50)
            favoriteMessages = page.items
            favoritesNextCursor = page.nextCursor
            favoritesFeedback = nil
        } catch is CancellationError {
            return
        } catch {
            favoritesFeedback = "无法读取收藏消息。"
        }
    }

    func loadMoreFavorites() async {
        guard let favoritesReader, let cursor = favoritesNextCursor, !isLoadingFavorites else { return }
        isLoadingFavorites = true
        defer { isLoadingFavorites = false }
        do {
            let page = try await favoritesReader.favoriteMessages(for: userID, before: cursor, limit: 50)
            try Task.checkCancellation()
            let existing = Set(favoriteMessages.map(\.id))
            favoriteMessages.append(contentsOf: page.items.filter { !existing.contains($0.id) })
            favoritesNextCursor = page.nextCursor
            favoritesFeedback = nil
        } catch is CancellationError {
        } catch {
            favoritesFeedback = "无法继续读取收藏消息。"
        }
    }

    func updateConversationState(_ item: V2ConversationListItem, isPinned: Bool? = nil, isArchived: Bool? = nil, muteUntil: Date?? = nil) async {
        guard let conversationStateChanger else { conversationStateFeedback = "会话设置暂不可用。"; return }
        do {
            let outcome = try await conversationStateChanger.setState(
                roomID: item.id,
                isPinned: isPinned ?? item.isPinned,
                isArchived: isArchived ?? item.isArchived,
                muteUntil: muteUntil ?? item.muteUntil
            )
            try Task.checkCancellation()
            switch outcome {
            case .accepted:
                conversationStateFeedback = "会话设置已提交，正在同步。"
                await refresh()
            case .queuedForRetry:
                conversationStateFeedback = "会话设置已安全保存，连接恢复后会重试。"
            case .rejected(let code):
                conversationStateFeedback = "会话设置被拒绝（\(code)）。"
            }
        } catch is CancellationError { return }
        catch { conversationStateFeedback = "无法保存会话设置。" }
    }

    private func restoreDurableGroupCreationStatusIfNeeded() async {
        guard let groupConversationCreator else { return }
        let generation = refreshGeneration
        do {
            let status = try await groupConversationCreator.restoredCreationStatus()
            try Task.checkCancellation()
            guard generation == refreshGeneration else { return }
            switch status {
            case .queuedForRetry(let operationID):
                pendingGroupConversationOperationID = operationID
                groupConversationFeedback = "建群请求已安全保存；取消可阻止其在恢复连接后继续创建。"
            case .cancelling:
                pendingGroupConversationOperationID = nil
                groupConversationFeedback = "建群请求正在取消；恢复连接后会完成取消。"
            case .finalizing:
                pendingGroupConversationOperationID = nil
                groupConversationFeedback = "群聊已进入创建阶段，无法取消；完成后会显示在会话列表。"
            case .cancelled:
                pendingGroupConversationOperationID = nil
                groupConversationFeedback = "建群请求已取消。"
            case .rejected(let code):
                pendingGroupConversationOperationID = nil
                groupConversationFeedback = "无法创建群聊（\(code)）。"
            case nil:
                break
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, generation == refreshGeneration else { return }
            // Conversation data already loaded successfully. Do not replace it
            // with a misleading bootstrap error just because status recovery
            // was temporarily unavailable.
        }
    }

    func detailStore(
        for roomID: String,
        initialDraft: String? = nil,
        initialMentionHandles: String? = nil
    ) -> V2ConversationDetailStore {
        let item = items.first(where: { $0.id == roomID })
        let title = explicitRoomTitles[roomID] ?? item?.title ?? "会话"
        let kind = explicitRoomKinds[roomID] ?? item?.kind ?? .unknown
        let forwardTargets = items
            .filter { $0.id != roomID }
            .map { V2ConversationForwardTarget(roomID: $0.id, label: .init(item: $0)) }
        return .init(
            environment: environment,
            context: .init(
                roomID: roomID,
                title: title,
                kind: kind,
                forwardTargets: forwardTargets,
                initialDraft: initialDraft,
                initialMentionHandles: initialMentionHandles,
                presentationKey: explicitDirectPresentationKeys[roomID] ?? item?.presentationKey
            )
        )
    }

    func messageSearchStore() -> V2ConversationSearchStore? {
        guard let messageSearcher else { return nil }
        return .init(searcher: messageSearcher, actorUserID: try? .init(userID))
    }

    func observeProjectionChanges() async {
        guard let projectionChangeNotifier else {
            await refresh()
            return
        }
        await V2ProjectionRefreshObserver.run(await projectionChangeNotifier.updates(scopes: .conversations)) { [self] in
            await refresh()
        }
    }

    func openDirectConversation(handle: String) async -> String? {
        let target = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            directConversationFeedback = "请输入对方的公开 ID。"
            return nil
        }
        guard let directConversationOpener else {
            directConversationFeedback = "实时网关尚未可用，无法新建会话。"
            return nil
        }
        guard let publicIdentityResolver else {
            directConversationFeedback = "身份目录暂不可用，无法创建会话。"
            return nil
        }
        guard !isOpeningDirectConversation else { return nil }
        isOpeningDirectConversation = true
        defer { isOpeningDirectConversation = false }
        do {
            let identity = try await publicIdentityResolver.resolve(handle: target)
            try Task.checkCancellation()
            guard identity.userID.rawValue != userID else {
                directConversationFeedback = "不能与自己创建私聊。"
                return nil
            }
            let roomID = try await directConversationOpener.openConversation(with: identity)
            try Task.checkCancellation()
            explicitRoomTitles[roomID] = identity.displayName
            explicitRoomKinds[roomID] = .direct(accountKind: identity.accountKind)
            explicitDirectPresentationKeys[roomID] = .init(userID: identity.userID, context: .directConversation)
            directConversationFeedback = nil
            return roomID
        } catch is CancellationError {
            return nil
        } catch {
            directConversationFeedback = "无法创建会话，请检查公开 ID 和网络连接。"
            return nil
        }
    }
}

struct V2ConversationListView: View {
    private enum NewConversationSheet: String, Identifiable {
        case direct
        case group

        var id: String { rawValue }
    }

    private struct SearchNavigationDestination: Hashable {
        let roomID: String
        let messageID: String
    }

    @Bindable var store: V2ConversationListStore
    let localE2EConversationLaunchFixture: V2LiveLocalAccountE2EConversationLaunchFixture?
    private let accountMenu: V2ConversationAccountMenu?
    private let rootNavigation: V2RootNavigationStore?
    private let groupInvitationStore: V2GroupInvitationStore?
    @State private var navigationPath = NavigationPath()
    @State private var newConversationSheet: NewConversationSheet?
    @State private var directTargetUserID: String
    @State private var localE2EFixtureRoomID: String?
    @State private var groupTitle = ""
    @State private var groupMemberUserIDs = ""
    @State private var directSubmissionTask: Task<Void, Never>?
    @State private var groupSubmissionTask: Task<Void, Never>?
    @State private var groupCancellationTask: Task<Void, Never>?
    @State private var messageSearchStore: V2ConversationSearchStore?
    @State private var isPresentingMessageSearch = false
    @State private var isPresentingFavorites = false

    init(
        store: V2ConversationListStore,
        localE2EConversationLaunchFixture: V2LiveLocalAccountE2EConversationLaunchFixture? = nil,
        accountMenu: V2ConversationAccountMenu? = nil,
        rootNavigation: V2RootNavigationStore? = nil,
        groupInvitationStore: V2GroupInvitationStore? = nil
    ) {
        self.store = store
        self.localE2EConversationLaunchFixture = localE2EConversationLaunchFixture
        self.accountMenu = accountMenu
        self.rootNavigation = rootNavigation
        self.groupInvitationStore = groupInvitationStore
        _directTargetUserID = State(
            initialValue: localE2EConversationLaunchFixture?.directTargetHandle ?? ""
        )
        _groupTitle = State(
            initialValue: localE2EConversationLaunchFixture?.initialGroupTitle ?? ""
        )
        _groupMemberUserIDs = State(
            initialValue: localE2EConversationLaunchFixture?.initialGroupMemberHandles ?? ""
        )
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                switch store.state {
                case .loading:
                    ProgressView("正在加载会话…")
                case .failed:
                    VStack(spacing: 12) {
                        ContentUnavailableView("无法读取本地会话", systemImage: "exclamationmark.triangle")
                        Button("重试") { Task { await store.refresh() } }
                    }
                case .loaded:
                    if store.visibleItems.isEmpty {
                        ContentUnavailableView(
                            store.isShowingArchived ? "没有已归档会话" : "暂无会话",
                            systemImage: store.isShowingArchived ? "archivebox" : "bubble.left.and.bubble.right",
                            description: Text(store.isShowingArchived ? "归档的会话会显示在这里。" : "连接实时网关并完成同步后，消息会显示在这里。")
                        )
                    } else {
                    ScrollViewReader { scrollProxy in
                    List {
                    if store.hasEarlierConversations {
                        Button("查看前面的会话") { Task { await store.loadEarlierConversations() } }
                            .disabled(store.isLoadingMoreConversations)
                            .accessibilityIdentifier("v2.conversation.load-earlier")
                        Button("回到最新会话") { Task { await store.refresh(resetWindow: true) } }
                            .accessibilityIdentifier("v2.conversation.return-to-latest")
                    }
                    ForEach(store.visibleItems) { item in
                        NavigationLink(value: item.id) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    if let key = item.presentationKey { V2AuthorizedAvatarView(key: key, showsName: true) }
                                    else {
                                        if item.kind == .group, let room = try? RoomID(item.id) { V2AuthorizedGroupAvatarView(roomID: room) }
                                        Text(item.kind == .group ? item.title : "会话").font(.headline)
                                    }
                                    if let accountKind = item.kind.directAccountKind,
                                       let accountBadge = accountKind.badgeTitle {
                                        Text(accountBadge)
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.tint)
                                            .accessibilityLabel(accountBadge)
                                            .accessibilityIdentifier("v2.conversation.account-kind.\(accountKind.rawValue)")
                                    }
                                    if item.isPinned { Image(systemName: "pin.fill").foregroundStyle(.secondary).accessibilityHidden(true) }
                                    if item.muteUntil.map({ $0 > Date() }) == true { Image(systemName: "bell.slash.fill").foregroundStyle(.secondary).accessibilityHidden(true) }
                                    Spacer()
                                    // 未读来自服务端摘要；静音只影响提醒，不影响这里的计数。
                                    if let unreadCount = item.unreadCount, unreadCount > 0 {
                                        Text(unreadCount > 99 ? "99+" : "\(unreadCount)")
                                            .font(.caption2.weight(.semibold))
                                            .monospacedDigit()
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill(.red))
                                            .accessibilityLabel("\(unreadCount) 条未读")
                                            .accessibilityIdentifier("v2.conversation.unread.\(item.id)")
                                    }
                                    Text(item.lastActivity, format: .dateTime.hour().minute())
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text((item.isOutgoing ? "我：" : "") + item.preview)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .contextMenu {
                            Button(item.isPinned ? "取消置顶会话" : "置顶会话", systemImage: item.isPinned ? "pin.slash" : "pin") {
                                Task { await store.updateConversationState(item, isPinned: !item.isPinned) }
                            }
                            Button(item.isArchived ? "取消归档" : "归档会话", systemImage: item.isArchived ? "tray.and.arrow.up" : "archivebox") {
                                Task { await store.updateConversationState(item, isArchived: !item.isArchived) }
                            }
                            Button(item.muteUntil.map({ $0 > Date() }) == true ? "取消免打扰" : "免打扰 1 小时", systemImage: item.muteUntil.map({ $0 > Date() }) == true ? "bell" : "bell.slash") {
                                Task {
                                    if item.muteUntil.map({ $0 > Date() }) == true {
                                        await store.updateConversationState(item, muteUntil: .some(nil))
                                    } else {
                                        await store.updateConversationState(item, muteUntil: .some(Date().addingTimeInterval(60 * 60)))
                                    }
                                }
                            }
                        }
                        .accessibilityIdentifier("v2.conversation.\(item.kind.accessibilityIdentifierComponent).\(item.id)")
                        .id(item.id)
                        .modifier(V2ListViewportRow(viewport: store.viewport, itemID: item.id, coordinateSpace: "v2.conversation.viewport"))
                    }
                    if store.conversationNextCursor != nil {
                        HStack {
                            Spacer()
                            if store.isLoadingMoreConversations {
                                ProgressView().accessibilityLabel("正在加载更多会话")
                            } else {
                                Button("加载更多会话") {
                                    Task { await store.loadMoreConversations() }
                                }
                                .accessibilityIdentifier("v2.conversation.load-more")
                            }
                            Spacer()
                        }
                    }
                    }
                    .accessibilityIdentifier("v2.conversation.list")
                    .coordinateSpace(name: "v2.conversation.viewport")
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { store.viewport.resize(height: $0) }
                    .onScrollPhaseChange { _, phase in
                        if phase == .tracking || phase == .interacting { store.viewport.userDidBeginScrolling() }
                    }
                    .task(id: store.viewport.restoration?.id) {
                        guard let request = store.viewport.restoration else { return }
                        await store.viewport.performRestoration(request) { scrollProxy.scrollTo($0, anchor: .top) }
                    }
                    }
                    }
                }
            }
            .navigationTitle(store.isShowingArchived ? "已归档" : "消息")
            .safeAreaInset(edge: .bottom) {
                if let feedback = store.conversationStateFeedback {
                    Text(feedback).font(.footnote).foregroundStyle(.secondary).padding(.horizontal).padding(.vertical, 6).accessibilityIdentifier("v2.conversation.state-feedback")
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Button(store.isShowingArchived ? "返回收件箱" : "已归档", systemImage: store.isShowingArchived ? "tray" : "archivebox") {
                            Task { await store.toggleArchivedConversations() }
                        }
                        .accessibilityIdentifier("v2.conversation.archive-toggle")
                        Button("搜索消息", systemImage: "magnifyingglass") {
                            guard let searchStore = store.messageSearchStore() else { return }
                            messageSearchStore = searchStore
                            isPresentingMessageSearch = true
                        }
                        .accessibilityIdentifier("v2.message.search")
                        Button("收藏", systemImage: "star") {
                            isPresentingFavorites = true
                        }
                        .accessibilityIdentifier("v2.message.favorites")
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("会话工具")
                    .accessibilityHint("打开归档、搜索和收藏")
                    .accessibilityIdentifier("v2.conversation.tools")
                    Button("新建群聊", systemImage: "person.3") {
                        newConversationSheet = .group
                    }
                    .accessibilityIdentifier("v2.conversation.new-group")
                    if let groupInvitationStore {
                        Button("加入群聊", systemImage: "qrcode.viewfinder") {
                            groupInvitationStore.isPresentingJoin = true
                        }
                        .accessibilityIdentifier("v2.group-join.open")
                    }
                    Button("新建私聊", systemImage: "square.and.pencil") {
                        newConversationSheet = .direct
                    }
                    .accessibilityIdentifier("v2.conversation.new-direct")
                    Button("刷新", systemImage: "arrow.clockwise") {
                        Task { await store.refresh() }
                    }
                    .accessibilityIdentifier("v2.conversation.refresh")
                    if let accountMenu {
                        accountMenu
                    }
                }
            }
            .navigationDestination(for: String.self) { roomID in
                V2ConversationDetailView(
                    store: store.detailStore(
                        for: roomID,
                        initialDraft: localE2EFixtureRoomID == roomID
                            ? localE2EConversationLaunchFixture?.initialMessage
                            : nil,
                        initialMentionHandles: localE2EFixtureRoomID == roomID
                            ? localE2EConversationLaunchFixture?.initialMentionHandles
                            : nil
                    ),
                    groupInvitationStore: groupInvitationStore
                )
            }
            .navigationDestination(for: SearchNavigationDestination.self) { destination in
                V2ConversationDetailView(
                    store: store.detailStore(for: destination.roomID),
                    initiallyFocusedMessageID: destination.messageID,
                    groupInvitationStore: groupInvitationStore
                )
            }
            .sheet(isPresented: $isPresentingFavorites) {
                V2FavoriteMessagesSheet(store: store) { item in
                    isPresentingFavorites = false
                    navigationPath.append(SearchNavigationDestination(roomID: item.roomID, messageID: item.id))
                }
            }
            .task { await store.observeProjectionChanges() }
            .onAppear { consumeRequestedConversationIfNeeded() }
            .onChange(of: rootNavigation?.conversationRequest) { _, _ in
                consumeRequestedConversationIfNeeded()
            }
            .sheet(isPresented: $isPresentingMessageSearch, onDismiss: {
                messageSearchStore = nil
            }) {
                if let messageSearchStore {
                    NavigationStack {
                        V2MessageSearchView(store: messageSearchStore) { hit in
                            isPresentingMessageSearch = false
                            navigationPath.append(SearchNavigationDestination(roomID: hit.roomID.rawValue, messageID: hit.messageID.rawValue))
                        }
                    }
                }
            }
            .sheet(item: $newConversationSheet) { sheet in
                switch sheet {
                case .direct:
                NavigationStack {
                    Form {
                        Section("对方公开 ID") {
                            TextField("@handle", text: $directTargetUserID)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .disabled(store.isOpeningDirectConversation)
                                .accessibilityIdentifier("v2.conversation.direct-target")
                        }
                        if let feedback = store.directConversationFeedback {
                            Text(feedback)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .navigationTitle("新建私聊")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { newConversationSheet = nil }
                                .accessibilityIdentifier("v2.conversation.direct-cancel")
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("开始") {
                                guard directSubmissionTask == nil else { return }
                                let target = directTargetUserID
                                directSubmissionTask = Task {
                                    if let roomID = await store.openDirectConversation(handle: target), !Task.isCancelled {
                                        directSubmissionTask = nil
                                        directTargetUserID = ""
                                        localE2EFixtureRoomID = roomID
                                        newConversationSheet = nil
                                        navigationPath.append(roomID)
                                    } else if !Task.isCancelled {
                                        directSubmissionTask = nil
                                    }
                                }
                            }
                            .disabled(
                                directTargetUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    || store.isOpeningDirectConversation
                            )
                            .accessibilityIdentifier("v2.conversation.direct-submit")
                        }
                    }
                    .onDisappear {
                        directSubmissionTask?.cancel()
                        directSubmissionTask = nil
                    }
                }
                case .group:
                NavigationStack {
                    Form {
                        Section("群名称") {
                            TextField("群名称", text: $groupTitle)
                                .disabled(store.isCreatingGroupConversation)
                                .accessibilityIdentifier("v2.conversation.group-title")
                        }
                        Section("初始成员") {
                            TextEditor(text: $groupMemberUserIDs)
                                .frame(minHeight: 110)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .disabled(store.isCreatingGroupConversation)
                                .accessibilityLabel("初始成员公开 ID")
                                .accessibilityHint("输入 @handle，用逗号或换行分隔；可留空创建仅自己的群聊")
                                .accessibilityIdentifier("v2.conversation.group-members")
                            Text("用逗号或换行分隔公开 ID，例如 @alice。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        if let feedback = store.groupConversationFeedback {
                            Text(feedback)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("v2.conversation.group-feedback")
                        }
                    }
                    .navigationTitle("新建群聊")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") {
                                groupSubmissionTask?.cancel()
                                groupSubmissionTask = nil
                                guard store.pendingGroupConversationOperationID != nil else {
                                    newConversationSheet = nil
                                    return
                                }
                                guard groupCancellationTask == nil else { return }
                                groupCancellationTask = Task {
                                    await store.cancelPendingGroupConversationCreation()
                                    guard !Task.isCancelled else { return }
                                    groupCancellationTask = nil
                                    newConversationSheet = nil
                                }
                            }
                                .accessibilityIdentifier("v2.conversation.group-cancel")
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("创建") {
                                guard groupSubmissionTask == nil else { return }
                                let title = groupTitle
                                let members = groupMemberUserIDs
                                groupSubmissionTask = Task {
                                    if let roomID = await store.createGroupConversation(title: title, memberHandlesText: members), !Task.isCancelled {
                                        groupSubmissionTask = nil
                                        groupTitle = ""
                                        groupMemberUserIDs = ""
                                        // The local E2E fixture only supplies a draft to the
                                        // room created by this real UI action. Keep the same
                                        // state handoff as the direct-conversation path.
                                        localE2EFixtureRoomID = roomID
                                        newConversationSheet = nil
                                        navigationPath.append(roomID)
                                    } else if !Task.isCancelled {
                                        groupSubmissionTask = nil
                                    }
                                }
                            }
                            .disabled(
                                groupTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    || store.isCreatingGroupConversation
                            )
                            .accessibilityIdentifier("v2.conversation.group-submit")
                        }
                    }
                    .onDisappear {
                        groupSubmissionTask?.cancel()
                        groupSubmissionTask = nil
                        groupCancellationTask?.cancel()
                        groupCancellationTask = nil
                    }
                }
                }
            }
            .sheet(isPresented: Binding(
                get: { groupInvitationStore?.isPresentingJoin == true },
                set: { if !$0 { groupInvitationStore?.dismissJoin() } }
            )) {
                if let groupInvitationStore { V2GroupJoinSheet(store: groupInvitationStore) }
            }
        }
    }

    private func consumeRequestedConversationIfNeeded() {
        guard let request = rootNavigation?.conversationRequest else { return }
        rootNavigation?.consumeConversationRequest(id: request.id)
        navigationPath.append(request.roomID)
    }
}

private extension V2AccountKind {
    var badgeTitle: String? {
        switch self {
        case .regular: nil
        case .system: "系统"
        case .customerSupport: "客服"
        }
    }
}

struct V2ConversationAccountMenu: View {
    let canOpenPublicIdentity: Bool
    let canOpenDeviceSessions: Bool
    let canOpenPendingGroupAvatars: Bool
    let openPublicIdentity: @MainActor () -> Void
    let openDeviceSessions: @MainActor () -> Void
    let openPendingGroupAvatars: @MainActor () -> Void
    let openPrivacySettings: @MainActor () -> Void
    let openAccountSecurity: @MainActor () -> Void
    let signOut: @MainActor () -> Void

    var body: some View {
        Menu {
            if canOpenPublicIdentity {
                Button("我的资料", action: openPublicIdentity)
                    .accessibilityIdentifier("v2.identity.open")
            }
            if canOpenDeviceSessions {
                Button("登录设备", action: openDeviceSessions)
                    .accessibilityIdentifier("v2.device-sessions.open")
            }
            if canOpenPendingGroupAvatars {
                Button("待处理群头像", action: openPendingGroupAvatars)
                    .accessibilityIdentifier("v2.group.avatar.pending.open")
            }
            Button("消息接收设置", action: openPrivacySettings)
                .accessibilityIdentifier("v2.privacy.open")
            Button("账号安全", action: openAccountSecurity)
                .accessibilityIdentifier("v2.security.open")
            Button("退出登录", role: .destructive, action: signOut)
                .accessibilityIdentifier("v2.sign-out")
        } label: {
            Image(systemName: "person.crop.circle")
                .font(.title2)
        }
        .accessibilityLabel("账户和设置")
        .accessibilityHint("打开资料、消息接收设置和退出登录菜单")
        .accessibilityIdentifier("v2.account-menu")
    }
}

private struct V2MessageSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: V2ConversationSearchStore
    let onSelect: (V2MessageSearchHit) -> Void
    @State private var profilePageID = UUID()

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                TextField("搜索消息", text: $store.query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("搜索消息")
                    .accessibilityHint("支持单个字符和连续文本搜索；选择媒体类别后可不输入文本")
                    .accessibilityIdentifier("v2.message.search.query")
                Picker("内容类型", selection: $store.contentFilter) {
                    Text("全部文字").tag(V2MessageSearchContentFilter.all)
                    Text("所有媒体").tag(V2MessageSearchContentFilter.media)
                    Text("图片").tag(V2MessageSearchContentFilter.image)
                    Text("视频").tag(V2MessageSearchContentFilter.video)
                    Text("文件").tag(V2MessageSearchContentFilter.file)
                    Text("音频").tag(V2MessageSearchContentFilter.audio)
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("v2.message.search.content-filter")
                if store.senderFilter != nil {
                    HStack {
                        Text("已按成员筛选")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let key = store.senderPresentationKey { V2AuthorizedProfileNameView(key: key, placeholder: "选定成员").font(.footnote) }
                        else { Text("选定成员").font(.footnote) }
                        Spacer()
                        Button("清除") { store.clearSenderFilter() }
                            .accessibilityLabel("清除成员筛选")
                            .accessibilityIdentifier("v2.message.search.clear-sender-filter")
                    }
                    .accessibilityElement(children: .contain)
                }
            }
            .padding()
            switch store.state {
            case .idle:
                ContentUnavailableView(
                    "搜索本地消息",
                    systemImage: "magnifyingglass",
                    description: Text("输入文本，或选择媒体类别浏览对应消息。")
                )
            case .indexing:
                ContentUnavailableView(
                    "正在建立搜索索引",
                    systemImage: "magnifyingglass.circle",
                    description: Text("完成后即可搜索历史消息。")
                )
            case .loading:
                Spacer()
                ProgressView("正在搜索…")
                Spacer()
            case .failed:
                ContentUnavailableView(
                    "无法搜索本地消息",
                    systemImage: "exclamationmark.triangle",
                    description: Text("请稍后重试。")
                )
            case .loaded:
                List {
                    if store.isCatchingUp {
                        Label("搜索索引正在追赶最新消息，最新内容可能暂未显示。", systemImage: "clock.arrow.circlepath")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("v2.message.search.catching-up")
                    }
                    if store.hits.isEmpty {
                        ContentUnavailableView("没有匹配消息", systemImage: "text.magnifyingglass")
                    } else {
                        ForEach(store.hits) { hit in
                            Button {
                                onSelect(hit)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(hit.text)
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                    Text(hit.createdAt, format: .dateTime.year().month().day().hour().minute())
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityLabel(hit.text)
                            .accessibilityHint("打开这条消息所在的会话")
                            .accessibilityIdentifier("v2.message.search.result.\(hit.messageID.rawValue)")
                            .contextMenu {
                                if store.senderFilter != hit.senderUserID {
                                    Button("只看此成员的消息", systemImage: "person.fill") {
                                        store.filterToSender(hit.senderUserID, in: hit.roomID)
                                    }
                                    .accessibilityIdentifier("v2.message.search.filter-sender.\(hit.senderUserID.rawValue)")
                                }
                            }
                        }
                        if store.canLoadMore {
                            Button("继续加载") { Task { await store.loadMore() } }
                                .disabled(store.isLoadingMore)
                                .accessibilityIdentifier("v2.message.search.load-more")
                        }
                    }
                }
                .accessibilityIdentifier("v2.message.search.results")
            }
        }
        .navigationTitle("搜索消息")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") { dismiss() }
            }
        }
        .task { await store.observeIndexState() }
        .task(id: store.senderContextGeneration) { await store.refreshSenderPresentationContext() }
        .task(id: [store.query, store.contentFilter.rawValue, store.senderFilter?.rawValue ?? ""].joined(separator: "|")) {
            await store.search()
        }
        .authorPresentationPage(context: .list(profilePageID))
    }
}

private struct V2FavoriteMessagesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: V2ConversationListStore
    let select: (V2FavoriteConversationMessageItem) -> Void
    @State private var profilePageID = UUID()

    var body: some View {
        NavigationStack {
            Group {
                if store.isLoadingFavorites {
                    ProgressView("正在读取收藏…")
                } else if let feedback = store.favoritesFeedback {
                    ContentUnavailableView("无法读取收藏", systemImage: "exclamationmark.triangle", description: Text(feedback))
                } else if store.favoriteMessages.isEmpty {
                    ContentUnavailableView("暂无收藏", systemImage: "star", description: Text("长按消息后选择“收藏”，会显示在这里。"))
                } else {
                    List {
                        ForEach(store.favoriteMessages) { item in
                            Button {
                                select(item)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    V2ConversationLabelView(label: item.label)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(item.text)
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                    Text(item.createdAt, format: .dateTime.year().month().day().hour().minute())
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityHint("打开这条收藏消息所在的会话")
                            .accessibilityIdentifier("v2.message.favorite.item.\(item.id)")
                        }
                        if store.favoritesNextCursor != nil {
                            Button {
                                Task { await store.loadMoreFavorites() }
                            } label: {
                                if store.isLoadingFavorites { ProgressView() } else { Text("加载更多收藏") }
                            }
                            .disabled(store.isLoadingFavorites)
                            .accessibilityIdentifier("v2.message.favorites.load-more")
                        }
                    }
                    .accessibilityIdentifier("v2.message.favorites.list")
                }
            }
            .navigationTitle("收藏消息")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("刷新", systemImage: "arrow.clockwise") { Task { await store.loadFavorites() } }
                        .accessibilityIdentifier("v2.message.favorites.refresh")
                }
            }
            .task { await store.loadFavorites() }
        }
        .authorPresentationPage(context: .list(profilePageID))
    }
}

struct V2ConversationDetailView: View {
    private enum PresentedDetailSheet: Identifiable {
        case groupMembers
        case groupAvatar
        case groupReadReceipts(V2ConversationMessageItem)
        case edit(V2ConversationMessageItem)
        case forward
        case copyAttachments(V2ConversationMessageItem)
        case groupAnnouncement
        case groupPermissions
        case groupInvitations

        var id: String {
            switch self {
            case .groupMembers:
                "groupMembers"
            case .groupAvatar:
                "groupAvatar"
            case .groupReadReceipts(let message):
                "groupReadReceipts-\(message.id)"
            case .edit(let message):
                "edit-\(message.id)"
            case .forward:
                "forward"
            case .copyAttachments(let message):
                "copyAttachments-\(message.id)"
            case .groupAnnouncement:
                "groupAnnouncement"
            case .groupPermissions:
                "groupPermissions"
            case .groupInvitations:
                "groupInvitations"
            }
        }
    }

    @State private var store: V2ConversationDetailStore
    @State private var presentedDetailSheet: PresentedDetailSheet?
    @State private var isPresentingAttachmentImporter = false
    @State private var messageSearchStore: V2ConversationSearchStore?
    @State private var isPresentingMessageSearch = false
    @State private var focusedMessageID: String?
    private let groupInvitationStore: V2GroupInvitationStore?

    init(store: V2ConversationDetailStore, initiallyFocusedMessageID: String? = nil, groupInvitationStore: V2GroupInvitationStore? = nil) {
        _store = State(initialValue: store)
        _focusedMessageID = State(initialValue: initiallyFocusedMessageID)
        self.groupInvitationStore = groupInvitationStore
    }

    var body: some View {
        @Bindable var store = store
        Group {
            switch store.state {
            case .loading:
                ProgressView("正在加载消息…")
            case .failed:
                VStack(spacing: 12) {
                    ContentUnavailableView("无法读取本地消息", systemImage: "exclamationmark.triangle")
                    Button("重试") { Task { await store.refresh() } }
                }
            case .loaded:
                VStack(spacing: 0) {
                    if store.isGroupConversation, let announcement = store.groupAnnouncement {
                        V2GroupAnnouncementBanner(announcement: announcement) {
                            presentedDetailSheet = .groupAnnouncement
                        }
                    }
                    if store.timeline.isEmpty {
                        ContentUnavailableView("暂无消息", systemImage: "bubble")
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 10) {
                                    // 服务端按保留窗口裁剪过这个房间：缺口是永久的，
                                    // 必须显式告知，不能让用户以为往上滚就能看到全部历史。
                                    if store.isHistoryIncomplete {
                                        Label("更早的消息已不可用", systemImage: "clock.badge.exclamationmark")
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 4)
                                            .accessibilityLabel("更早的消息已不可用")
                                            .accessibilityIdentifier("v2.message.history-incomplete")
                                    }
                                    if store.canLoadOlderTimeline {
                                        Button {
                                            Task { await store.loadOlderTimeline() }
                                        } label: {
                                            if store.isLoadingOlderTimeline {
                                                ProgressView("正在加载更早消息…")
                                            } else {
                                                Label("加载更早消息", systemImage: "clock.arrow.circlepath")
                                            }
                                        }
                                        .disabled(store.isLoadingOlderTimeline || store.isReturningToLatestTimeline)
                                        .frame(maxWidth: .infinity)
                                        .accessibilityIdentifier("v2.message.load-older")
                                    }
                                    ForEach(store.timeline) { item in
                                        switch item {
                                        case .message(let message, _):
                                            V2ConversationMessageRow(
                                                store: store,
                                                message: message,
                                                beginEditing: { presentedDetailSheet = .edit(message) },
                                                showReadReceipts: { presentedDetailSheet = .groupReadReceipts(message) },
                                                beginForward: {
                                                    store.beginForwardSelection(with: message)
                                                    presentedDetailSheet = .forward
                                                },
                                                beginCopyAttachments: { presentedDetailSheet = .copyAttachments(message) }
                                            )
                                            .id(item.id)
                                        case .activity(let activity):
                                            V2ConversationTimelineActivityRow(activity: activity)
                                                .id(item.id)
                                        }
                                    }
                                    if store.isBrowsingHistoricalTimeline {
                                        Button {
                                            Task { await store.returnToLatestTimeline() }
                                        } label: {
                                            if store.isReturningToLatestTimeline {
                                                ProgressView("正在返回最新消息…")
                                            } else {
                                                Label("返回最新消息", systemImage: "arrow.down.to.line")
                                            }
                                        }
                                        .disabled(store.isLoadingOlderTimeline || store.isReturningToLatestTimeline)
                                        .frame(maxWidth: .infinity)
                                        .accessibilityHint("重新加载当前会话的最新消息")
                                        .accessibilityIdentifier("v2.message.return-latest")
                                    }
                                }
                                .padding()
                            }
                            .onAppear { scrollToFocusedMessage(with: proxy) }
                            .onChange(of: focusedMessageID) { _, _ in
                                scrollToFocusedMessage(with: proxy)
                            }
                            .onChange(of: store.timelineRevision) { _, _ in
                                scrollToFocusedMessage(with: proxy)
                            }
                        }
                        .accessibilityIdentifier("v2.message.list")
                    }
                    Divider()
                    if !store.attachments.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(store.attachments) { attachment in
                                V2ConversationAttachmentRow(store: store, attachment: attachment)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .accessibilityIdentifier("v2.message.attachments")
                    }
                    if store.isGroupConversation {
                        V2ComposerTextInput(
                            text: $store.mentionHandlesText,
                            placeholder: "提及（@all 或 @handle）",
                            accessibilityLabel: "提及成员",
                            accessibilityHint: "输入 @all 或成员公开 ID，用逗号或换行分隔；最多 20 个"
                        )
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .disabled(store.isSending || store.canSendInDirectConversation == false)
                            .accessibilityIdentifier("v2.message.mentions")
                            .padding(.horizontal)
                            .padding(.top, 8)
                    }
                    if let replyTarget = store.replyTarget {
                        HStack(spacing: 8) {
                            Image(systemName: "arrowshape.turn.up.left.fill")
                            Text("回复：\(replyTarget.text.isEmpty ? "附件" : replyTarget.text)")
                                .lineLimit(1)
                            Spacer()
                            Button("取消") { store.cancelReply() }
                                .accessibilityIdentifier("v2.message.reply.cancel")
                        }
                        .font(.subheadline)
                        .padding(.horizontal)
                        .padding(.top, 8)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("v2.message.reply.composer")
                    }
                    if store.isGroupConversation, !store.typingUserIDs.isEmpty {
                        Text(store.typingUserIDs.count == 1 ? "有人正在输入…" : "多位成员正在输入…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                            .padding(.top, 6)
                            .accessibilityLabel("会话状态")
                            .accessibilityValue("有人正在输入")
                            .accessibilityIdentifier("v2.conversation.typing")
                    } else if !store.isGroupConversation, !store.typingUserIDs.isEmpty {
                        Text("对方正在输入…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                            .padding(.top, 6)
                            .accessibilityLabel("对方状态")
                            .accessibilityValue("正在输入")
                            .accessibilityIdentifier("v2.conversation.typing")
                    } else if !store.isGroupConversation, let presence = store.peerPresence {
                        Text(presence.isOnline ? "在线" : "离线")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                            .padding(.top, 6)
                            .accessibilityLabel("对方状态")
                            .accessibilityValue(presence.isOnline ? "在线" : "离线")
                            .accessibilityIdentifier("v2.conversation.presence")
                    }
                    HStack(alignment: .bottom) {
                        Button("添加附件", systemImage: "paperclip") {
                            isPresentingAttachmentImporter = true
                        }
                        .disabled(!store.canAddAttachment || store.directAccountKind == .system)
                        .tint(.primary)
                        .accessibilityHint("从文件中选择要发送的附件")
                        .accessibilityIdentifier("v2.message.attachment.add")
                        V2ComposerTextInput(
                            text: $store.draft,
                            placeholder: "消息",
                            accessibilityLabel: "消息内容",
                            accessibilityHint: "输入要发送的消息"
                        )
                            .disabled(store.isSending || store.canSendInDirectConversation == false || store.directAccountKind == .system)
                            .onChange(of: store.draft) { _, _ in store.updateTypingForDraft() }
                            .accessibilityIdentifier("v2.message.draft")
                        if store.isSending {
                            ProgressView()
                                .frame(minWidth: 44, minHeight: 44)
                                .accessibilityLabel("正在保存消息")
                        } else if canSendDraft {
                            Button("发送") { Task { await store.sendDraft() } }
                                .tint(.primary)
                                .accessibilityIdentifier("v2.message.send")
                        }
                    }
                    .padding()
                    if !store.isGroupConversation, store.canSendInDirectConversation == false || store.directAccountKind == .system {
                        Text(store.directAccountKind == .system ? "此系统账号仅用于发送通知" : "当前无法向此会话发送消息")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                            .padding(.bottom, 8)
                            .accessibilityIdentifier("v2.message.sending-restricted")
                    }
                    ForEach(store.pendingResourceSends) { pending in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(pending.status).font(.caption)
                                if pending.total > 0 {
                                    ProgressView(value: Double(pending.completed), total: Double(pending.total))
                                        .accessibilityLabel("附件已准备 \(pending.completed)/\(pending.total)")
                                }
                            }
                            if pending.canRetry { Button("重试") { Task { await store.retryResourceSend(pending.id) } } }
                            if pending.canCancel { Button("取消") { Task { await store.cancelResourceSend(pending.id) } } }
                        }.padding(.horizontal)
                    }
                    if let sendFeedback = store.sendFeedback {
                        Text(sendFeedback)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                            .padding(.bottom, 8)
                            .onAppear { announceV2AccessibilityAnnouncement(sendFeedback) }
                            .onChange(of: sendFeedback) { _, updatedFeedback in
                                announceV2AccessibilityAnnouncement(updatedFeedback)
                            }
                            .accessibilityIdentifier("v2.message.send-feedback")
                    }
                    if let messageActionFeedback = store.messageActionFeedback {
                        Text(messageActionFeedback)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                            .padding(.bottom, 8)
                            .onAppear { announceV2AccessibilityAnnouncement(messageActionFeedback) }
                            .onChange(of: messageActionFeedback) { _, updatedFeedback in
                                announceV2AccessibilityAnnouncement(updatedFeedback)
                            }
                            .accessibilityIdentifier("v2.message.action-feedback")
                    }
                }
            }
        }
        .navigationTitle(store.isGroupConversation ? store.title : "会话")
        .toolbar {
            if let key = store.presentationKey {
                ToolbarItem(placement: .principal) { V2AuthorizedAvatarView(key: key, showsName: true, size: 24) }
            } else if store.isGroupConversation, let room = try? RoomID(store.roomID) {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        V2AuthorizedGroupAvatarView(roomID: room, size: 24)
                        Text(store.title).font(.headline).lineLimit(1)
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { conversationToolbar }
        .sheet(item: $presentedDetailSheet) { sheet in
            switch sheet {
            case .groupMembers:
                V2GroupMembersSheet(store: store)
            case .groupAvatar:
                if let manager = store.groupAvatarManagementStore() { V2GroupAvatarManagementView(store: manager) }
            case .groupReadReceipts(let message):
                V2GroupReadReceiptsSheet(store: store, message: message)
            case .edit(let message):
                V2MessageEditSheet(store: store, message: message)
            case .forward:
                V2ForwardMessagesSheet(store: store)
            case .copyAttachments(let message):
                V2CopyAttachmentsSheet(store: store, message: message)
            case .groupAnnouncement:
                V2GroupAnnouncementSheet(store: store)
            case .groupPermissions:
                V2GroupPermissionsSheet(store: store)
            case .groupInvitations:
                if let groupInvitationStore { V2GroupInvitationManagementSheet(store: groupInvitationStore, roomID: store.roomID) }
            }
        }
        .sheet(isPresented: $isPresentingMessageSearch, onDismiss: {
            messageSearchStore = nil
        }) {
            if let messageSearchStore {
                NavigationStack {
                    V2MessageSearchView(store: messageSearchStore) { hit in
                        focusedMessageID = hit.messageID.rawValue
                        isPresentingMessageSearch = false
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $isPresentingAttachmentImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await store.stageAttachment(from: url) }
        }
        .task { await store.observeProjectionChanges() }
        .task { await store.pollVisibleHybridGroupEvents() }
        .authorPresentationPage(context: store.authorPresentationContext)
        .task { await store.observeResourceSends() }
        .task { await store.observeLiveActivity() }
        .task(id: focusedMessageID) {
            guard let focusedMessageID else { return }
            await store.loadTimeline(containing: focusedMessageID)
        }
    }

    private var canSendDraft: Bool {
        !store.isSending
            && store.directAccountKind != .system
            && store.canSendInDirectConversation != false
            && (!store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.attachments.isEmpty)
    }

    @ToolbarContentBuilder
    private var conversationToolbar: some ToolbarContent {
        if store.isSelectingMessagesForForward {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { store.endForwardSelection() }
                    .accessibilityIdentifier("v2.message.forward.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("转发 \(store.selectedForwardMessageIDs.count)") {
                    presentedDetailSheet = .forward
                }
                .disabled(store.selectedForwardMessageIDs.isEmpty)
                .accessibilityHint("选择目标会话后发送已勾选的消息")
                .accessibilityIdentifier("v2.message.forward.selected")
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Button("多选转发", systemImage: "arrowshape.turn.up.right") {
                    store.beginForwardSelection()
                }
                .disabled(store.messages.allSatisfy(\.isWithdrawn))
                .accessibilityHint("选择多条消息并转发到一个或多个会话")
                .accessibilityIdentifier("v2.message.forward.begin")
            }
        }
        if store.messageSearchStore() != nil {
            ToolbarItem(placement: .topBarTrailing) {
                Button("搜索本会话", systemImage: "magnifyingglass") {
                    messageSearchStore = store.messageSearchStore()
                    isPresentingMessageSearch = messageSearchStore != nil
                }
                .accessibilityHint("只搜索当前会话中的消息")
                .accessibilityIdentifier("v2.message.search.current-room")
            }
        }
        if store.isGroupConversation {
            if store.hasGroupAvatarManagement {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("群头像", systemImage: "person.crop.circle") { presentedDetailSheet = .groupAvatar }
                        .accessibilityIdentifier("v2.group.avatar.manage")
                }
            }
            if groupInvitationStore != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("邀请", systemImage: "person.badge.plus") { presentedDetailSheet = .groupInvitations }
                        .accessibilityHint("创建邀请链接、显示二维码并审批入群申请")
                        .accessibilityIdentifier("v2.group.invitations")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("成员", systemImage: "person.3") {
                    presentedDetailSheet = .groupMembers
                }
                .accessibilityHint("查看和管理群成员")
                .accessibilityIdentifier("v2.group.members")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("群公告", systemImage: "megaphone") {
                    presentedDetailSheet = .groupAnnouncement
                }
                .accessibilityHint("查看或编辑群公告；编辑权限由服务端验证")
                .accessibilityIdentifier("v2.group.announcement")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("权限", systemImage: "lock.shield") {
                    presentedDetailSheet = .groupPermissions
                }
                .accessibilityHint("查看或编辑群角色权限；编辑权限由服务端验证")
                .accessibilityIdentifier("v2.group.permissions")
            }
        }
    }

    private func scrollToFocusedMessage(with proxy: ScrollViewProxy) {
        guard let focusedMessageID,
              let target = store.timeline.first(where: { item in
                  guard case .message(let message, _) = item else { return false }
                  return message.id == focusedMessageID
              }) else { return }
        withAnimation { proxy.scrollTo(target.id, anchor: .center) }
    }
}

/// 使用可滚动编辑器，避免消息输入框在辅助功能动态字体尺寸下
/// 因 UIKit 文本框固定高度而被裁剪。
private struct V2ComposerTextInput: View {
    @Binding var text: String
    let placeholder: String
    let accessibilityLabel: String
    let accessibilityHint: String

    var body: some View {
        TextEditor(text: $text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(minHeight: 64, maxHeight: 128)
            .background {
                RoundedRectangle(cornerRadius: 9)
                    .fill(.background)
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(.quaternary)
                    }
            }
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(accessibilityHint)
    }
}

private struct V2ConversationAttachmentRow: View {
    @Bindable var store: V2ConversationDetailStore
    let attachment: V2ConversationAttachmentItem

    var body: some View {
        let removalLabel = "移除附件 " + attachment.displayName
        let removeIdentifier = "v2.message.attachment.remove." + attachment.id.uuidString
        HStack(spacing: 8) {
            Image(systemName: attachmentIcon(for: attachment.state))
                .foregroundStyle(attachmentColor(for: attachment.state))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.displayName)
                    .lineLimit(1)
                Text(attachmentStatusText(for: attachment.state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("附件 " + attachment.displayName)
            .accessibilityValue(attachmentStatusText(for: attachment.state))
            Spacer()
            Button("移除", role: .destructive) {
                Task { await store.removeAttachment(id: attachment.id) }
            }
            .frame(minWidth: 44, minHeight: 44)
            .disabled(store.isSending)
            .accessibilityLabel(removalLabel)
            .accessibilityIdentifier(removeIdentifier)
        }
    }

    private func attachmentIcon(for state: V2ConversationAttachmentItem.State) -> String {
        switch state {
        case .staged: "paperclip"
        case .uploading: "arrow.up.circle"
        case .available: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    private func attachmentColor(for state: V2ConversationAttachmentItem.State) -> Color {
        switch state {
        case .staged: .secondary
        case .uploading: .blue
        case .available: .green
        case .failed: .red
        }
    }

    private func attachmentStatusText(for state: V2ConversationAttachmentItem.State) -> String {
        switch state {
        case .staged: "等待上传"
        case .uploading: "正在上传并等待安全扫描"
        case .available: "已准备发送"
        case .failed: "上传失败，可重试"
        }
    }
}

private struct V2ConversationTimelineActivityRow: View {
    let activity: V2ConversationTimelineItem.Activity

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 24)
            .accessibilityLabel("系统提示")
            .accessibilityValue(text)
            .accessibilityIdentifier("v2.timeline.activity.\(activity.id)")
    }

    private var text: String {
        switch activity.kind {
        case .directMessageRestricted:
            "当前无法向此会话发送消息"
        case .systemAccountReadOnly:
            "此系统账号仅用于发送通知"
        }
    }
}

private struct V2ConversationMessageRow: View {
    @Bindable var store: V2ConversationDetailStore
    let message: V2ConversationMessageItem
    let beginEditing: () -> Void
    let showReadReceipts: () -> Void
    let beginForward: () -> Void
    let beginCopyAttachments: () -> Void

    var body: some View {
        HStack {
            if message.isOutgoing { Spacer(minLength: 44) }
            if !message.isOutgoing, let key = store.authorPresentationKey(for: message) { V2AuthorizedAvatarView(key: key, showsName: store.isGroupConversation) }
            V2ConversationMessageBubble(store: store, message: message, beginEditing: beginEditing, showReadReceipts: showReadReceipts, beginForward: beginForward, beginCopyAttachments: beginCopyAttachments)
            if message.isOutgoing, let key = store.authorPresentationKey(for: message) { V2AuthorizedAvatarView(key: key) }
            if !message.isOutgoing { Spacer(minLength: 44) }
        }
        // Keep the row queryable without letting its identifier overwrite the
        // independently actionable message controls (reaction, edit and
        // withdrawal) in SwiftUI's accessibility bridge.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v2.message.row.\(message.id)")
        .contentShape(Rectangle())
        .overlay(alignment: message.isOutgoing ? .topTrailing : .topLeading) {
            if store.isSelectingMessagesForForward && !message.isWithdrawn {
                Image(systemName: store.selectedForForward(message) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(store.selectedForForward(message) ? Color.accentColor : Color.secondary)
                    .font(.title3)
                    .padding(4)
                    .accessibilityHidden(true)
            }
        }
        .onTapGesture {
            if store.isSelectingMessagesForForward { store.toggleForwardSelection(for: message) }
        }
        .onAppear { Task { await store.reportVisibleMessage(message) } }
        // VoiceOver message operations belong to the whole row, whose target
        // includes the complete bubble and surrounding touch area. Attaching
        // them to the bubble lets a one-character Text inherit actionable
        // semantics with an unusably small hit region.
        .modifier(V2MessageAccessibilityActions(
            canEdit: store.canEditMessage(message),
            canWithdraw: store.canWithdrawMessage(message),
            edit: beginEditing,
            withdraw: { Task { await store.withdrawMessage(message) } }
        ))
        .accessibilityAction(named: Text(store.selectedForForward(message) ? "取消选择转发消息" : "选择转发消息")) {
            if store.isSelectingMessagesForForward { store.toggleForwardSelection(for: message) }
        }
    }
}

private struct V2ConversationMessageBubble: View {
    @Bindable var store: V2ConversationDetailStore
    let message: V2ConversationMessageItem
    let beginEditing: () -> Void
    let showReadReceipts: () -> Void
    let beginForward: () -> Void
    let beginCopyAttachments: () -> Void

    var body: some View {
        VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 3) {
            if message.isFavorited {
                Label("已收藏", systemImage: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("已收藏")
                    .accessibilityIdentifier("v2.message.favorite.indicator.\(message.id)")
            }
            if let replyTo = message.replyTo {
                Label(store.replyPreview(for: replyTo), systemImage: "arrowshape.turn.up.left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityLabel("回复：\(store.replyPreview(for: replyTo))")
                    .accessibilityIdentifier("v2.message.reply.reference.\(message.id)")
            }
            if !message.text.isEmpty {
                ZStack(alignment: message.isOutgoing ? .trailing : .leading) {
                    V2RichMessageText(text: message.text, entities: message.entities)
                        // A withdrawn-message bubble already has a neutral
                        // background. Keep its tombstone readable rather than
                        // using low-contrast secondary text on that surface.
                        .foregroundStyle(.primary)
                        .accessibilityHidden(true)
                }
                // Do not let a short Text view become the accessible node:
                // the wrapper is the message body and owns a full target.
                .frame(minWidth: 44, minHeight: 44, alignment: message.isOutgoing ? .trailing : .leading)
                .accessibilityElement()
                .accessibilityLabel(message.text)
                .accessibilityIdentifier("v2.message.body.\(message.id)")
            }
            if !message.mentions.isEmpty {
                Text(mentionSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(mentionSummary)
                    .accessibilityIdentifier("v2.message.mentions.\(message.id)")
            }
            let links = Array(Set(message.entities.compactMap { entity -> URL? in
                entity.kind == .link ? entity.linkURL : nil
            }))
            if !links.isEmpty {
                ForEach(links, id: \.self) { url in
                    V2SafeLinkPreview(url: url, messageID: message.id)
                }
            }
            if !message.media.isEmpty {
                VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 6) {
                    Label(attachmentSummary, systemImage: "paperclip")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("消息附件")
                        .accessibilityValue(attachmentSummary)
                    ForEach(Array(message.media.enumerated()), id: \.element.mediaID) { index, media in
                        V2ConversationMediaAttachmentRow(
                            store: store,
                            message: message,
                            media: media,
                            presentation: message.presentation(for: media),
                            index: index
                        )
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("v2.message.attachments.\(message.id)")
            }
            Text(message.createdAt, format: .dateTime.hour().minute())
                .font(.caption)
                .foregroundStyle(.primary)
            if message.isOutgoing && message.isReadByPeer {
                Text("已读")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("对方已读")
                    .accessibilityIdentifier("v2.message.read.\(message.id)")
            }
            if message.isForwarded {
                Label("转发的消息", systemImage: "arrowshape.turn.up.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("v2.message.forwarded.\(message.id)")
            }
            if store.isGroupConversation && message.isPinnedInGroup {
                Label("已置顶", systemImage: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("v2.group.message.pinned.\(message.id)")
            }
            if message.isOutgoing && store.isGroupConversation && !message.isWithdrawn {
                Button("查看已读") { showReadReceipts() }
                    .font(.caption)
                    .accessibilityHint("查看已读这条消息的群成员")
                    .accessibilityIdentifier("v2.message.group-readers.\(message.id)")
            }
            if store.canReactToMessage(message) {
                V2ConversationReactionControls(store: store, message: message)
            }
            if !message.isWithdrawn {
                Button("回复", systemImage: "arrowshape.turn.up.left") { store.beginReply(to: message) }
                    .font(.caption)
                    .accessibilityHint("引用这条消息回复")
                    .accessibilityIdentifier("v2.message.reply.\(message.id)")
            }
        }
        .padding(10)
        .background(message.isOutgoing ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .contextMenu {
            if !message.isWithdrawn {
                Button("回复", systemImage: "arrowshape.turn.up.left") { store.beginReply(to: message) }
            }
            if !message.isWithdrawn {
                Button("转发", systemImage: "arrowshape.turn.up.right") { beginForward() }
                    .accessibilityIdentifier("v2.message.forward.\(message.id)")
                if !message.media.isEmpty {
                    Button("复制附件到会话", systemImage: "doc.on.doc", action: beginCopyAttachments)
                }
            }
            if store.canEditMessage(message) {
                Button("编辑") { beginEditing() }
                    .accessibilityIdentifier("v2.message.edit.\(message.id)")
            }
            if store.canWithdrawMessage(message) {
                Button("撤回", role: .destructive) {
                    Task { await store.withdrawMessage(message) }
                }
                .disabled(!store.canWithdrawMessage(message))
                .accessibilityValue(store.isMessageActionInFlight(message) ? "正在保存消息操作" : "")
                .accessibilityIdentifier("v2.message.withdraw.\(message.id)")
            }
            if !message.isWithdrawn {
                Button(message.isFavorited ? "取消收藏" : "收藏", systemImage: message.isFavorited ? "star.slash" : "star") {
                    Task { await store.setFavorite(message) }
                }
                .accessibilityIdentifier("v2.message.favorite.\(message.id)")
                if store.isGroupConversation {
                    Button(message.isPinnedInGroup ? "取消置顶消息" : "置顶消息", systemImage: message.isPinnedInGroup ? "pin.slash" : "pin") { Task { await store.pinInGroup(message) } }
                        .accessibilityIdentifier("v2.group.message.pin.\(message.id)")
                }
            }
        }
    }

    private var attachmentSummary: String {
        let images = message.mediaPresentations.filter { $0.kind == .image || $0.kind == .animatedImage }.count
        let videos = message.mediaPresentations.filter { $0.kind == .video }.count
        let audio = message.mediaPresentations.filter { $0.kind == .audio }.count
        let files = message.media.count - images - videos - audio
        let components = [
            images > 0 ? "\(images) 张图片" : nil,
            videos > 0 ? "\(videos) 个视频" : nil,
            audio > 0 ? "\(audio) 个音频" : nil,
            files > 0 ? "\(files) 个文件" : nil,
        ].compactMap { $0 }
        return components.joined(separator: "、")
    }

    private var mentionSummary: String {
        let userCount = message.mentions.reduce(into: 0) { count, target in
            if case .user = target { count += 1 }
        }
        let includesEveryone = message.mentions.contains(.everyone)
        switch (includesEveryone, userCount) {
        case (true, 0): return "提及所有人"
        case (true, _): return "提及所有人及 \(userCount) 位成员"
        case (false, _): return "提及 \(userCount) 位成员"
        }
    }
}

private struct V2RichMessageText: View {
    let text: String
    let entities: [V2MessageEntity]

    var body: some View {
        Text(attributedText)
    }

    private var attributedText: AttributedString {
        var value = AttributedString(text)
        for entity in entities {
            let range = NSRange(location: entity.offsetUTF16, length: entity.lengthUTF16)
            guard let stringRange = Range(range, in: text),
                  let attributedRange = Range(stringRange, in: value)
            else { continue }
            switch entity.kind {
            case .bold:
                value[attributedRange].font = .body.bold()
            case .italic:
                value[attributedRange].font = .body.italic()
            case .code, .preformatted:
                value[attributedRange].font = .system(.body, design: .monospaced)
            case .link:
                value[attributedRange].link = entity.linkURL
                value[attributedRange].foregroundColor = .blue
            case .underline, .strikethrough, .spoiler:
                // The canonical entity still synchronizes on platforms where
                // the native text renderer has no matching visual style.
                break
            }
        }
        return value
    }
}

/// 让原本只能长按触发的消息操作也能通过 VoiceOver 转子访问。
///
/// 操作仍然带有条件判断，使当前不可用的动作不会被朗读出来。
private struct V2MessageAccessibilityActions: ViewModifier {
    let canEdit: Bool
    let canWithdraw: Bool
    let edit: () -> Void
    let withdraw: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if canEdit && canWithdraw {
            content
                .accessibilityAction(named: "编辑消息") { edit() }
                .accessibilityAction(named: "撤回消息") { withdraw() }
        } else if canEdit {
            content.accessibilityAction(named: "编辑消息") { edit() }
        } else if canWithdraw {
            content.accessibilityAction(named: "撤回消息") { withdraw() }
        } else {
            content
        }
    }
}

/// 有界的多目标选择器。
///
/// 它刻意只接收会话列表存储提供的紧凑列表快照；
/// 在该页面渲染期间不会去查询或修改房间状态。

private struct V2ForwardMessagesSheet: View {
    @Bindable var store: V2ConversationDetailStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTargetRoomIDs: Set<String> = []
    @State private var selectionFeedback: String?
    @State private var profilePageID = UUID()

    var body: some View {
        NavigationStack {
            List {
                Section("已选消息") {
                    Text("\(store.selectedForwardMessageIDs.count) 条消息")
                        .accessibilityIdentifier("v2.message.forward.source-count")
                }
                Section("目标会话") {
                    if store.forwardTargets.isEmpty {
                        ContentUnavailableView("没有可用的目标会话", systemImage: "bubble.left.and.bubble.right")
                    } else {
                        ForEach(store.forwardTargets) { target in
                            Button {
                                toggle(target)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: selectedTargetRoomIDs.contains(target.roomID) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selectedTargetRoomIDs.contains(target.roomID) ? Color.accentColor : Color.secondary)
                                    V2ConversationLabelView(label: target.label)
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityElement(children: .combine)
                            .accessibilityValue(selectedTargetRoomIDs.contains(target.roomID) ? "已选择" : "未选择")
                            .accessibilityHint("选择为转发目标")
                            .accessibilityIdentifier("v2.message.forward.target.\(target.roomID)")
                        }
                    }
                }
                if let selectionFeedback {
                    Section {
                        Text(selectionFeedback)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("v2.message.forward.feedback")
                    }
                }
            }
            .navigationTitle("转发到")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("返回") { dismiss() }
                        .accessibilityIdentifier("v2.message.forward.back")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发送") {
                        let targets = Array(selectedTargetRoomIDs)
                        Task {
                            if await store.forwardSelectedMessages(to: targets) { dismiss() }
                        }
                    }
                    .disabled(selectedTargetRoomIDs.isEmpty || store.isForwardingMessages)
                    .accessibilityValue(store.isForwardingMessages ? "正在保存转发操作" : "")
                    .accessibilityIdentifier("v2.message.forward.send")
                }
            }
        }
        .authorPresentationPage(context: .list(profilePageID))
    }

    private func toggle(_ target: V2ConversationForwardTarget) {
        if selectedTargetRoomIDs.contains(target.roomID) {
            selectedTargetRoomIDs.remove(target.roomID)
            selectionFeedback = nil
        } else if selectedTargetRoomIDs.count < V2ForwardMessagesCommand.maximumTargetRooms {
            selectedTargetRoomIDs.insert(target.roomID)
            selectionFeedback = nil
        } else {
            selectionFeedback = "一次最多转发到 \(V2ForwardMessagesCommand.maximumTargetRooms) 个会话。"
        }
    }
}

private struct V2CopyAttachmentsSheet: View {
    @Bindable var store: V2ConversationDetailStore
    let message: V2ConversationMessageItem
    @Environment(\.dismiss) private var dismiss
    @State private var profilePageID = UUID()
    @State private var selectedTarget: String?
    @State private var feedback: String?

    var body: some View {
        NavigationStack {
            List {
                if store.forwardTargets.isEmpty {
                    ContentUnavailableView("没有可用的目标会话", systemImage: "bubble.left.and.bubble.right")
                }
                ForEach(store.forwardTargets) { target in
                    Button { selectedTarget = target.roomID } label: {
                        HStack {
                            V2ConversationLabelView(label: target.label)
                            Spacer()
                            if selectedTarget == target.roomID { ProgressView().accessibilityLabel("正在保存复制操作") }
                        }
                    }
                    .disabled(selectedTarget != nil)
                    .accessibilityHint("复制附件到此会话")
                    .accessibilityIdentifier("v2.message.copy.target.\(target.roomID)")
                }
                if let feedback { Text(feedback).foregroundStyle(.secondary) }
            }
            .navigationTitle("复制附件到")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回") { dismiss() } } }
            .task(id: selectedTarget) {
                guard let target = selectedTarget else { return }
                let saved = await store.copyAttachments(message, to: target)
                guard !Task.isCancelled else { return }
                if saved { dismiss() }
                else { feedback = store.messageActionFeedback; selectedTarget = nil }
            }
        }
        .authorPresentationPage(context: .list(profilePageID))
    }
}

private struct V2MessageEditSheet: View {
    @Bindable var store: V2ConversationDetailStore
    let message: V2ConversationMessageItem
    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(store: V2ConversationDetailStore, message: V2ConversationMessageItem) {
        self.store = store
        self.message = message
        _text = State(initialValue: message.text)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextEditor(text: $text)
                    .frame(minHeight: 140)
                    .accessibilityLabel("消息内容")
                    .accessibilityIdentifier("v2.message.edit-text")
                if let feedback = store.messageActionFeedback {
                    Text(feedback)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("v2.message.edit-feedback")
                }
            }
            .navigationTitle("编辑消息")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .accessibilityIdentifier("v2.message.edit-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let editedText = text
                        Task {
                            if await store.editMessage(message, text: editedText) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(
                        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || text == message.text
                            || !store.canEditMessage(message)
                    )
                    .accessibilityValue(store.isMessageActionInFlight(message) ? "正在保存消息操作" : "")
                    .accessibilityIdentifier("v2.message.edit-save")
                }
            }
        }
    }
}

private struct V2ConversationReactionControls: View {
    @Bindable var store: V2ConversationDetailStore
    let message: V2ConversationMessageItem

    var body: some View {
        HStack(spacing: 4) {
            ForEach(message.reactions) { reaction in
                Button {
                    Task { await store.changeReaction(reaction.reaction, on: message) }
                } label: {
                    Text("\(reaction.reaction) \(reaction.count)")
                }
                .buttonStyle(.bordered)
                .tint(reaction.includesCurrentUser ? .accentColor : .secondary)
                .frame(minWidth: 44, minHeight: 44)
                .disabled(!store.canReactToMessage(message))
                .accessibilityLabel(reaction.reaction + " 表情反应")
                .accessibilityValue(reactionAccessibilityValue(reaction))
                .accessibilityHint(reaction.includesCurrentUser ? "双击移除反应" : "双击添加反应")
                .accessibilityIdentifier("v2.message.reaction.\(message.id).\(reaction.reaction)")
            }
            Menu {
                ForEach(store.reactionPresets, id: \.self) { reaction in
                    Button(reaction) {
                        Task { await store.changeReaction(reaction, on: message) }
                    }
                    .accessibilityIdentifier("v2.message.reaction-picker.\(message.id).\(reaction)")
                }
            } label: {
                Image(systemName: "face.smiling")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
            }
            .disabled(!store.canReactToMessage(message))
            .accessibilityLabel("添加反应")
            .accessibilityValue(store.isMessageActionInFlight(message) ? "正在保存消息操作" : "")
            .accessibilityIdentifier("v2.message.reaction-picker.\(message.id)")
        }
    }

    private func reactionAccessibilityValue(_ reaction: V2ConversationMessageReaction) -> String {
        if reaction.includesCurrentUser {
            return "\(reaction.count) 人已添加，包括你"
        }
        return "\(reaction.count) 人已添加，不包括你"
    }
}
