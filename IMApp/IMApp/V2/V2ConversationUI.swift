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
struct V2ConversationListItem: Hashable, Identifiable, Sendable {
    enum Kind: Hashable, Sendable {
        /// A direct room with an authorized, bounded public-identity projection.
        case direct
        /// A group room with a compact room-profile projection.
        case group
        /// A message arrived before its corresponding room projection. Keep
        /// it readable, but do not expose group-only controls speculatively.
        case unknown

        /// Test-only consumers can distinguish a locally projected direct
        /// room from a group without depending on a mutable display name.
        /// The opaque room ID remains the final identifier component.
        var accessibilityIdentifierComponent: String {
            switch self {
            case .direct: "direct"
            case .group: "group"
            case .unknown: "unknown"
            }
        }
    }

    let id: String
    let title: String
    let preview: String
    let lastActivity: Date
    let isOutgoing: Bool
    let kind: Kind
    let isPinned: Bool
    let isArchived: Bool
    let muteUntil: Date?

    init(id: String, title: String, preview: String, lastActivity: Date, isOutgoing: Bool, kind: Kind = .unknown, isPinned: Bool = false, isArchived: Bool = false, muteUntil: Date? = nil) {
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

protocol V2ConversationDataSource: Sendable {
    func conversationSummaries(for userID: String) async throws -> [V2ConversationListItem]
    func messages(in roomID: String, for userID: String) async throws -> [V2ConversationMessageItem]
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

    private let dataSource: any V2ConversationDataSource
    private let messageSearcher: (any V2ConversationMessageSearching)?
    private let userID: String
    private let sender: (any V2ConversationSending)?
    private let messageWithdrawer: (any V2MessageWithdrawing)?
    private let messageReactionChanger: (any V2MessageReactionChanging)?
    private let messageEditor: (any V2MessageEditing)?
    private let readReceiptReporter: (any V2ConversationReadReporting)?
    private let conversationStateChanger: (any V2ConversationStateChanging)?
    private let messageFavoriter: (any V2MessageFavoriting)?
    private let groupMessagePinner: (any V2GroupMessagePinning)?
    private let messageForwarder: (any V2MessageForwarding)?
    private let groupAnnouncementManager: (any V2GroupAnnouncementManaging)?
    private let groupMemberRoleChanger: (any V2GroupMemberRoleChanging)?
    private let groupRolePolicyChanger: (any V2GroupRolePolicyChanging)?
    private let groupReadReceiptReader: (any V2GroupReadReceiptReading)?
    private let conversationLiveActivity: (any V2ConversationLiveActivityManaging)?
    private let directConversationOpener: (any V2DirectConversationOpening)?
    private let publicIdentityResolver: (any V2ConversationPublicIdentityResolving)?
    private let groupConversationCreator: (any V2GroupConversationCreating)?
    private let groupMemberDirectory: (any V2GroupMemberDirectoryReading)?
    private let groupMembershipChanger: (any V2GroupMembershipChanging)?
    private let groupMemberMuter: (any V2GroupMemberMuting)?
    private let moderatedGroupMemberRemover: (any V2ModeratedGroupMemberRemoving)?
    private let attachmentStager: (any V2ConversationAttachmentStaging)?
    private let attachmentUploader: (any V2ConversationAttachmentUploading)?
    private let mediaDownloader: (any V2ConversationMediaDownloading)?
    private let projectionChangeNotifier: V2ProjectionChangeNotifier?
    private let activeHybridGroupSynchronizer: (any V2ActiveHybridGroupSynchronizing)?
    private(set) var items: [V2ConversationListItem] = []
    private(set) var state: State = .loading
    private(set) var directConversationFeedback: String?
    private(set) var groupConversationFeedback: String?
    private(set) var conversationStateFeedback: String?
    private(set) var isOpeningDirectConversation = false
    private(set) var isCreatingGroupConversation = false
    private(set) var pendingGroupConversationOperationID: String?
    private var explicitRoomTitles: [String: String] = [:]
    private var explicitRoomKinds: [String: V2ConversationListItem.Kind] = [:]
    private var refreshGeneration = 0

    init(
        dataSource: any V2ConversationDataSource,
        messageSearcher: (any V2ConversationMessageSearching)? = nil,
        userID: String,
        sender: (any V2ConversationSending)? = nil,
        messageWithdrawer: (any V2MessageWithdrawing)? = nil,
        messageReactionChanger: (any V2MessageReactionChanging)? = nil,
        messageEditor: (any V2MessageEditing)? = nil,
        readReceiptReporter: (any V2ConversationReadReporting)? = nil,
        conversationStateChanger: (any V2ConversationStateChanging)? = nil,
        messageFavoriter: (any V2MessageFavoriting)? = nil,
        groupMessagePinner: (any V2GroupMessagePinning)? = nil,
        messageForwarder: (any V2MessageForwarding)? = nil,
        groupAnnouncementManager: (any V2GroupAnnouncementManaging)? = nil,
        groupMemberRoleChanger: (any V2GroupMemberRoleChanging)? = nil,
        groupRolePolicyChanger: (any V2GroupRolePolicyChanging)? = nil,
        groupReadReceiptReader: (any V2GroupReadReceiptReading)? = nil,
        conversationLiveActivity: (any V2ConversationLiveActivityManaging)? = nil,
        directConversationOpener: (any V2DirectConversationOpening)? = nil,
        publicIdentityResolver: (any V2ConversationPublicIdentityResolving)? = nil,
        groupConversationCreator: (any V2GroupConversationCreating)? = nil,
        groupMemberDirectory: (any V2GroupMemberDirectoryReading)? = nil,
        groupMembershipChanger: (any V2GroupMembershipChanging)? = nil,
        groupMemberMuter: (any V2GroupMemberMuting)? = nil,
        moderatedGroupMemberRemover: (any V2ModeratedGroupMemberRemoving)? = nil,
        attachmentStager: (any V2ConversationAttachmentStaging)? = nil,
        attachmentUploader: (any V2ConversationAttachmentUploading)? = nil,
        mediaDownloader: (any V2ConversationMediaDownloading)? = nil,
        projectionChangeNotifier: V2ProjectionChangeNotifier? = nil,
        activeHybridGroupSynchronizer: (any V2ActiveHybridGroupSynchronizing)? = nil
    ) {
        self.dataSource = dataSource
        self.messageSearcher = messageSearcher
        self.userID = userID
        self.sender = sender
        self.messageWithdrawer = messageWithdrawer
        self.messageReactionChanger = messageReactionChanger
        self.messageEditor = messageEditor
        self.readReceiptReporter = readReceiptReporter
        self.conversationStateChanger = conversationStateChanger
        self.messageFavoriter = messageFavoriter
        self.groupMessagePinner = groupMessagePinner
        self.messageForwarder = messageForwarder
        self.groupAnnouncementManager = groupAnnouncementManager
        self.groupMemberRoleChanger = groupMemberRoleChanger
        self.groupRolePolicyChanger = groupRolePolicyChanger
        self.groupReadReceiptReader = groupReadReceiptReader
        self.conversationLiveActivity = conversationLiveActivity
        self.directConversationOpener = directConversationOpener
        self.publicIdentityResolver = publicIdentityResolver
        self.groupConversationCreator = groupConversationCreator
        self.groupMemberDirectory = groupMemberDirectory
        self.groupMembershipChanger = groupMembershipChanger
        self.groupMemberMuter = groupMemberMuter
        self.moderatedGroupMemberRemover = moderatedGroupMemberRemover
        self.attachmentStager = attachmentStager
        self.attachmentUploader = attachmentUploader
        self.mediaDownloader = mediaDownloader
        self.projectionChangeNotifier = projectionChangeNotifier
        self.activeHybridGroupSynchronizer = activeHybridGroupSynchronizer
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
                var resolved: [String] = []
                for handle in handles {
                    resolved.append(try await publicIdentityResolver.resolve(handle: handle).userID.rawValue)
                    try Task.checkCancellation()
                }
                members = resolved
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
            let refreshedItems = try await dataSource.conversationSummaries(for: userID)
            try Task.checkCancellation()
            guard generation == refreshGeneration else { return }
            items = refreshedItems
            state = .loaded
            await restoreDurableGroupCreationStatusIfNeeded()
        } catch is CancellationError {
            return
        } catch {
            guard generation == refreshGeneration else { return }
            state = .failed
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
        return .init(dataSource: dataSource, messageSearcher: messageSearcher, sender: sender, messageWithdrawer: messageWithdrawer, messageReactionChanger: messageReactionChanger, messageEditor: messageEditor, readReceiptReporter: readReceiptReporter, messageFavoriter: messageFavoriter, groupMessagePinner: groupMessagePinner, messageForwarder: messageForwarder, forwardTargets: forwardTargets, groupAnnouncementReader: dataSource as? any V2GroupAnnouncementReading, groupAnnouncementManager: groupAnnouncementManager, groupMemberRoleChanger: groupMemberRoleChanger, groupRolePolicyReader: dataSource as? any V2GroupRolePolicyReading, groupRolePolicyChanger: groupRolePolicyChanger, groupReadReceiptReader: groupReadReceiptReader, conversationLiveActivity: conversationLiveActivity, userID: userID, roomID: roomID, title: title, isGroupConversation: kind == .group, groupMemberDirectory: groupMemberDirectory, groupMembershipChanger: groupMembershipChanger, groupMemberMuter: groupMemberMuter, moderatedGroupMemberRemover: moderatedGroupMemberRemover, publicIdentityResolver: publicIdentityResolver, attachmentStager: attachmentStager, attachmentUploader: attachmentUploader, mediaDownloader: mediaDownloader, projectionChangeNotifier: projectionChangeNotifier, activeHybridGroupSynchronizer: activeHybridGroupSynchronizer, initialDraft: initialDraft, initialMentionHandles: initialMentionHandles)
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
            explicitRoomKinds[roomID] = .direct
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
                    if typing.isTyping && typing.expiresAt > Date() {
                        typingUserIDs.insert(typing.userID)
                    } else {
                        typingUserIDs.remove(typing.userID)
                    }
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
        typingLeaseTask?.cancel()
        typingLeaseTask = nil
        await conversationLiveActivity.deactivate(roomID: roomID, includesPresence: includesPresence)
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
                case .loaded where store.items.isEmpty:
                    ContentUnavailableView(
                        "暂无会话",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("连接实时网关并完成同步后，消息会显示在这里。")
                    )
                case .loaded:
                    List(store.items) { item in
                        NavigationLink(value: item.id) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(item.title).font(.headline)
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
                    .accessibilityIdentifier("v2.conversation.list")
                }
            }
            .navigationTitle("消息")
            .safeAreaInset(edge: .bottom) {
                if let feedback = store.conversationStateFeedback {
                    Text(feedback).font(.footnote).foregroundStyle(.secondary).padding(.horizontal).padding(.vertical, 6).accessibilityIdentifier("v2.conversation.state-feedback")
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("搜索消息", systemImage: "magnifyingglass") {
                        guard let searchStore = store.messageSearchStore() else { return }
                        messageSearchStore = searchStore
                        isPresentingMessageSearch = true
                    }
                    .accessibilityIdentifier("v2.message.search")
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
                }
                if let accountMenu {
                    ToolbarItem(placement: .topBarTrailing) {
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

struct V2ConversationAccountMenu: View {
    let canOpenPublicIdentity: Bool
    let openPublicIdentity: @MainActor () -> Void
    let openPrivacySettings: @MainActor () -> Void
    let signOut: @MainActor () -> Void

    var body: some View {
        Menu {
            if canOpenPublicIdentity {
                Button("我的资料", action: openPublicIdentity)
                    .accessibilityIdentifier("v2.identity.open")
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
                if store.hits.isEmpty {
                    ContentUnavailableView("没有匹配消息", systemImage: "text.magnifyingglass")
                } else {
                    List {
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
                        }
                        if store.canLoadMore {
                            Button("继续加载") { Task { await store.loadMore() } }
                                .accessibilityIdentifier("v2.message.search.load-more")
                        }
                    }
                    .accessibilityIdentifier("v2.message.search.results")
                }
            }
        }
        .navigationTitle("搜索消息")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") { dismiss() }
            }
        }
        .task(id: "\(store.query)|\(store.contentFilter.rawValue)") {
            await store.search()
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
                    if store.messages.isEmpty {
                        ContentUnavailableView("暂无消息", systemImage: "bubble")
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 10) {
                                    ForEach(store.messages) { message in
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
                                        .id(message.id)
                                    }
                                }
                                .padding()
                            }
                            .onAppear { scrollToFocusedMessage(with: proxy) }
                            .onChange(of: focusedMessageID) { _, _ in
                                scrollToFocusedMessage(with: proxy)
                            }
                            .onChange(of: store.messages.map(\.id)) { _, _ in
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
                            .disabled(store.isSending)
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
                        .disabled(!store.canAddAttachment)
                        .tint(.primary)
                        .accessibilityHint("从文件中选择要发送的附件")
                        .accessibilityIdentifier("v2.message.attachment.add")
                        V2ComposerTextInput(
                            text: $store.draft,
                            placeholder: "消息",
                            accessibilityLabel: "消息内容",
                            accessibilityHint: "输入要发送的消息"
                        )
                            .disabled(store.isSending)
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
    }

    private var canSendDraft: Bool {
        !store.isSending
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
private struct V2GroupAnnouncementBanner: View {
    let announcement: V2ClientGroupAnnouncement
    let edit: () -> Void

    var body: some View {
        Button(action: edit) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "megaphone.fill")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("群公告")
                        .font(.caption.weight(.semibold))
                    Text(announcement.body)
                        .font(.subheadline)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.08))
        .accessibilityLabel("群公告")
        .accessibilityValue(announcement.body)
        .accessibilityHint("打开群公告详情")
        .accessibilityIdentifier("v2.group.announcement.banner")
    }
}

private struct V2GroupAnnouncementSheet: View {
    @Bindable var store: V2ConversationDetailStore
    @Environment(\.dismiss) private var dismiss
    @State private var announcementText: String

    init(store: V2ConversationDetailStore) {
        self.store = store
        _announcementText = State(initialValue: store.groupAnnouncement?.body ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("公告内容") {
                    TextEditor(text: $announcementText)
                        .frame(minHeight: 160)
                        .accessibilityLabel("群公告内容")
                        .accessibilityIdentifier("v2.group.announcement.body")
                    Text("最多 \(V2GroupAnnouncementCommand.maximumUTF8Bytes) 字节；最终权限与版本冲突由服务端处理。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let feedback = store.messageActionFeedback {
                    Section { Text(feedback).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("群公告")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .accessibilityIdentifier("v2.group.announcement.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let updatedBody = announcementText
                        Task {
                            if await store.saveGroupAnnouncement(updatedBody) { dismiss() }
                        }
                    }
                    .disabled(announcementText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isSavingGroupAnnouncement)
                    .accessibilityValue(store.isSavingGroupAnnouncement ? "正在保存群公告" : "")
                    .accessibilityIdentifier("v2.group.announcement.save")
                }
            }
        }
    }
}

private struct V2GroupPermissionsSheet: View {
    @Bindable var store: V2ConversationDetailStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedRole: V2RoomMembershipRole = .admin
    @State private var selectedPermissions: Set<V2GroupPermission> = []

    var body: some View {
        NavigationStack {
            Form {
                if store.isLoadingGroupRolePolicies || store.isLoadingGroupMembers {
                    Section { ProgressView("正在读取群权限…") }
                } else {
                    Section("角色") {
                        Picker("编辑角色", selection: $selectedRole) {
                            Text("管理员").tag(V2RoomMembershipRole.admin)
                            Text("普通成员").tag(V2RoomMembershipRole.member)
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: selectedRole) { _, _ in loadSelectedPolicy() }
                        Text("当前策略版本 \(selectedPolicy?.revision ?? 1)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Section("允许的操作") {
                        ForEach(V2GroupPermission.allCases, id: \.self) { permission in
                            Toggle(permission.title, isOn: binding(for: permission))
                                .accessibilityIdentifier("v2.group.permission.\(selectedRole.rawValue).\(permission.rawValue)")
                        }
                    }
                    if store.groupActorRole != "群主" {
                        Section {
                            Text("只有群主可以提交角色权限策略；服务端也会再次验证权限和版本。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let feedback = store.messageActionFeedback {
                        Section { Text(feedback).foregroundStyle(.secondary) }
                    }
                }
            }
            .navigationTitle("群权限")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .accessibilityIdentifier("v2.group.permissions.close")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard let policy = selectedPolicy else { return }
                        let permissions = selectedPermissions
                        Task {
                            if await store.saveGroupRolePolicy(policy, permissions: permissions) { dismiss() }
                        }
                    }
                    .disabled(selectedPolicy == nil || store.isSavingGroupRolePolicy || store.groupActorRole != "群主")
                    .accessibilityValue(store.isSavingGroupRolePolicy ? "正在保存群权限策略" : "")
                    .accessibilityIdentifier("v2.group.permissions.save")
                }
            }
            .task {
                await store.loadGroupRolePolicies()
                await store.loadGroupMembers(reset: true)
                loadSelectedPolicy()
            }
        }
    }

    private var selectedPolicy: V2ClientGroupRolePolicy? {
        store.groupRolePolicies.first(where: { $0.role == selectedRole })
    }

    private func binding(for permission: V2GroupPermission) -> Binding<Bool> {
        .init(
            get: { selectedPermissions.contains(permission) },
            set: { isAllowed in
                if isAllowed { selectedPermissions.insert(permission) }
                else { selectedPermissions.remove(permission) }
            }
        )
    }

    private func loadSelectedPolicy() {
        selectedPermissions = selectedPolicy?.permissions ?? []
    }
}

private extension V2GroupPermission {
    var title: String {
        switch self {
        case .sendMessages: "发送消息"
        case .inviteMembers: "邀请成员"
        case .removeMembers: "移除成员"
        case .changeMemberRoles: "修改成员角色"
        case .pinMessages: "置顶消息"
        case .manageAnnouncements: "管理群公告"
        case .moderateMessages: "审核消息"
        case .muteMembers: "禁言成员"
        }
    }
}

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

private struct V2ConversationMediaAttachmentRow: View {
    @Bindable var store: V2ConversationDetailStore
    let message: V2ConversationMessageItem
    let media: V2MediaReference
    let presentation: V2MediaPresentation
    let index: Int
    @State private var isPresentingPlayer = false

    var body: some View {
        switch store.mediaDownloadState(for: media) {
        case .notDownloaded:
            downloadButton(title: downloadTitle, systemImage: "arrow.down.circle")
        case .downloading:
            Label("正在下载\(kindLabel)", systemImage: "arrow.down.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("正在下载\(kindLabel)")
                .accessibilityIdentifier(identifier)
        case .downloaded(let downloaded):
            downloadedContent(downloaded)
        case .failed:
            downloadButton(title: "重新下载\(kindLabel)", systemImage: "arrow.clockwise")
        }
    }

    @ViewBuilder
    private func downloadedContent(_ downloaded: V2DownloadedConversationMedia) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if (presentation.kind == .image || presentation.kind == .animatedImage),
               let image = UIImage(contentsOfFile: downloaded.fileURL.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 260, maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel(kindLabel)
                    .accessibilityValue(byteCountLabel)
                    .accessibilityIdentifier(identifier + ".preview")
            }
            if presentation.kind == .video || presentation.kind == .audio {
                Button(playbackTitle, systemImage: playbackSymbol) {
                    isPresentingPlayer = true
                }
                .font(.caption)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityHint("播放已下载到此设备的\(kindLabel)")
                .accessibilityIdentifier(identifier + ".play")
                .sheet(isPresented: $isPresentingPlayer) {
                    V2LocalMediaPlayerSheet(
                        fileURL: downloaded.fileURL,
                        kind: presentation.kind,
                        accessibilityIdentifier: identifier + ".player"
                    )
                }
            }
            ShareLink(item: downloaded.fileURL) {
                Label("分享\(kindLabel)", systemImage: "square.and.arrow.up")
            }
            .font(.caption)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel("分享\(kindLabel)")
            .accessibilityHint("打开系统分享菜单")
            .accessibilityIdentifier(identifier)
        }
    }

    @ViewBuilder
    private func downloadButton(title: String, systemImage: String) -> some View {
        Button(title, systemImage: systemImage) {
            Task { await store.downloadMedia(media, from: message) }
        }
        .font(.caption)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityHint("重新验证权限后下载\(kindLabel)到此设备，\(byteCountLabel)")
        .accessibilityIdentifier(identifier)
    }

    private var kindLabel: String {
        switch presentation.kind {
        case .image: "图片"
        case .animatedImage: "动图"
        case .video: "视频"
        case .audio: "音频"
        case .file: "文件"
        }
    }

    private var downloadTitle: String {
        "下载\(kindLabel)"
    }

    private var byteCountLabel: String {
        presentation.byteCount > 0
            ? ByteCountFormatter.string(fromByteCount: presentation.byteCount, countStyle: .file)
            : "大小未知"
    }

    private var identifier: String {
        "v2.message.media." + message.id + "." + String(index)
    }

    private var playbackTitle: String { presentation.kind == .video ? "播放视频" : "播放音频" }
    private var playbackSymbol: String { presentation.kind == .video ? "play.rectangle" : "play.circle" }
}

/// A privacy-preserving card: rendering a message never fetches a remote
/// page, image, or favicon. The user explicitly chooses whether to hand the
/// already-validated HTTP(S) URL to the system browser.
private struct V2SafeLinkPreview: View {
    let url: URL
    let messageID: String

    var body: some View {
        Link(destination: url) {
            Label(url.host ?? "网页链接", systemImage: "link")
                .lineLimit(1)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityLabel("打开链接：\(url.host ?? "网页链接")")
        .accessibilityHint("将在系统浏览器中打开；不会自动加载网页预览")
        .accessibilityIdentifier("v2.message.link.\(messageID).\(url.host ?? "unknown")")
    }
}

@MainActor
private struct V2LocalMediaPlayerSheet: View {
    let fileURL: URL
    let kind: V2MediaPresentation.Kind
    let accessibilityIdentifier: String
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var isPlaying = false

    var body: some View {
        NavigationStack {
            Group {
                if kind == .video, let player {
                    VideoPlayer(player: player)
                        .accessibilityLabel("视频播放器")
                } else {
                    VStack(spacing: 20) {
                        Image(systemName: "waveform")
                            .font(.system(size: 44))
                            .accessibilityHidden(true)
                        Button(isPlaying ? "暂停音频" : "播放音频", systemImage: isPlaying ? "pause.circle.fill" : "play.circle.fill") {
                            togglePlayback()
                        }
                        .font(.title2)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityValue(isPlaying ? "正在播放" : "已暂停")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .accessibilityIdentifier(accessibilityIdentifier)
            .navigationTitle(kind == .video ? "视频" : "音频")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .onAppear {
            guard player == nil else { return }
            player = AVPlayer(url: fileURL)
        }
        .onDisappear {
            player?.pause()
            isPlaying = false
            player = nil
        }
    }

    private func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
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

private struct V2GroupReadReceiptsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: V2ConversationDetailStore
    let message: V2ConversationMessageItem

    var body: some View {
        NavigationStack {
            Group {
                if let page = store.groupReadReceiptPage {
                    List {
                        Section {
                            Text("\(page.readerCount) 人已读")
                                .accessibilityLabel("已有 \(page.readerCount) 人已读")
                                .accessibilityIdentifier("v2.message.group-readers.count.\(message.id)")
                        }
                        Section("已读成员") {
                            ForEach(page.readers, id: \.userID) { reader in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(reader.publicIdentity?.displayName ?? "成员")
                                    if let handle = reader.publicIdentity?.handle.rawValue {
                                        Text("@\(handle)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel(reader.publicIdentity?.displayName ?? "成员已读")
                            }
                            if page.nextCursor != nil {
                                Button("加载更多") { Task { await store.loadGroupReadReceipts(for: message) } }
                                    .disabled(store.isLoadingGroupReadReceipts)
                                    .accessibilityIdentifier("v2.message.group-readers.more.\(message.id)")
                            }
                        }
                    }
                } else if store.isLoadingGroupReadReceipts {
                    ProgressView("正在读取已读详情…")
                } else if let feedback = store.groupReadReceiptFeedback {
                    ContentUnavailableView("无法读取已读详情", systemImage: "exclamationmark.triangle", description: Text(feedback))
                } else {
                    ContentUnavailableView("暂无已读记录", systemImage: "checkmark.circle")
                }
            }
            .navigationTitle("已读详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task(id: message.id) { await store.loadGroupReadReceipts(for: message, reset: true) }
        }
    }
}

private struct V2GroupMembersSheet: View {
    @Bindable var store: V2ConversationDetailStore
    @Environment(\.dismiss) private var dismiss
    @State private var newMemberUserID = ""
    @State private var membershipChangeTask: Task<Void, Never>?
    @State private var moderationTask: Task<Void, Never>?
    @State private var pendingModeratedRemoval: V2GroupMemberItem?

    var body: some View {
        NavigationStack {
            List {
                if let revision = store.groupMemberRevision {
                    Text("成员版本 \(revision)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if store.canAddGroupMembers {
                    Section("添加成员") {
                        TextField("成员公开 ID（@handle）", text: $newMemberUserID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .disabled(
                                store.isLoadingGroupMembers
                                    || store.isChangingGroupMembership
                                    || store.isApplyingGroupModeration
                            )
                            .accessibilityIdentifier("v2.group.members.add-input")
                        Button("添加") {
                            let target = newMemberUserID
                            newMemberUserID = ""
                            runMembershipChange(target: target, action: .add)
                        }
                        .disabled(
                            store.isLoadingGroupMembers
                                || store.isChangingGroupMembership
                                || store.isApplyingGroupModeration
                                || newMemberUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                        .accessibilityValue(
                            store.isChangingGroupMembership || store.isApplyingGroupModeration
                                ? "正在保存成员变更"
                                : ""
                        )
                        .accessibilityIdentifier("v2.group.members.add")
                    }
                }
                if store.groupActorRole == "群主" || store.groupActorRole == "管理员" {
                    Section {
                        Text("禁言和管理员移除会以独立的可审计命令保存；网络中断时会自动重试。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(store.groupMembers) { member in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(member.displayName ?? member.handle.map { "@\($0)" } ?? "资料暂不可用")
                            if let handle = member.handle {
                                Text("@\(handle)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(member.role).foregroundStyle(.secondary)
                        if store.canChangeGroupMemberRole(member) {
                            Menu {
                                Button("设为管理员") { runRoleChange(member, role: .admin) }
                                    .disabled(member.role == "管理员")
                                    .accessibilityIdentifier("v2.group.member.role.admin.\(member.id)")
                                Button("设为普通成员") { runRoleChange(member, role: .member) }
                                    .disabled(member.role == "成员")
                                    .accessibilityIdentifier("v2.group.member.role.member.\(member.id)")
                            } label: {
                                Image(systemName: "person.badge.key")
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(.rect)
                            }
                            .disabled(store.isLoadingGroupMembers || store.isChangingGroupMembership || store.isApplyingGroupModeration)
                            .accessibilityLabel("修改 \(member.displayName ?? member.handle ?? "成员") 的角色")
                            .accessibilityHint("可设为管理员或普通成员")
                            .accessibilityIdentifier("v2.group.member.role.\(member.id)")
                        }
                        if store.canRemoveGroupMember(member) {
                            Menu {
                                Button("禁言 1 小时") {
                                    runMute(member)
                                }
                                .accessibilityIdentifier("v2.group.member.mute.\(member.id)")
                                Button("管理员移除", role: .destructive) {
                                    pendingModeratedRemoval = member
                                }
                                .accessibilityIdentifier("v2.group.member.moderated-remove.\(member.id)")
                            } label: {
                                Image(systemName: "shield")
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(.rect)
                            }
                            .disabled(store.isLoadingGroupMembers || store.isChangingGroupMembership || store.isApplyingGroupModeration)
                            .accessibilityLabel("群管理 \(member.displayName ?? member.handle ?? "成员")")
                            .accessibilityHint("可禁言一小时或执行带审计记录的管理员移除")
                            .accessibilityIdentifier("v2.group.member.moderation.\(member.id)")
                            Button("移除", role: .destructive) {
                                runMembershipChange(target: member.id, action: .remove)
                            }
                            .disabled(store.isLoadingGroupMembers || store.isChangingGroupMembership || store.isApplyingGroupModeration)
                            .accessibilityValue(store.isChangingGroupMembership || store.isApplyingGroupModeration ? "正在保存成员变更" : "")
                            .accessibilityIdentifier("v2.group.member.remove.\(member.id)")
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("v2.group.member.\(member.id)")
                }
                if store.canLoadMoreGroupMembers {
                    Button("加载更多") { Task { await store.loadGroupMembers() } }
                        .disabled(store.isLoadingGroupMembers)
                        .accessibilityIdentifier("v2.group.members.load-more")
                }
                if let feedback = store.groupMemberFeedback {
                    Text(feedback).foregroundStyle(.secondary)
                        .onAppear { announceV2AccessibilityAnnouncement(feedback) }
                        .onChange(of: feedback) { _, updatedFeedback in
                            announceV2AccessibilityAnnouncement(updatedFeedback)
                        }
                        .accessibilityIdentifier("v2.group.members.feedback")
                }
            }
            .accessibilityIdentifier("v2.group.members.sheet")
            .overlay {
                if store.isLoadingGroupMembers, store.groupMembers.isEmpty, store.groupMemberFeedback == nil {
                    ProgressView("正在读取成员…")
                }
            }
            .navigationTitle("群成员")
            .onDisappear {
                membershipChangeTask?.cancel()
                moderationTask?.cancel()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .accessibilityIdentifier("v2.group.members.close")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("刷新") { Task { await store.loadGroupMembers(reset: true) } }
                        .disabled(store.isLoadingGroupMembers)
                        .accessibilityValue(store.isLoadingGroupMembers ? "正在读取成员" : "")
                }
            }
            .task { await store.loadGroupMembers(reset: true) }
            .confirmationDialog(
                "确认管理员移除？",
                isPresented: Binding(
                    get: { pendingModeratedRemoval != nil },
                    set: { if !$0 { pendingModeratedRemoval = nil } }
                ),
                presenting: pendingModeratedRemoval
            ) { member in
                Button("管理员移除", role: .destructive) {
                    pendingModeratedRemoval = nil
                    runModeratedRemoval(member)
                }
            } message: { member in
                Text("将移除 \(member.displayName ?? member.handle ?? "该成员")，并写入管理员审计记录。")
            }
        }
    }

    private func runMembershipChange(target: String, action: V2RoomMembershipAction) {
        guard membershipChangeTask == nil else { return }
        membershipChangeTask = Task {
            await store.changeGroupMembership(targetUserID: target, action: action)
            guard !Task.isCancelled else { return }
            membershipChangeTask = nil
        }
    }

    private func runRoleChange(_ member: V2GroupMemberItem, role: V2RoomMembershipRole) {
        guard membershipChangeTask == nil else { return }
        membershipChangeTask = Task {
            await store.changeGroupMemberRole(member, to: role)
            guard !Task.isCancelled else { return }
            membershipChangeTask = nil
        }
    }

    private func runMute(_ member: V2GroupMemberItem) {
        guard moderationTask == nil else { return }
        moderationTask = Task {
            await store.muteGroupMember(member)
            guard !Task.isCancelled else { return }
            moderationTask = nil
        }
    }

    private func runModeratedRemoval(_ member: V2GroupMemberItem) {
        guard moderationTask == nil else { return }
        moderationTask = Task {
            await store.removeGroupMemberByModerator(member)
            guard !Task.isCancelled else { return }
            moderationTask = nil
        }
    }
}

@MainActor
func announceV2AccessibilityAnnouncement(_ message: String) {
    guard UIAccessibility.isVoiceOverRunning else { return }
    UIAccessibility.post(notification: .announcement, argument: message)
}
