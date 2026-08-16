import Foundation
import IMV2ClientKit
import IMV2Core
import Observation
import SwiftUI
import UIKit
import AVKit
import UniformTypeIdentifiers

/// App-facing, value-only view data. The UI never reads SQLite rows or sync
/// event payloads directly, which keeps navigation and rendering testable.
enum V2ConversationKind: Hashable, Sendable {
    /// A direct room with an authorized, bounded public-identity projection.
    case direct(accountKind: V2AccountKind)
    /// A group room with a compact room-profile projection.
    case group
    /// A message arrived before its corresponding room projection. Keep it
    /// readable, but do not invent a direct-account classification for it.
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

    let id: String
    let title: String
    let preview: String
    let lastActivity: Date
    let isOutgoing: Bool
    let kind: V2ConversationKind
    let isPinned: Bool
    let isArchived: Bool
    let muteUntil: Date?

    init(id: String, title: String, preview: String, lastActivity: Date, isOutgoing: Bool, kind: V2ConversationKind, isPinned: Bool = false, isArchived: Bool = false, muteUntil: Date? = nil) {
        self.id = id
        self.title = title
        self.preview = preview
        self.lastActivity = lastActivity
        self.isOutgoing = isOutgoing
        self.kind = kind
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.muteUntil = muteUntil
    }
}

/// A value-only destination shown in the forward picker.  The user sees a
/// title, while the opaque ID remains confined to the Store boundary.
struct V2ConversationForwardTarget: Hashable, Identifiable, Sendable {
    let roomID: String
    let title: String

    var id: String { roomID }
}

struct V2ConversationMessageItem: Hashable, Identifiable, Sendable {
    let id: String
    let roomSequence: UInt64
    let revision: UInt64
    let text: String
    /// Opaque media IDs from the local projection. The UI may show that a
    /// message has attachments, but never receives a provider URL here.
    let media: [V2MediaReference]
    /// Server-derived, non-sensitive presentation facts for `media`. These
    /// let the view choose image/file affordances without reading object-store
    /// metadata or assuming a provider URL.
    let mediaPresentations: [V2MediaPresentation]
    /// Protocol-level mention targets. IDs are kept opaque in the UI; the
    /// message bubble exposes only aggregate mention semantics.
    let mentions: [V2MentionTarget]
    let entities: [V2MessageEntity]
    let replyTo: V2MessageReplyReference?
    let createdAt: Date
    let isOutgoing: Bool
    /// Direct-room state projected from the counterpart's durable receipt.
    /// Group details are deliberately queried on demand and do not populate
    /// every row during normal timeline rendering.
    let isReadByPeer: Bool
    let isWithdrawn: Bool
    let isFavorited: Bool
    let isPinnedInGroup: Bool
    let isForwarded: Bool
    let reactions: [V2ConversationMessageReaction]

    init(id: String, roomSequence: UInt64 = 1, revision: UInt64, text: String, media: [V2MediaReference] = [], mediaPresentations: [V2MediaPresentation] = [], mentions: [V2MentionTarget] = [], entities: [V2MessageEntity] = [], replyTo: V2MessageReplyReference? = nil, createdAt: Date, isOutgoing: Bool, isWithdrawn: Bool, reactions: [V2ConversationMessageReaction] = [], isReadByPeer: Bool = false, isFavorited: Bool = false, isPinnedInGroup: Bool = false, isForwarded: Bool = false) {
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

/// Render-only union for the conversation stream. Keeping activity separate
/// from `V2ConversationMessageItem` prevents a local system notice from
/// accidentally becoming replyable, forwardable or read-receipt eligible.
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
}

struct V2ConversationTimelinePage: Equatable, Sendable {
    let items: [V2ConversationTimelineItem]
    let olderCursor: V2ConversationTimelineCursor?
}

/// A compact, cross-conversation entry for the personal Favorites screen.
/// IDs remain navigation keys; presentation strings have already been
/// resolved at the data-source boundary.
struct V2FavoriteConversationMessageItem: Hashable, Identifiable, Sendable {
    let id: String
    let roomID: String
    let roomTitle: String
    let text: String
    let createdAt: Date
}

/// A display-only aggregate. Individual reactor IDs stay in the local
/// projection boundary; the message bubble exposes only count and whether the
/// signed-in user currently belongs to that reaction set.
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

protocol V2ConversationDataSource: Sendable {
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

protocol V2ConversationSendingCapabilityReading: Sendable {
    /// `nil` means no server decision has been projected yet, so the composer
    /// remains usable and the authoritative send command is still the gate.
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

protocol V2GroupRolePolicyReading: Sendable {
    func groupRolePolicies(in roomID: String) async throws -> [V2ClientGroupRolePolicy]
}

/// Keeps the FTS/GRDB boundary out of the SwiftUI search state in the same way
/// the conversation data source keeps message projections out of views.
protocol V2ConversationMessageSearching: Sendable {
    func searchMessages(_ request: V2MessageSearchRequest) async throws -> V2MessageSearchPage
}

protocol V2ConversationMessageSearchProgressReading: Sendable {
    func messageSearchIndexProgress() async throws -> V2MessageSearchIndexProgress
}

/// A foreground-only boundary for the currently open hybrid room. It is not a
/// member notification channel: only the device that is displaying a room
/// polls it, and every returned event still commits through the durable local
/// cursor before SwiftUI is refreshed.
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
}

protocol V2ActiveHybridGroupSynchronizing: Sendable {
    func synchronizeOnePage(roomID: String) async throws -> V2ActiveHybridGroupSyncOutcome
    func subscribe(roomID: String) async throws -> V2ActiveHybridGroupSubscriptionOutcome
    func nextWake() async throws -> V2ActiveHybridGroupWake
    func unsubscribe(roomID: String) async
}

/// Bridges durable sync completion to UI stores without exposing transport
/// payloads or database rows to SwiftUI. Subscribers first receive the
/// current generation, then each later completed sync generation.
actor V2ProjectionChangeNotifier {
    private var generation: UInt64 = 0
    private var continuations: [UUID: AsyncStream<UInt64>.Continuation] = [:]

    func updates() -> AsyncStream<UInt64> {
        let identifier = UUID()
        let (stream, continuation) = AsyncStream<UInt64>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        continuations[identifier] = continuation
        continuation.yield(generation)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(identifier) }
        }
        return stream
    }

