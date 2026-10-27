import Foundation
import IMV2ClientKit
import IMV2Core
import Observation
import SwiftUI
import MessagingUI
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
    let preferenceActivity: V2PreferenceActivityStore?
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
    private(set) var directConversationRequests: [V2DirectRoomPending] = []
    private var discoveredDirectRoomIDs = Set<RoomID>()

    var pendingDirectConversationRequests: [V2DirectRoomPending] {
        guard !isShowingArchived else { return [] }
        return Self.pendingDirectRequests(directConversationRequests, conversations: items)
    }

    static func pendingDirectRequests(_ requests: [V2DirectRoomPending], conversations: [V2ConversationListItem]) -> [V2DirectRoomPending] {
        let existingPeers = Set(conversations.compactMap { $0.kind.directAccountKind != nil ? $0.presentationKey?.userID : nil })
        var seen = existingPeers
        return requests.sorted { $0.work.localSequence > $1.work.localSequence }.filter {
            !$0.work.execution.isTerminal && $0.work.scheduling != .finished && $0.receipt == nil
                && seen.insert($0.command.targetUserID).inserted
        }
    }
    private(set) var groupConversationFeedback: String?
    private(set) var conversationStateFeedback: String?
    private(set) var conversationRefreshFeedback: String?
    private var changingPreferenceRooms = Set<String>()
    private(set) var isOpeningDirectConversation = false
    private(set) var isCreatingGroupConversation = false
    private(set) var pendingGroupConversationOperationID: String?
    private(set) var groupCreationNeedsConfirmation=false
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
        preferenceActivity = (environment.messages.stateChanger as? any V2PersonalPreferenceManaging).map { V2PreferenceActivityStore(manager: $0) }
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
                groupConversationFeedback = "建群请求已安全保存；取消结果由服务器确认。"
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

    func observeGroupCreation() async {
        guard let creator=groupConversationCreator as? any V2GroupCreationRecovering else { return }
        do {
            for try await _ in await creator.creationUpdates() {
                try Task.checkCancellation()
                await restoreDurableGroupCreationStatusIfNeeded()
            }
        } catch is CancellationError {} catch { groupConversationFeedback="建群状态暂不可读，已保存的请求仍会保留。" }
    }
    func resumePendingGroupCreation() async {
        guard let operationID=pendingGroupConversationOperationID,let creator=groupConversationCreator as? any V2GroupCreationRecovering else { return }
        do { try await creator.resumeCreation(operationID:operationID) }
        catch { groupConversationFeedback="暂时无法继续核对建群结果。" }
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
                groupConversationFeedback = "正在核对取消结果；若创建已开始，将继续确认原结果。"
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
        conversationRefreshFeedback = nil
        let operation = UUID()
        conversationRefreshOperation = operation
        conversationPageOperation = nil
        defer { if conversationRefreshOperation == operation { conversationRefreshOperation = nil } }
        let retainedCount = resetWindow ? 50 : min(Self.maximumWindowCount, max(50, items.count))
        if resetWindow { items = []; conversationNextCursor = nil; hasEarlierConversations = false; viewport.reset() }
        if state != .loaded || resetWindow { state = .loading }
        let archived = isShowingArchived
        do {
            await recoverDiscoveredDirectConversations()
            try Task.checkCancellation()
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
                V2ProjectionVisibilityScope.conversationCommit?.didPublishSnapshot()
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
            if items.isEmpty {
                state = .failed
            } else {
                state = .loaded
                conversationRefreshFeedback = "无法刷新会话列表，保留上次读取的内容。"
            }
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
        V2ProjectionVisibilityScope.conversationCommit?.didPublishSnapshot()
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

    func displayedConversationState(_ item: V2ConversationListItem) async -> V2ConversationListItem {
        guard let manager = conversationStateChanger as? any V2PersonalPreferenceManaging,
              let desired = try? await manager.desiredPreferenceTarget(.conversation(roomID: .init(item.id), isPinned: item.isPinned, isArchived: item.isArchived, muteUntil: item.muteUntil)),
              case .conversation(_, let pinned, let archived, let mute) = desired else { return item }
        return V2ConversationListItem(id: item.id, title: item.title, preview: item.preview, lastActivity: item.lastActivity, isOutgoing: item.isOutgoing, kind: item.kind, isPinned: pinned, isArchived: archived, muteUntil: mute, unreadCount: item.unreadCount, presentationKey: item.presentationKey)
    }

    func updateConversationState(_ item: V2ConversationListItem, isPinned: Bool? = nil, isArchived: Bool? = nil, muteUntil: Date?? = nil) async {
        guard let conversationStateChanger else { conversationStateFeedback = "会话设置暂不可用。"; return }
        guard changingPreferenceRooms.insert(item.id).inserted else { return }
        defer { changingPreferenceRooms.remove(item.id) }
        do {
            var pinned = item.isPinned, archived = item.isArchived, mute = item.muteUntil
            if let manager = conversationStateChanger as? any V2PersonalPreferenceManaging,
               case .conversation(_, let desiredPinned, let desiredArchived, let desiredMute) = try await manager.desiredPreferenceTarget(.conversation(roomID: .init(item.id), isPinned: pinned, isArchived: archived, muteUntil: mute)) {
                pinned = desiredPinned; archived = desiredArchived; mute = desiredMute
            }
            let outcome = try await conversationStateChanger.setState(
                roomID: item.id,
                isPinned: isPinned ?? pinned,
                isArchived: isArchived ?? archived,
                muteUntil: muteUntil ?? mute
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
            groupCreationNeedsConfirmation=false
            switch status {
            case .expired:
                pendingGroupConversationOperationID=nil
                groupConversationFeedback="建群请求已过期，未创建群聊。可重新创建。"
            case .needsConfirmation(let operationID):
                pendingGroupConversationOperationID=operationID
                groupCreationNeedsConfirmation=true
                groupConversationFeedback="建群结果待确认，可继续核对原请求。"
            case .created:
                pendingGroupConversationOperationID=nil
                groupConversationFeedback="群聊已创建，可从会话列表打开。"
            case .queuedForRetry(let operationID):
                pendingGroupConversationOperationID = operationID
                groupConversationFeedback = "建群请求已安全保存；取消结果由服务器确认。"
            case .cancelling:
                pendingGroupConversationOperationID = nil
                groupConversationFeedback = "正在核对取消结果；若创建已开始，将继续确认原结果。"
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

    func observeDirectConversationRequests() async {
        guard let opener=directConversationOpener as? any V2DirectConversationRecovering else { return }
        do {
            for try await requests in await opener.service.updates() {
                try Task.checkCancellation()
                await updateDirectConversationRequests(requests)
            }
        } catch is CancellationError { return }
        catch { directConversationFeedback="无法读取已保存的私聊请求。" }
    }

    func updateDirectConversationRequests(_ requests: [V2DirectRoomPending]) async {
        directConversationRequests = requests
        await refresh()
    }

    private func recoverDiscoveredDirectConversations() async {
        guard let source = dataSource as? any V2DiscoveredConversationRefreshing else { return }
        let known = Set(items.compactMap { try? RoomID($0.id) })
        let opened = Set(directConversationRequests.compactMap { request -> RoomID? in
            guard case .opened(let room, _)? = request.receipt?.outcome else { return nil }
            return room
        })
        let missing = opened.subtracting(known).subtracting(discoveredDirectRoomIDs)
        guard !missing.isEmpty else { return }
        discoveredDirectRoomIDs.formUnion(missing)
        do {
            // Receipts identify rooms to query; only a fresh authorized server
            // observation may restore them to the durable conversation list.
            try await source.refreshDiscoveredConversations(roomIDs: Array(missing))
        } catch {
            discoveredDirectRoomIDs.subtract(missing)
        }
    }

    func resumeDirectConversationRequest(_ request:V2DirectRoomPending) async {
        guard let opener=directConversationOpener as? any V2DirectConversationRecovering else { return }
        do { try await opener.service.resume(id:request.work.id) }
        catch is CancellationError { return }
        catch { directConversationFeedback="暂时无法继续核对私聊请求。" }
    }

    func directConversationRequestStatus(_ request:V2DirectRoomPending) -> String {
        if let receipt=request.receipt {
            switch receipt.outcome {
            case .opened:return "会话已就绪"
            case .closed:return "请求已关闭，未创建会话"
            case .rejected(.firstSubmissionExpired):return "请求已过期，可重新发起"
            case .rejected:return "当前无法创建会话"
            }
        }
        switch request.work.execution {
        case .expiredUnsubmitted:return "请求已过期，未提交"
        case .cancelledLocally:return "请求已取消，未提交"
        default:break
        }
        switch request.work.scheduling {
        case .needsAttention:return "需要继续核对结果"
        case .waitingForNetwork:return "等待网络恢复"
        case .waitingForAuthentication:return "等待登录恢复"
        case .suspended:return "请求已暂停"
        default:return "请求已保存，正在处理"
        }
    }

    func openDirectConversation(handle: String) async -> String? {
        let target = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            directConversationFeedback = "请输入对方的公开 ID。"
            return nil
        }
        guard directConversationOpener != nil else {
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
            return await resolveDirectConversation(with: identity)
        } catch is CancellationError {
            return nil
        } catch {
            directConversationFeedback = "无法查找用户，请检查公开 ID 和网络连接。"
            return nil
        }
    }

    func openLocalFirstDirectConversation(handle: String) async -> V2ConversationDestination? {
        let handle = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !handle.isEmpty, !isOpeningDirectConversation, let publicIdentityResolver else { return nil }
        isOpeningDirectConversation = true
        defer { isOpeningDirectConversation = false }
        do {
            // An unknown public handle still needs identity lookup. Once the
            // identity is known, opening the chat never waits for room creation.
            let identity = try await publicIdentityResolver.resolve(handle: handle)
            try Task.checkCancellation()
            isOpeningDirectConversation = false
            return await openLocalFirstDirectConversation(with: identity)
        } catch is CancellationError { return nil }
        catch { directConversationFeedback = "无法查找用户，请检查公开 ID 和网络连接。"; return nil }
    }

    private var localDirectIdentities: [UUID: V2PublicIdentity] = [:]

    func localDirectIdentity(for operationID: UUID) -> V2PublicIdentity? {
        localDirectIdentities[operationID] ?? directConversationRequests.first { $0.work.id == operationID }?.publicIdentity
    }

    /// Opening a known contact depends only on a local durable enqueue.
    /// Server room discovery and message delivery continue in the account runtime.
    func openLocalFirstDirectConversation(with identity: V2PublicIdentity) async -> V2ConversationDestination? {
        guard !isOpeningDirectConversation, identity.userID.rawValue != userID else { return nil }
        if items.contains(where: { $0.kind.directAccountKind != nil && $0.presentationKey?.userID == identity.userID }) {
            return await openDirectConversation(with: identity).map { .room(.init(roomID: $0)) }
        }
        guard let recovering = directConversationOpener as? any V2DirectConversationRecovering else {
            return await openDirectConversation(with: identity).map { .room(.init(roomID: $0)) }
        }
        isOpeningDirectConversation = true
        defer { isOpeningDirectConversation = false }
        do {
            if let room = try await recovering.service.existingLocalRoom(with: identity.userID) {
                try Task.checkCancellation()
                registerLocalDirectRoom(room.rawValue, identity: identity)
                directConversationFeedback = nil
                return .init(roomID: room.rawValue)
            }
            let id = try await recovering.service.enqueue(publicIdentity: identity)
            try Task.checkCancellation()
            localDirectIdentities[id] = identity
            directConversationFeedback = nil
            return .localDirect(.init(operationID: id))
        } catch is CancellationError { return nil }
        catch { directConversationFeedback = "无法保存本地会话，请重试。"; return nil }
    }

    func registerLocalDirectRoom(_ roomID: String, identity: V2PublicIdentity) {
        explicitRoomTitles[roomID] = identity.displayName
        explicitRoomKinds[roomID] = .direct(accountKind: identity.accountKind)
        explicitDirectPresentationKeys[roomID] = .init(userID: identity.userID, context: .directConversation)
    }

    var localDirectConversationService: V2DirectRoomOperationService? {
        (directConversationOpener as? any V2DirectConversationRecovering)?.service
    }

    /// All entry points register the same direct-room metadata before navigation,
    /// including rooms that have not reached the current paginated list yet.
    func openDirectConversation(with identity: V2PublicIdentity) async -> String? {
        guard !isOpeningDirectConversation else { return nil }
        isOpeningDirectConversation = true
        defer { isOpeningDirectConversation = false }
        return await resolveDirectConversation(with: identity)
    }

    private func resolveDirectConversation(with identity: V2PublicIdentity) async -> String? {
        guard !Task.isCancelled else { return nil }
        guard identity.userID.rawValue != userID else {
            directConversationFeedback = "不能与自己创建私聊。"
            return nil
        }
        do {
            let roomID: String
            if let existing = items.first(where: {
                $0.kind.directAccountKind != nil && $0.presentationKey?.userID == identity.userID
            }) {
                roomID = existing.id
            } else if let directConversationOpener {
                roomID = try await directConversationOpener.openConversation(with: identity)
            } else {
                directConversationFeedback = "实时网关尚未可用，无法新建会话。"
                return nil
            }
            try Task.checkCancellation()
            guard (try? RoomID(roomID)) != nil else {
                directConversationFeedback = "会话信息无效，请刷新后重试。"
                return nil
            }
            explicitRoomTitles[roomID] = identity.displayName
            explicitRoomKinds[roomID] = .direct(accountKind: identity.accountKind)
            explicitDirectPresentationKeys[roomID] = .init(userID: identity.userID, context: .directConversation)
            directConversationFeedback = nil
            return roomID
        } catch V2DirectConversationOpeningState.queued {
            directConversationFeedback = "连接暂未完成，请检查网络后重试；原请求会保留，不会重复创建。"
            return nil
        } catch V2DirectConversationOpeningState.expired {
            directConversationFeedback = "私聊请求已过期，可重新发起。"
            return nil
        } catch V2DirectConversationOpeningState.rejected {
            directConversationFeedback = "当前无法与对方创建私聊。"
            return nil
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

    @Environment(\.v2UserInteractionContext) private var userContext
    @State private var choosingGroupFriends = false
    @Bindable var store: V2ConversationListStore
    let localE2EConversationLaunchFixture: V2LiveLocalAccountE2EConversationLaunchFixture?
    private let accountMenu: V2ConversationAccountMenu?
    private let rootNavigation: V2RootNavigationStore
    private let groupInvitationStore: V2GroupInvitationStore?
    @State private var newConversationSheet: NewConversationSheet?
    @State private var conversationAfterSheetDismissal: V2ConversationDestination?
    @State private var directTargetUserID: String
    @State private var groupTitle = ""
    @State private var groupMemberUserIDs = ""
    @State private var directSubmissionTask: Task<Void, Never>?
    @State private var groupSubmissionTask: Task<Void, Never>?
    @State private var groupCancellationTask: Task<Void, Never>?
    @State private var messageSearchStore: V2ConversationSearchStore?
    @State private var isPresentingMessageSearch = false
    @State private var isPresentingPreferenceActivity = false
    @State private var isPresentingFavorites = false
    @State private var conversationQuery = ""

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
        self.rootNavigation = rootNavigation ?? V2RootNavigationStore()
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
        Group {
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
                    if store.visibleItems.isEmpty && store.pendingDirectConversationRequests.isEmpty {
                        V2ConversationEmptyState(
                            title: store.isShowingArchived ? "没有已归档会话" : "暂无会话",
                            symbol: store.isShowingArchived ? "archivebox" : "bubble.left.and.bubble.right",
                            description: store.isShowingArchived ? "归档的会话会显示在这里。" : "与朋友聊聊，或创建群聊开启新的讨论。"
                        )
                    } else {
                    ScrollViewReader { scrollProxy in
                    List {
                    ForEach(store.pendingDirectConversationRequests, id: \.command.targetUserID) { request in
                        NavigationLink(value: V2LocalDirectConversationRoute(operationID: request.work.id)) {
                            HStack(spacing: 14) {
                                let key = V2ProfileViewLookupKey(userID: request.command.targetUserID, context: .relationship)
                                V2AuthorizedAvatarView(key: key, size: 52)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(request.publicIdentity?.displayName ?? "聊天")
                                        .font(.body.weight(.semibold))
                                    Text(store.directConversationRequestStatus(request))
                                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "clock").foregroundStyle(.orange)
                            }.padding(.vertical, 12)
                        }
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        .accessibilityIdentifier("v2.conversation.local.\(request.work.id.uuidString)")
                    }
                    if store.hasEarlierConversations {
                        Button("查看前面的会话") { Task { await store.loadEarlierConversations() } }
                            .disabled(store.isLoadingMoreConversations)
                            .accessibilityIdentifier("v2.conversation.load-earlier")
                        Button("回到最新会话") { Task { await store.refresh(resetWindow: true) } }
                            .accessibilityIdentifier("v2.conversation.return-to-latest")
                    }
                    ForEach(filteredConversations) { item in
                        NavigationLink(value: V2ConversationRoute(roomID: item.id)) {
                            V2ConversationSummaryRow(item: item)
                        }
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button(item.isPinned ? "取消置顶" : "置顶", systemImage: item.isPinned ? "pin.slash" : "pin") {
                                Task { await store.updateConversationState(item, isPinned: !item.isPinned) }
                            }.tint(.orange)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(item.isArchived ? "取消归档" : "归档", systemImage: "archivebox") {
                                Task { await store.updateConversationState(item, isArchived: !item.isArchived) }
                            }.tint(.indigo)
                            Button(item.muteUntil.map { $0 > Date() } == true ? "恢复提醒" : "免打扰", systemImage: "bell.slash") {
                                Task { await store.updateConversationState(item, muteUntil: .some(item.muteUntil.map { $0 > Date() } == true ? nil : Date().addingTimeInterval(315_576_000))) }
                            }.tint(.gray)
                        }
                        .contextMenu {
                            Menu("会话置顶", systemImage: "pin") {
                                Button(item.isPinned ? "取消置顶会话" : "置顶会话") { Task { await store.updateConversationState(item, isPinned: !item.isPinned) } }
                            }
                            Menu("会话归档", systemImage: "archivebox") {
                                Button(item.isArchived ? "取消归档" : "归档会话") { Task { await store.updateConversationState(item, isArchived: !item.isArchived) } }
                            }
                            Menu("消息提醒", systemImage: "bell") {
                                Button("免打扰 1 小时") { Task { await store.updateConversationState(item, muteUntil: .some(Date().addingTimeInterval(60 * 60))) } }
                                Button("免打扰 8 小时") { Task { await store.updateConversationState(item, muteUntil: .some(Date().addingTimeInterval(28800))) } }
                                Button("持续免打扰") { Task { await store.updateConversationState(item, muteUntil: .some(Date().addingTimeInterval(315_576_000))) } }
                                if item.muteUntil.map({ $0 > Date() }) == true { Button("取消免打扰") { Task { await store.updateConversationState(item, muteUntil: .some(nil)) } } }
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
                                .onAppear { Task { await store.loadMoreConversations() } }
                                .accessibilityIdentifier("v2.conversation.load-more")
                            }
                            Spacer()
                        }
                    }
                    }
                    .listStyle(.plain)
                    .listRowSeparatorTint(V2VisualStyle.separator)
                    .v2PageSurface()
                    .refreshable { await store.refresh() }
                    .accessibilityIdentifier("v2.conversation.list")
                    .coordinateSpace(name: "v2.conversation.viewport")
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { store.viewport.resize(visibleBounds: $0) }
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
            .navigationBarTitleDisplayMode(.inline)
            .v2PageSurface()
            .safeAreaInset(edge: .top) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.body)
                        .foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("搜索会话", text: $conversationQuery, axis: .vertical)
                        .font(.body).foregroundStyle(.primary).lineLimit(1...3)
                        .submitLabel(.search)
                        .accessibilityIdentifier("v2.conversation.summary-search")
                    if !conversationQuery.isEmpty {
                        Button { conversationQuery = "" } label: {
                            Image(systemName: "xmark.circle.fill").font(.body)
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel("清除会话搜索")
                        .accessibilityIdentifier("v2.conversation.summary-search.clear")
                    }
                }
                .padding(12)
                .background(V2VisualStyle.surface, in: RoundedRectangle(cornerRadius: 16))
                .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(V2VisualStyle.separator) }
                .padding(.horizontal, 20).padding(.vertical, 8)
                .background(V2VisualStyle.canvas)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 4) {
                if let feedback = store.conversationRefreshFeedback {
                    Text(feedback).font(.footnote).foregroundStyle(.secondary).padding(.horizontal).padding(.vertical, 6).accessibilityIdentifier("v2.conversation.refresh-feedback")
                }
                if let feedback = store.conversationStateFeedback {
                    Text(feedback).font(.footnote).foregroundStyle(.secondary).padding(.horizontal).padding(.vertical, 6).accessibilityIdentifier("v2.conversation.state-feedback")
                }
                }
            }
            .onChange(of: rootNavigation.conversationAction) { _, action in
                guard let action else { return }
                rootNavigation.conversationAction = nil
                switch action {
                case .newDirect: newConversationSheet = .direct
                case .newGroup: newConversationSheet = .group
                case .search:
                    messageSearchStore = store.messageSearchStore()
                    isPresentingMessageSearch = messageSearchStore != nil
                case .favorites: isPresentingFavorites = true
                case .preferences: isPresentingPreferenceActivity = true
                }
            }
            .sheet(isPresented: $isPresentingPreferenceActivity, onDismiss: openConversationAfterSheetDismissal) {
                if let activity = store.preferenceActivity {
                    V2PreferenceActivityView(store: activity, roomTitles: Dictionary(store.items.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })) { roomID, messageID in
                        conversationAfterSheetDismissal = .init(roomID: roomID, messageID: messageID)
                        isPresentingPreferenceActivity = false
                    }
                }
            }
            .sheet(isPresented: $isPresentingFavorites, onDismiss: openConversationAfterSheetDismissal) {
                V2FavoriteMessagesSheet(store: store) { item in
                    conversationAfterSheetDismissal = .init(roomID: item.roomID, messageID: item.id)
                    isPresentingFavorites = false
                }
            }
            .task { await store.observeGroupCreation() }
            .task { await store.observeDirectConversationRequests() }
        .task { await store.observeProjectionChanges() }
            .sheet(isPresented: $isPresentingMessageSearch, onDismiss: {
                openConversationAfterSheetDismissal()
                messageSearchStore = nil
            }) {
                if let messageSearchStore {
                    NavigationStack {
                        V2MessageSearchView(store: messageSearchStore) { hit in
                            conversationAfterSheetDismissal = .init(roomID: hit.roomID.rawValue, messageID: hit.messageID.rawValue)
                            isPresentingMessageSearch = false
                        }
                    }
                }
            }
            .sheet(item: $newConversationSheet, onDismiss: openConversationAfterSheetDismissal) { sheet in
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
                    .v2GroupedPageSurface()
                    .navigationTitle("新建私聊")
                    .navigationBarTitleDisplayMode(.inline)
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
                                    if let destination = await store.openLocalFirstDirectConversation(handle: target), !Task.isCancelled {
                                        directSubmissionTask = nil
                                        directTargetUserID = ""
                                        if case .room(let route) = destination { rootNavigation.fixtureRoomID = route.roomID }
                                        conversationAfterSheetDismissal = destination
                                        newConversationSheet = nil
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
                            if userContext != nil {
                                Button("从好友中选择", systemImage: "person.2") { choosingGroupFriends = true }
                                    .sheet(isPresented: $choosingGroupFriends) {
                                        if let context = userContext {
                                            V2FriendPickerView(store: context.contacts) { handles in
                                                let existing = groupMemberUserIDs.components(separatedBy: CharacterSet(charactersIn: ",\n"))
                                                groupMemberUserIDs = Array(Set(existing.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } + handles)).sorted().joined(separator: ", ")
                                            }
                                        }
                                    }
                            }
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
                        if store.groupCreationNeedsConfirmation {
                            Button("继续核对建群结果") { Task { await store.resumePendingGroupCreation() } }
                        }
                        if let feedback = store.groupConversationFeedback {
                            Text(feedback)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("v2.conversation.group-feedback")
                        }
                    }
                    .v2GroupedPageSurface()
                    .navigationTitle("新建群聊")
                    .navigationBarTitleDisplayMode(.inline)
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
                                        rootNavigation.fixtureRoomID = roomID
                                        conversationAfterSheetDismissal = .init(roomID: roomID)
                                        newConversationSheet = nil
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

    private func openConversationAfterSheetDismissal() {
        guard let route = conversationAfterSheetDismissal else { return }
        conversationAfterSheetDismissal = nil
        rootNavigation.showConversation(route)
    }

    private var filteredConversations: [V2ConversationListItem] {
        let query = conversationQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.visibleItems }
        // Private identity strings remain in the expiring presentation pipeline.
        return store.visibleItems.filter {
            $0.preview.localizedStandardContains(query)
                || ($0.kind == .group && $0.title.localizedStandardContains(query))
        }
    }


}

extension V2AccountKind {
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

struct V2MessageSearchView: View {
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
                        if let failure = store.paginationFailure {
                            Label(failure == .invalidContinuation
                                  ? "后续结果暂不可用，请重新搜索。"
                                  : "未能加载更多，已保留当前结果。", systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("v2.message.search.pagination-error")
                            if failure == .invalidContinuation {
                                Button("重新搜索") { Task { await store.search() } }
                                    .accessibilityIdentifier("v2.message.search.restart")
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

struct V2FavoriteMessagesSheet: View {
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
            .navigationBarTitleDisplayMode(.inline)
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
        case groupReadReceipts(V2ConversationMessageItem)
        case edit(V2ConversationMessageItem)
        case forward
        case copyAttachments(V2ConversationMessageItem)
        case groupAnnouncement

        var id: String {
            switch self {
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
            }
        }
    }

    @Environment(\.v2UserInteractionContext) private var userContext
    @State private var userProfile: V2UserProfileTarget?
    @State private var peerActions: V2UserProfileActionStore?
    @State private var store: V2ConversationDetailStore
    @State private var presentedDetailSheet: PresentedDetailSheet?
    @State private var isPresentingAttachmentImporter = false
    @State private var isPresentingPhotoPicker = false
    @State private var isImportingPhotos = false
    @State private var photoSelectionLimit = 1
    @State private var focusedMessageID: String?
    @State private var showsMentionInput = false
    @State private var followsOwnSend = false
    @State private var timelinePresentation = V2MessageTimelinePresentation()
    @State private var timelinePosition = TiledScrollState<String>()
    @State private var initialBottomAnchor = V2MessageTimelineInitialBottomAnchor()
    private let groupInvitationStore: V2GroupInvitationStore?

    init(store: V2ConversationDetailStore, initiallyFocusedMessageID: String? = nil, groupInvitationStore: V2GroupInvitationStore? = nil) {
        _store = State(initialValue: store)
        _focusedMessageID = State(initialValue: initiallyFocusedMessageID)
        let opensAtLatest = initiallyFocusedMessageID == nil && !store.isBrowsingHistoricalTimeline
        _initialBottomAnchor = State(initialValue: .init(isActive: opensAtLatest))
        _timelinePosition = State(initialValue: .init(
            autoScrollsToBottomOnAppend: opensAtLatest, scrollsToBottomOnReplace: opensAtLatest))
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
                    if let peerActions, let key = store.presentationKey, peerActions.relationship != nil, peerActions.relationship != .friend {
                        HStack(spacing: 12) {
                            Text(peerActions.relationshipTitle).font(.footnote).foregroundStyle(.secondary)
                            Spacer()
                            Button(peerActions.relationship == .stranger ? "添加好友" : "查看资料") { userProfile = .init(key: key) }
                                .font(.footnote.weight(.semibold))
                                .accessibilityIdentifier("v2.chat.relationship-action")
                        }.padding(.horizontal).padding(.vertical, 10)
                            .background(V2VisualStyle.surface)
                            .accessibilityIdentifier("v2.chat.relationship-banner")
                    }
                    if store.readSyncNeedsAttention {
                        HStack {
                            Text("已读状态同步已暂停，本地阅读记录仍保留。")
                                .font(.footnote)
                            Button("继续同步") { Task { await store.resumeReadSync() } }
                                .disabled(store.isResumingReadSync)
                                .accessibilityIdentifier("v2.readSync.resume")
                        }.padding()
                    }
                    if store.readSyncArchiveCandidate != nil {
                        VStack(alignment: .leading) {
                            Text("当前无法核对原已读结果。归档仅停止跟踪，不表示成功或失败。")
                                .font(.footnote)
                            Button("归档本次核对") { Task { await store.archiveUnavailableReadSync() } }
                                .disabled(store.isResumingReadSync)
                        }.padding(.horizontal)
                    }
                    if !store.readSyncArchives.isEmpty {
                        DisclosureGroup("已归档的已读核对（\(store.readSyncArchives.count)）") {
                            ForEach(store.readSyncArchives) { archive in
                                VStack(alignment: .leading) {
                                    Text("已读状态暂未同步")

                                    Button("重试同步") {
                                        Task { await store.restoreReadSyncArchive(archive.id) }
                                    }.disabled(store.isResumingReadSync)
                                }.font(.footnote)
                            }
                        }.padding(.horizontal)
                    }
                    if let feedback = store.readSyncFeedback {
                        Text(feedback).font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                    }
                    ForEach(store.groupCapabilityPending,id:\.id) { pending in
                        HStack {
                            Text(groupCapabilityTitle(pending.intent.action))
                            if pending.work?.execution == .committed { Text("服务器已确认") }
                            else if pending.work?.execution == .closed { Text("服务器确认未执行") }
                            else if pending.work?.execution == .rejected || pending.work?.execution == .conflicted { Text("未执行，请刷新后重新操作") }
                            else if pending.work?.scheduling == .needsAttention {
                                Text("原操作结果待确认")
                                Button("重试") { Task { await store.continueGroupCapability(pending) } }
                            } else if pending.confirmationRequired {
                                Text("需要重新确认")
                                Button("查看并确认") { Task { await store.prepareGroupCapabilityReconfirmation(pending) } }
                            }
                            else { Text(pending.work==nil ? "正在准备操作" : "正在处理") }
                            if pending.work==nil { Button("取消确认") { Task { await store.discardGroupCapability(pending) } } }
                        }.font(.caption).padding(.horizontal)
                    }
                    ForEach(store.membershipPending,id:\.id) { pending in
                        HStack {
                            Text(pending.intent.action == .add ? "添加成员确认" : "移除成员确认")
                            if pending.work?.execution == .committed { Text("原操作已获服务器确认") }
                            else if pending.work?.execution == .closed { Text("服务器确认未执行") }
                            else if pending.work?.execution == .rejected || pending.work?.execution == .conflicted { Text("未获准执行，请刷新成员状态") }
                            else if pending.work?.scheduling == .needsAttention {
                                Text("原操作结果待确认")
                                Button("重试") { Task { await store.continueMembership(pending) } }
                            } else if pending.confirmationRequired {
                                Text("成员状态已变化，请重新确认")
                                Button("重新确认") { Task { await store.continueMembership(pending) } }
                            } else { Text(pending.work==nil ? "正在准备操作" : "正在处理") }
                            if pending.work==nil { Button("取消确认") { Task { await store.discardMembership(pending) } } }
                        }.font(.caption).padding(.horizontal)
                    }
                    ForEach(store.memberAdministrationPending,id:\.id) { pending in
                        HStack {
                            Text(pending.intent.action == .remove ? "成员移除" : "成员禁言")
                            if pending.work?.execution == .committed { Text("服务器已确认原操作结果") }
                            else if pending.work?.execution == .closed { Text("服务器确认未执行") }
                            else if pending.work?.execution == .rejected || pending.work?.execution == .conflicted { Text("未获准执行，请刷新成员状态") }
                            else if pending.work?.scheduling == .needsAttention {
                                Text("原操作结果待确认")
                                Button("重试") { Task { await store.continueMemberAdministration(pending) } }
                            } else if pending.confirmationRequired {
                                Text("确认窗口已结束或权限需重新核对")
                                Button("重新确认") { Task { await store.continueMemberAdministration(pending) } }
                            } else { Text(pending.work == nil ? "正在准备操作" : "正在处理") }
                            if pending.work==nil { Button("取消确认") { Task { await store.discardMemberAdministration(pending) } } }
                        }.font(.caption).padding(.horizontal)
                    }
                    ForEach(store.messageRemovalPending, id: \.work.id) { pending in
                        VStack(alignment: .leading) {
                            Text(store.messageRemovalStatus(pending)).font(.footnote)
                            if pending.work.scheduling == .needsAttention {
                                Button("继续核对原移除") { Task { await store.resumeMessageRemoval(pending.work.id) } }
                            }
                        }
                    }
                    ForEach(store.forwardPlans,id:\.work.id) { plan in
                        HStack {
                            Text("转发：\(plan.succeeded) 已接受，\(plan.rejected) 拒绝，\(plan.cancelled) 未启动取消，\(plan.unresolved) 待确认")
                            if plan.work.scheduling == .needsAttention {
                                Button("继续确认") { Task { await store.resumeForwardPlan(plan.work.id) } }
                            }
                            if !plan.work.execution.isTerminal && !plan.cancellationRequested {
                                Button("停止剩余") { Task { await store.cancelRemainingForwardPlan(plan.work.id) } }
                            }
                        }.font(.caption).padding(.horizontal).disabled(store.changingForwardPlanID != nil)
                    }
                    if let feedback=store.forwardSyncFeedback { Text(feedback).font(.caption).padding(.horizontal) }
                    ForEach(store.pendingReactions,id:\.intent.id) { pending in
                        HStack {
                            Text(pending.intent.reaction + (pending.intent.targetState == .present ? " 添加目标已保存" : " 移除目标已保存"))
                            if pending.expiredUnsubmitted { Text("尚未提交，已过期") }
                            else if pending.preparationPaused || pending.work?.scheduling == .needsAttention {
                                Button("继续确认") { Task { await store.resumeReactionIntent(pending.intent.id) } }
                            } else if pending.work?.execution == .conflicted { Text("反应版本已变化，请明确重新选择目标") }
                            else if pending.work?.execution == .rejected { Text("服务器拒绝了此目标") }
                            else if pending.work?.execution == .closed { Text("服务器确认未执行，可重新选择目标") }
                        }.font(.caption).padding(.horizontal)
                    }
                    if let feedback=store.reactionSyncFeedback { Text(feedback).font(.caption).padding(.horizontal) }
                    ForEach(store.messageMutations, id:\.work.id) { snapshot in
                        if snapshot.work.scheduling == .needsAttention {
                            HStack {
                                Text("消息修改结果仍待确认，原操作已保留。")
                                    .font(.footnote)
                                Button("继续确认") { Task { await store.resumeMessageMutation(snapshot.work.id) } }
                                    .disabled(store.resumingMutationID != nil)
                                    .accessibilityIdentifier("v2.messageMutation.resume.\(snapshot.work.id.uuidString)")
                            }.padding()
                        } else if snapshot.work.execution == .conflicted {
                            Text("消息已被更新，修改草稿已保留。请刷新当前消息后重新编辑。")
                                .font(.footnote).padding()
                        } else if snapshot.work.execution == .expiredUnsubmitted {
                            Text("消息修改尚未提交且已超过确认期限，请重新检查当前消息。")
                                .font(.footnote).padding()
                        }
                    }
                    if let feedback=store.mutationSyncFeedback {
                        Text(feedback).font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                    }

                    if store.isGroupConversation, let announcement = store.groupAnnouncement {
                        V2GroupAnnouncementBanner(announcement: announcement) {
                            presentedDetailSheet = .groupAnnouncement
                        }
                    }
                    if store.timeline.isEmpty && store.pendingResourceSends.isEmpty {
                        V2ConversationEmptyState(title: "暂无消息", symbol: "bubble", description: "发送第一条消息，开始会话。")
                    } else {
                        V2MessageTimelineEnvironment { environment in
                        VStack(spacing: 0) {
                            TiledView(dataSource: timelinePresentation.dataSource, scrollPosition: $timelinePosition) { item in
                                Group {
                                        switch item {
                                        case .committed(.message(let message, _)):
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
                                        case .committed(.activity(let activity)):
                                            V2ConversationTimelineActivityRow(activity: activity)
                                        case .pending(let pending):
                                            V2PendingMessageRow(pending: pending,
                                                retry: { Task { await store.retryResourceSend(pending.id) } },
                                                cancel: { Task { await store.cancelResourceSend(pending.id) } },
                                                borrowImage: { try await store.borrowPendingImage(jobID: $0) })
                                            }
                                }
                                .modifier(V2MessageTimelineInheritedEnvironment(source: environment))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                            }
                            .headerContent(.header {
                                VStack(spacing: 8) {
                                    if store.pendingResourceSendPage > 0 {
                                        Button("较新的待处理发送") { store.previousPendingResourceSendPage() }
                                    }
                                    if store.hasNextPendingResourceSendPage {
                                        Button("查看更多待处理发送") { store.nextPendingResourceSendPage() }
                                    }
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
                                }.modifier(V2MessageTimelineInheritedEnvironment(source: environment)).padding(.horizontal, 16)
                            })
                            .onTiledScrollGeometryChange { geometry in
                                if store.isBrowsingHistoricalTimeline || focusedMessageID != nil {
                                    initialBottomAnchor.release()
                                }
                                if initialBottomAnchor.needsCorrection(.init(
                                    contentSize: geometry.contentSize, visibleSize: geometry.visibleSize,
                                    bottomInset: geometry.contentInset.bottom, pointsFromBottom: geometry.pointsFromBottom
                                ), hasItems: !timelinePresentation.dataSource.items.isEmpty) {
                                    // Correct against the actual content edge after sizing,
                                    // not a last-row frame captured before the final layout.
                                    timelinePosition.scrollTo(edge: .bottom, animated: false)
                                }
                                // Follow both incoming and outgoing messages only while
                                // reading the tail. Browsing history keeps its anchor.
                                timelinePosition.autoScrollsToBottomOnAppend = (initialBottomAnchor.isActive || geometry.pointsFromBottom < 80)
                                    && !store.isBrowsingHistoricalTimeline && focusedMessageID == nil
                            }
                            .onTiledUserScrollInput {
                                initialBottomAnchor.release()
                                focusedMessageID = nil
                                followsOwnSend = false
                            }
                            .onScrollFailure { _ in focusedMessageID = nil }
                            .onChange(of: V2MessageTimelinePresentation.Snapshot(
                                timeline: store.timeline, pending: store.pendingResourceSends
                            ), initial: true) { _, snapshot in
                                let wasEmpty = timelinePresentation.dataSource.items.isEmpty
                                let wasFollowingLatest = timelinePosition.autoScrollsToBottomOnAppend
                                    && !store.isBrowsingHistoricalTimeline
                                guard timelinePresentation.apply(snapshot.timeline, pending: snapshot.pending) else { return }
                                if focusedMessageID != nil { scrollToFocusedMessage() }
                                else if wasEmpty || followsOwnSend || wasFollowingLatest {
                                    scrollToLatestMessage()
                                }
                            }
                            .onChange(of: focusedMessageID) { _, messageID in
                                if messageID != nil {
                                    initialBottomAnchor.release()
                                    followsOwnSend = false
                                }
                                scrollToFocusedMessage()
                            }
                            .accessibilityIdentifier("v2.message.list")
                            if timelinePresentation.hasInvalidSnapshot {
                                Text("消息列表暂时无法更新，请刷新重试。")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                                    if store.isBrowsingHistoricalTimeline {
                                        Button {
                                            Task {
                                                await store.returnToLatestTimeline()
                                                if !store.isBrowsingHistoricalTimeline, timelinePresentation.apply(store.timeline, pending: store.pendingResourceSends) {
                                                    scrollToLatestMessage()
                                                }
                                            }
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
                        }
                    }
                    if !store.attachments.isEmpty {
                        ScrollView(.horizontal) {
                            HStack(spacing: 10) {
                                ForEach(store.attachments) { attachment in
                                    V2ConversationAttachmentRow(store: store, attachment: attachment)
                                        .frame(width: 240)
                                        .padding(8)
                                        .background(V2VisualStyle.surface, in: RoundedRectangle(cornerRadius: 12))
                                }
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .accessibilityIdentifier("v2.message.attachments")
                    }
                    if store.isGroupConversation && (showsMentionInput || !store.mentionHandlesText.isEmpty) {
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
                    GlassEffectContainer(spacing: 12) {
                        HStack(alignment: .bottom, spacing: 12) {
                            Menu {
                                Button("照片", systemImage: "photo.on.rectangle") {
                                    photoSelectionLimit = V2MessageCommandLimits.maxMediaAttachments - store.attachments.count
                                    isPresentingPhotoPicker = true
                                }
                                .disabled(!store.canAddAttachment || store.directAccountKind == .system || isImportingPhotos)
                                .accessibilityIdentifier("v2.message.photo.add")
                                Button("文件", systemImage: "paperclip") {
                                    isPresentingAttachmentImporter = true
                                }
                                .disabled(!store.canAddAttachment || store.directAccountKind == .system || isImportingPhotos)
                                .accessibilityIdentifier("v2.message.attachment.add")
                                if store.isGroupConversation {
                                    Button(showsMentionInput ? "收起提及" : "提及成员", systemImage: "at") {
                                        showsMentionInput.toggle()
                                    }
                                    .accessibilityIdentifier("v2.message.mentions.toggle")
                                }
                            } label: {
                                if isImportingPhotos {
                                    ProgressView().frame(width: 44, height: 44)
                                        .accessibilityLabel("正在准备图片")
                                } else {
                                    Image(systemName: "plus")
                                        .font(.system(size: 18, weight: .medium))
                                        .foregroundStyle(.primary)
                                        .frame(width: 32, height: 32)
                                        .background(Color.secondary.opacity(0.08), in: Circle())
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("消息附件与提及")
                            .accessibilityIdentifier("v2.message.composer.options")

                            HStack(alignment: .bottom, spacing: 8) {
                                V2ComposerTextInput(
                                    text: $store.draft,
                                    placeholder: "发送消息…",
                                    accessibilityLabel: "消息内容",
                                    accessibilityHint: "输入要发送的消息"
                                )
                                .disabled(store.isSending || store.canSendInDirectConversation == false || store.directAccountKind == .system)
                                .onChange(of: store.draft) { _, _ in store.updateTypingForDraft() }
                                .accessibilityIdentifier("v2.message.draft")
                                if store.isSending {
                                    ProgressView()
                                        .frame(width: 36, height: 36)
                                        .accessibilityLabel("正在保存消息")
                                } else {
                                    Button {
                                        focusedMessageID = nil
                                        followsOwnSend = true
                                        Task {
                                            await store.sendDraft()
                                            if !store.draft.isEmpty {
                                                followsOwnSend = false
                                            }
                                        }
                                    } label: {
                                        Image(systemName: "arrow.up")
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(.white)
                                            .frame(width: 36, height: 36)
                                            .background(canSendDraft ? V2VisualStyle.outgoing : Color.secondary, in: Circle())
                                            .padding(4)
                                            .contentShape(Circle())
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(!canSendDraft)
                                    .accessibilityLabel("发送")
                                    .accessibilityIdentifier("v2.message.send")
                                }
                            }
                            .padding(.leading, 14)
                            .padding(.trailing, 2)
                            .padding(.vertical, 2)
                            .background(V2VisualStyle.surface, in: RoundedRectangle(cornerRadius: 24))
                            .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(V2VisualStyle.separator) }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    if !store.isGroupConversation, store.canSendInDirectConversation == false || store.directAccountKind == .system {
                        Text(store.directAccountKind == .system ? "此系统账号仅用于发送通知" : "当前无法向此会话发送消息")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                            .padding(.bottom, 8)
                            .accessibilityIdentifier("v2.message.sending-restricted")
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
        .v2PageSurface()
        .navigationTitle(store.isGroupConversation ? store.title : "会话")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let key = store.presentationKey {
                ToolbarItem(placement: .principal) {
                    Button { userProfile = .init(key: key) } label: {
                        HStack(spacing: 8) {
                            V2AuthorizedAvatarView(key: key, size: 32)
                            VStack(alignment: .leading, spacing: 1) {
                                V2AuthorizedProfileNameView(key: key).font(.headline).lineLimit(1)
                                headerActivity
                            }
                        }
                    }.buttonStyle(.plain).accessibilityLabel("查看对方资料").accessibilityValue(headerActivityText ?? "").accessibilityIdentifier("v2.chat.peer-profile")
                }
            } else if store.isGroupConversation, let room = try? RoomID(store.roomID) {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        V2AuthorizedGroupAvatarView(roomID: room, size: 32, fallbackTitle: store.title)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(store.title).font(.headline).lineLimit(1)
                            headerActivity
                        }
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar { conversationToolbar }
        .sheet(item: $presentedDetailSheet) { sheet in
            switch sheet {
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
            }
        }
        .v2UserProfileSheet(item: $userProfile)
        .task(id: store.presentationKey) {
            guard let key = store.presentationKey else { return }
            peerActions = userContext?.contacts.profileActions(for: key.userID)
            await peerActions?.run()
        }
        .fileImporter(
            isPresented: $isPresentingAttachmentImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await store.stageAttachment(from: url) }
        }
        .v2PhotoLibraryPicker(isPresented: $isPresentingPhotoPicker, isImporting: $isImportingPhotos,
                              maximumSelectionCount: photoSelectionLimit) { photo in
            await store.stageAttachment(photo: photo)
        }
        .task { await store.observeProjectionChanges() }
        .task { await store.pollVisibleHybridGroupEvents() }
        .authorPresentationPage(context: store.authorPresentationContext)
        .task(id: store.trackedSendIntentID) { await store.observeSendConfirmation() }
        .task(id: store.pendingResourceSendPage) { await store.observeResourceSends() }
        .task { await store.observeReadSync() }
        .task { await store.observeMessageMutations() }
        .task { await store.observeReactionIntents() }
        .task { await store.observeMessageRemoval() }
        .task {
            await store.loadGroupMembers()
            guard !Task.isCancelled else { return }
            await store.loadGroupRolePolicies()
        }
        .onDisappear { store.endMessageRemovalPage() }
        .task(id: store.messageRemovalProposal?.expires) {
            guard let expires = store.messageRemovalProposal?.expires else { return }
            do { try await Task.sleep(until: expires, clock: .continuous) }
            catch { return }
            if store.messageRemovalProposal?.expires == expires { store.messageRemovalProposal = nil }
        }
        .confirmationDialog("管理移除这条消息？", isPresented: Binding(
            get: { store.messageRemovalProposal != nil },
            set: { if !$0 { store.messageRemovalProposal = nil } }), titleVisibility: .visible, presenting: store.messageRemovalProposal) { proposal in
            Button("移除消息", role: .destructive) {
                Task { await store.confirmMessageRemoval(proposal) }
            }
            Button("取消", role: .cancel) { store.messageRemovalProposal = nil }
        } message: { _ in Text("此操作将对所有成员移除消息。状态或权限变化时，服务器会拒绝原确认。") }

        .confirmationDialog(store.pendingPinBaseline?.isPinned == true ? "取消置顶这条消息？" : "置顶这条消息？", isPresented:Binding(get:{store.pendingPinBaseline != nil},set:{if !$0 {store.pendingPinBaseline=nil}}),titleVisibility:.visible) {
            Button(store.pendingPinBaseline?.isPinned == true ? "取消置顶" : "置顶") { if let baseline=store.pendingPinBaseline { Task { await store.confirmPinInGroup(baseline) } } }
            Button("取消",role:.cancel) { store.pendingPinBaseline=nil }
        }
        .sheet(item:$store.groupCapabilityReconfirmation) { proposal in
            NavigationStack {
                Form {
                    Section("重新确认群操作") {
                        Text(groupCapabilityTitle(proposal.action))
                        switch proposal.action {
                        case .pin(_,let desired,_): Text(desired ? "将这条消息置顶" : "取消这条消息的置顶")
                        case .announcement(let body,_): Text(body)
                        case .rolePermissions(let role,let permissions,_):
                            Text(role == .admin ? "角色：管理员" : "角色：普通成员")
                            Text(permissions.isEmpty ? "不授予上述群权限" : permissions.map(\.title).sorted().joined(separator:"、"))
                        case .memberRole(_,let role,_): Text(role == .admin ? "将原目标成员设为管理员" : "将原目标成员设为普通成员")
                        }
                        Text("请确认操作内容，提交后将在后台处理。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("确认提交") { Task { await store.confirmGroupCapability(proposal) } }
                    Button("返回",role:.cancel) { store.groupCapabilityReconfirmation=nil }
                }.navigationTitle("确认群操作")
            }
        }
        .task { await store.observeGroupCapabilities() }
        .task { await store.observeMembership() }
        .task { await store.observeMemberAdministration() }
        .task { await store.observeForwardPlans() }
        .task { await store.observeLiveActivity() }
        .task(id: focusedMessageID) {
            guard let focusedMessageID else { return }
            await store.loadTimeline(containing: focusedMessageID)
        }
    }

    private func groupCapabilityTitle(_ action:V2GroupCapabilityAction) -> String {
        switch action {
        case .pin: "消息置顶"
        case .announcement: "群公告"
        case .rolePermissions: "群权限"
        case .memberRole: "成员角色"
        }
    }

    private var headerActivityText: String? {
        if !store.typingUserIDs.isEmpty {
            if store.isGroupConversation {
                return store.typingUserIDs.count == 1 ? "有人正在输入…" : "多位成员正在输入…"
            }
            return "对方正在输入…"
        }
        guard !store.isGroupConversation, let presence = store.peerPresence else { return nil }
        return presence.isOnline ? "在线" : "离线"
    }

    @ViewBuilder
    private var headerActivity: some View {
        if let text = headerActivityText {
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityLabel(store.isGroupConversation ? "会话状态" : "对方状态")
                .accessibilityValue(text)
                .accessibilityIdentifier(store.typingUserIDs.isEmpty ? "v2.conversation.presence" : "v2.conversation.typing")
        }
    }

    private var canSendDraft: Bool {
        !store.isSending
            && !isImportingPhotos
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
                Button("转发 \(store.selectedForwardMessageIDs.count)") { presentedDetailSheet = .forward }
                    .disabled(store.selectedForwardMessageIDs.isEmpty)
                    .accessibilityIdentifier("v2.message.forward.selected")
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    V2ConversationSettingsView(store: store, groupInvitationStore: groupInvitationStore,
                        focusMessage: { focusedMessageID = $0 })
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("会话设置")
                .accessibilityIdentifier("v2.conversation.detail.tools")
            }
        }
    }


    private func scrollToLatestMessage() {
        guard let id = timelinePresentation.dataSource.items.last?.id else { return }
        // Use one stable tail identity for both pending and confirmed rows.
        // MessagingUI defers this command until its snapshot queue settles.
        timelinePosition.scrollTo(id: id, anchor: .bottom, animated: false)
    }

    private func scrollToFocusedMessage() {
        guard let focusedMessageID,
              let target = store.timeline.first(where: { item in
                  guard case .message(let message, _) = item else { return false }
                  return message.id == focusedMessageID
              }) else { return }
        timelinePosition.scrollTo(id: target.id, anchor: .centered)
    }
}

/// 使用可滚动编辑器，避免消息输入框在辅助功能动态字体尺寸下
/// 因 UIKit 文本框固定高度而被裁剪。
struct V2ComposerTextInput: View {
    @Binding var text: String
    let placeholder: String
    let accessibilityLabel: String
    let accessibilityHint: String

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .font(.body)
            .lineLimit(1...5)
            .padding(.vertical, 9)

            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(accessibilityHint)
    }
}

private struct V2ConversationAttachmentRow: View {
    @Bindable var store: V2ConversationDetailStore
    let attachment: V2ConversationAttachmentItem
    @State private var preview: UIImage?

    var body: some View {
        let removalLabel = "移除附件 " + attachment.displayName
        let removeIdentifier = "v2.message.attachment.remove." + attachment.id.uuidString
        HStack(spacing: 8) {
            if let preview {
                Image(uiImage: preview).resizable().scaledToFill()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
            } else {
                Image(systemName: attachmentIcon(for: attachment.state))
                    .foregroundStyle(attachmentColor(for: attachment.state))
                    .accessibilityHidden(true)
            }
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
        .task(id: attachment.id) {
            guard attachment.attachment.contentType.hasPrefix("image/") else { return }
            do {
                let lease = try await store.borrowAttachment(id: attachment.id)
                let result = await V2PhotoLibraryImage.preview(at: lease.fileURL)
                await lease.release()
                guard !Task.isCancelled else { return }
                preview = result?.image
            } catch { preview = nil }
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
        case .staged: "已添加，发送时上传"
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
    @State private var userProfile: V2UserProfileTarget?
    @Bindable var store: V2ConversationDetailStore
    let message: V2ConversationMessageItem
    let beginEditing: () -> Void
    let showReadReceipts: () -> Void
    let beginForward: () -> Void
    let beginCopyAttachments: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            if message.isOutgoing { Spacer(minLength: 56) }
            if !message.isOutgoing, let key = store.authorPresentationKey(for: message) {
                Button { userProfile = .init(key: key) } label: {
                    V2AuthorizedAvatarView(key: key, size: 32)
                        .frame(minWidth: 44, minHeight: 44)
                }.buttonStyle(.plain).accessibilityLabel("查看发送者资料")
                    .accessibilityIdentifier("v2.message.author-profile.\(message.id)")
            }
            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
                if !message.isOutgoing, store.isGroupConversation, let key = store.authorPresentationKey(for: message) {
                    V2AuthorizedProfileNameView(key: key)
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.leading, 12)
                }
                V2ConversationMessageBubble(store: store, message: message, beginEditing: beginEditing, showReadReceipts: showReadReceipts, beginForward: beginForward, beginCopyAttachments: beginCopyAttachments)
            }
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
        .v2UserProfileSheet(item: $userProfile)
        .onAppear { Task { await store.reportVisibleMessage(message) } }
        // VoiceOver message operations belong to the whole row, whose target
        // includes the complete bubble and surrounding touch area. Attaching
        // them to the bubble lets a one-character Text inherit actionable
        // semantics with an unusably small hit region.
        .modifier(V2MessageAccessibilityActions(
            canEdit: store.canEditMessage(message),
            canWithdraw: store.canWithdrawMessage(message),
            canUseMessageMenu: !message.isWithdrawn,
            isFavorited: message.isFavorited,
            reply: { store.beginReply(to: message) },
            forward: beginForward,
            setFavorite: { desired in Task { await store.setFavorite(message, desired: desired) } },
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
        VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 5) {
            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 3) {
                if message.isFavorited {
                    Label("已收藏", systemImage: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(message.isOutgoing && !message.isWithdrawn ? Color.white : Color.secondary)
                        .accessibilityLabel("已收藏")
                        .accessibilityIdentifier("v2.message.favorite.indicator.\(message.id)")
                }
                if let replyTo = message.replyTo {
                    Label(store.replyPreview(for: replyTo), systemImage: "arrowshape.turn.up.left")
                        .font(.caption)
                        .foregroundStyle(message.isOutgoing && !message.isWithdrawn ? Color.white : Color.secondary)
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
                            .foregroundStyle(message.isOutgoing && !message.isWithdrawn ? Color.white : Color.primary)
                            .accessibilityHidden(true)
                    }
                    // Do not let a short Text view become the accessible node:
                    // the wrapper is the message body and owns a full target.
                    .frame(minWidth: 44, minHeight: 44, alignment: message.isOutgoing ? .trailing : .leading)
                    .accessibilityElement()
                    .accessibilityLabel(message.text)
                    .accessibilityValue(Text(message.createdAt, format: .dateTime.hour().minute()))
                    .accessibilityIdentifier("v2.message.body.\(message.id)")
                }
                if !message.mentions.isEmpty {
                    Text(mentionSummary)
                        .font(.caption)
                        .foregroundStyle(message.isOutgoing && !message.isWithdrawn ? Color.white : Color.secondary)
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
                    .accessibilityLabel("消息附件")
                    .accessibilityValue(message.text.isEmpty
                        ? attachmentSummary + ", " + message.createdAt.formatted(.dateTime.hour().minute())
                        : attachmentSummary)
                    .accessibilityIdentifier("v2.message.attachments.\(message.id)")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                message.isOutgoing && !message.isWithdrawn ? V2VisualStyle.outgoing : V2VisualStyle.incoming,
                in: UnevenRoundedRectangle(topLeadingRadius: message.isOutgoing ? 19 : 5,
                    bottomLeadingRadius: 19, bottomTrailingRadius: 19, topTrailingRadius: message.isOutgoing ? 5 : 19)
            )
            .contextMenu { messageActions }
            // The message body (or attachment summary) announces this time.
            // Keep one readable message target instead of a second tiny node.
            Text(message.createdAt, format: .dateTime.hour().minute())
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .accessibilityHidden(true)
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
            if !message.reactions.isEmpty {
                V2ConversationReactionControls(store: store, message: message)
            }
        }
    }

    @ViewBuilder
    private var messageActions: some View {
        if !message.isWithdrawn {
            Button("回复", systemImage: "arrowshape.turn.up.left") { store.beginReply(to: message) }
                .accessibilityIdentifier("v2.message.reply.\(message.id)")
        }
        if store.canReactToMessage(message) {
            V2ReactionPickerMenu(store: store, message: message)
        }
        if message.isOutgoing && store.isGroupConversation && !message.isWithdrawn {
            Button("查看已读", systemImage: "checkmark.message") { showReadReceipts() }
                .accessibilityIdentifier("v2.message.group-readers.\(message.id)")
        }
        if !message.isWithdrawn {
            Button("转发", systemImage: "arrowshape.turn.up.right") { beginForward() }
                .accessibilityIdentifier("v2.message.forward.\(message.id)")
            if !message.media.isEmpty {
                Button("复制附件到会话", systemImage: "doc.on.doc", action: beginCopyAttachments)
            }
        }
        if store.canEditMessage(message) {
            Button("编辑", systemImage: "pencil") { beginEditing() }
                .accessibilityIdentifier("v2.message.edit.\(message.id)")
        }
        if store.canWithdrawMessage(message) {
            Button("撤回", systemImage: "arrow.uturn.backward", role: .destructive) {
                Task { await store.withdrawMessage(message) }
            }
            .disabled(!store.canWithdrawMessage(message))
            .accessibilityValue(store.isMessageActionInFlight(message) ? "正在保存消息操作" : "")
            .accessibilityIdentifier("v2.message.withdraw.\(message.id)")
        }
        if !message.isWithdrawn {
            Menu("收藏设置", systemImage: "star") {
                Button("设为收藏") { Task { await store.setFavorite(message, desired: true) } }
                Button("取消收藏") { Task { await store.setFavorite(message, desired: false) } }
            }
            .accessibilityIdentifier("v2.message.favorite.\(message.id)")
            if store.canManageMessages && !message.isWithdrawn {
                Button("管理移除消息", systemImage: "trash", role: .destructive) {
                    Task { await store.prepareMessageRemoval(message) }
                }
                .accessibilityIdentifier("v2.group.message.remove.\(message.id)")
            }
            if store.isGroupConversation {
                Button(message.isPinnedInGroup ? "取消置顶消息" : "置顶消息", systemImage: message.isPinnedInGroup ? "pin.slash" : "pin") { Task { await store.pinInGroup(message) } }
                    .accessibilityIdentifier("v2.group.message.pin.\(message.id)")
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
    let canUseMessageMenu: Bool
    let isFavorited: Bool
    let reply: () -> Void
    let forward: () -> Void
    let setFavorite: (Bool) -> Void
    let edit: () -> Void
    let withdraw: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        Group {
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
        .modifier(V2MessageMenuAccessibilityActions(
            isAvailable: canUseMessageMenu,
            isFavorited: isFavorited,
            reply: reply,
            forward: forward,
            setFavorite: setFavorite
        ))
    }
}

private struct V2MessageMenuAccessibilityActions: ViewModifier {
    let isAvailable: Bool
    let isFavorited: Bool
    let reply: () -> Void
    let forward: () -> Void
    let setFavorite: (Bool) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isAvailable {
            content
                .accessibilityAction(named: "回复消息") { reply() }
                .accessibilityAction(named: "转发消息") { forward() }
                .accessibilityAction(named: isFavorited ? "取消收藏" : "设为收藏") { setFavorite(!isFavorited) }
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
            .navigationBarTitleDisplayMode(.inline)
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
            .navigationBarTitleDisplayMode(.inline)
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
            .navigationBarTitleDisplayMode(.inline)
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
                Menu {
                    Button("添加我的反应") { Task { await store.changeReaction(reaction.reaction,on:message,action:.add) } }
                    Button("移除我的反应") { Task { await store.changeReaction(reaction.reaction,on:message,action:.remove) } }
                } label: {
                    Text("\(reaction.reaction) \(reaction.count)")
                }
                .buttonStyle(.bordered)
                .tint(reaction.includesCurrentUser ? .accentColor : .secondary)
                .frame(minWidth: 44, minHeight: 44)
                .disabled(!store.canReactToMessage(message))
                .accessibilityLabel(reaction.reaction + " 表情反应")
                .accessibilityValue(reactionAccessibilityValue(reaction))
                .accessibilityHint("选择添加或移除自己的反应")
                .accessibilityIdentifier("v2.message.reaction.\(message.id).\(reaction.reaction)")
            }

        }
    }

    private func reactionAccessibilityValue(_ reaction: V2ConversationMessageReaction) -> String {
        if reaction.includesCurrentUser {
            return "\(reaction.count) 人已添加，包括你"
        }
        return "\(reaction.count) 人已添加，不包括你"
    }
}

private struct V2ReactionPickerMenu: View {
    let store: V2ConversationDetailStore
    let message: V2ConversationMessageItem
    var body: some View {
        Menu("表情回应", systemImage: "face.smiling") {
            ForEach(store.reactionPresets, id: \.self) { reaction in
                Button(reaction) {
                    let includesCurrentUser = message.reactions.contains { $0.reaction == reaction && $0.includesCurrentUser }
                    Task { await store.changeReaction(reaction, on: message, action: includesCurrentUser ? .remove : .add) }
                }
                .accessibilityIdentifier("v2.message.reaction-picker.\(message.id).\(reaction)")
            }
        }
        .accessibilityIdentifier("v2.message.reaction-picker.\(message.id)")
    }
}