    func publish() {
        generation &+= 1
        for continuation in continuations.values {
            continuation.yield(generation)
        }
    }

    private func removeContinuation(_ identifier: UUID) {
        continuations.removeValue(forKey: identifier)
    }
}

@MainActor
@Observable
final class V2ConversationListStore {
    enum State: Equatable {
        case loading
        case loaded
        case failed
    }

    private let environment: V2ConversationFeatureEnvironment
    private let dataSource: any V2ConversationDataSource
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
    private(set) var isLoadingMoreConversations = false
    /// Inbox and archive are distinct views over the same durable projection;
    /// archiving must not merely demote an item to the bottom of the inbox.
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
    private var refreshGeneration = 0

    init(environment: V2ConversationFeatureEnvironment) {
        self.environment = environment
        dataSource = environment.projections.dataSource
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

    func refresh() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        state = .loading
        do {
            let page = try await dataSource.conversationSummaryPage(
                for: userID,
                isArchived: isShowingArchived,
                before: nil,
                limit: 50
            )
            try Task.checkCancellation()
            guard generation == refreshGeneration else { return }
            items = page.items
            conversationNextCursor = page.nextCursor
            state = .loaded
            await restoreDurableGroupCreationStatusIfNeeded()
        } catch is CancellationError {
            return
        } catch {
            guard generation == refreshGeneration else { return }
            state = .failed
        }
    }

    func toggleArchivedConversations() async {
        isShowingArchived.toggle()
        await refresh()
    }

    func loadMoreConversations() async {
        guard state == .loaded,
              let cursor = conversationNextCursor,
              !isLoadingMoreConversations
        else { return }
        let generation = refreshGeneration
        let archived = isShowingArchived
        isLoadingMoreConversations = true
        defer { isLoadingMoreConversations = false }
        do {
            let page = try await dataSource.conversationSummaryPage(
                for: userID,
                isArchived: archived,
                before: cursor,
                limit: 50
            )
            try Task.checkCancellation()
            guard generation == refreshGeneration, archived == isShowingArchived else { return }
            let existingIDs = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter { !existingIDs.contains($0.id) })
            conversationNextCursor = page.nextCursor
        } catch is CancellationError {
            return
        } catch {
            conversationStateFeedback = "无法加载更多会话。"
        }
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
        do {
            switch try await groupConversationCreator.restoredCreationStatus() {
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
            .map { V2ConversationForwardTarget(roomID: $0.id, title: $0.title) }
        return .init(
            environment: environment,
            context: .init(
                roomID: roomID,
                title: title,
                kind: kind,
                forwardTargets: forwardTargets,
                initialDraft: initialDraft,
                initialMentionHandles: initialMentionHandles
            )
        )
    }

    func messageSearchStore() -> V2ConversationSearchStore? {
        guard let messageSearcher else { return nil }
        return .init(searcher: messageSearcher)
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
        rootNavigation: V2RootNavigationStore? = nil
    ) {
        self.store = store
        self.localE2EConversationLaunchFixture = localE2EConversationLaunchFixture
        self.accountMenu = accountMenu
        self.rootNavigation = rootNavigation
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
                    List {
                    ForEach(store.visibleItems) { item in
                        NavigationLink(value: item.id) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(item.title).font(.headline)
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
                    )
                )
            }
            .navigationDestination(for: SearchNavigationDestination.self) { destination in
                V2ConversationDetailView(
                    store: store.detailStore(for: destination.roomID),
                    initiallyFocusedMessageID: destination.messageID
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
    let openPublicIdentity: @MainActor () -> Void
    let openDeviceSessions: @MainActor () -> Void
    let openPrivacySettings: @MainActor () -> Void
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
            Button("消息接收设置", action: openPrivacySettings)
                .accessibilityIdentifier("v2.privacy.open")
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
                if let sender = store.senderFilter {
                    HStack {
                        Text("已按成员筛选")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("清除") { store.clearSenderFilter() }
                            .accessibilityLabel("清除成员筛选")
                            .accessibilityIdentifier("v2.message.search.clear-sender-filter")
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(sender.rawValue)
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
                                        store.filterToSender(hit.senderUserID)
                                    }
                                    .accessibilityIdentifier("v2.message.search.filter-sender.\(hit.senderUserID.rawValue)")
                                }
                            }
                        }
                        if store.canLoadMore {
                            Button("继续加载") { Task { await store.loadMore() } }
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
        .task(id: [store.query, store.contentFilter.rawValue, store.senderFilter?.rawValue ?? ""].joined(separator: "|")) {
            await store.search()
        }
    }
}

private struct V2FavoriteMessagesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: V2ConversationListStore
    let select: (V2FavoriteConversationMessageItem) -> Void

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
                                    Text(item.roomTitle)
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
                            .accessibilityLabel(item.roomTitle)
                            .accessibilityValue(item.text)
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
    }
}

private struct V2ConversationDetailView: View {
    private enum PresentedDetailSheet: Identifiable {
        case groupMembers
        case groupReadReceipts(V2ConversationMessageItem)
        case edit(V2ConversationMessageItem)
        case forward
        case groupAnnouncement
        case groupPermissions

        var id: String {
            switch self {
            case .groupMembers:
                "groupMembers"
            case .groupReadReceipts(let message):
                "groupReadReceipts-\(message.id)"
            case .edit(let message):
                "edit-\(message.id)"
            case .forward:
                "forward"
            case .groupAnnouncement:
                "groupAnnouncement"
            case .groupPermissions:
                "groupPermissions"
            }
        }
    }

    @State private var store: V2ConversationDetailStore
    @State private var presentedDetailSheet: PresentedDetailSheet?
    @State private var isPresentingAttachmentImporter = false
    @State private var messageSearchStore: V2ConversationSearchStore?
    @State private var isPresentingMessageSearch = false
    @State private var focusedMessageID: String?

    init(store: V2ConversationDetailStore, initiallyFocusedMessageID: String? = nil) {
        _store = State(initialValue: store)
        _focusedMessageID = State(initialValue: initiallyFocusedMessageID)
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
                                                }
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
        .navigationTitle(store.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { conversationToolbar }
        .sheet(item: $presentedDetailSheet) { sheet in
            switch sheet {
            case .groupMembers:
                V2GroupMembersSheet(store: store)
            case .groupReadReceipts(let message):
                V2GroupReadReceiptsSheet(store: store, message: message)
            case .edit(let message):
                V2MessageEditSheet(store: store, message: message)
            case .forward:
                V2ForwardMessagesSheet(store: store)
            case .groupAnnouncement:
                V2GroupAnnouncementSheet(store: store)
            case .groupPermissions:
                V2GroupPermissionsSheet(store: store)
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
        guard let focusedMessageID else { return }
        withAnimation { proxy.scrollTo(focusedMessageID, anchor: .center) }
    }
}

/// A scrollable editor avoids the fixed-height UIKit text-field clipping that
/// occurs in a message composer at accessibility Dynamic Type sizes.
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

    var body: some View {
        HStack {
            if message.isOutgoing { Spacer(minLength: 44) }
            V2ConversationMessageBubble(store: store, message: message, beginEditing: beginEditing, showReadReceipts: showReadReceipts, beginForward: beginForward)
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

/// Makes long-press-only message operations available from the VoiceOver rotor.
/// The operations remain conditional so inaccessible actions are never announced.
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

/// A bounded multi-destination picker.  It deliberately takes only the
/// compact list snapshot supplied by the conversation list Store; querying or
/// mutating room state does not happen while this sheet is rendering.

private struct V2ForwardMessagesSheet: View {
    @Bindable var store: V2ConversationDetailStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTargetRoomIDs: Set<String> = []
    @State private var selectionFeedback: String?

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
                                    Text(target.title)
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(target.title)
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
