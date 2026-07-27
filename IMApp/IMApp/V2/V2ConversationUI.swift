import Foundation
import IMV2ClientKit
import IMV2Core
import Observation
import SwiftUI
import UIKit
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
    }

    let id: String
    let title: String
    let preview: String
    let lastActivity: Date
    let isOutgoing: Bool
    let kind: Kind

    init(id: String, title: String, preview: String, lastActivity: Date, isOutgoing: Bool, kind: Kind = .unknown) {
        self.id = id
        self.title = title
        self.preview = preview
        self.lastActivity = lastActivity
        self.isOutgoing = isOutgoing
        self.kind = kind
    }
}

struct V2ConversationMessageItem: Hashable, Identifiable, Sendable {
    let id: String
    let roomSequence: UInt64
    let revision: UInt64
    let text: String
    /// Opaque media IDs from the local projection. The UI may show that a
    /// message has attachments, but never receives a provider URL here.
    let media: [V2MediaReference]
    /// Protocol-level mention targets. IDs are kept opaque in the UI; the
    /// message bubble exposes only aggregate mention semantics.
    let mentions: [V2MentionTarget]
    let createdAt: Date
    let isOutgoing: Bool
    let isWithdrawn: Bool
    let reactions: [V2ConversationMessageReaction]

    init(id: String, roomSequence: UInt64 = 1, revision: UInt64, text: String, media: [V2MediaReference] = [], mentions: [V2MentionTarget] = [], createdAt: Date, isOutgoing: Bool, isWithdrawn: Bool, reactions: [V2ConversationMessageReaction] = []) {
        self.id = id
        self.roomSequence = roomSequence
        self.revision = revision
        self.text = text
        self.media = media
        self.mentions = mentions
        self.createdAt = createdAt
        self.isOutgoing = isOutgoing
        self.isWithdrawn = isWithdrawn
        self.reactions = reactions
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

/// Boundary from the UI feature to the V2 SQLite projection. All IDs are
/// parsed at this boundary; invalid data can never become a navigation route.
actor V2GRDBConversationDataSource: V2ConversationDataSource {
    private let localStore: GRDBV2LocalSyncStore

    init(localStore: GRDBV2LocalSyncStore) {
        self.localStore = localStore
    }

    func conversationSummaries(for userID: String) async throws -> [V2ConversationListItem] {
        let profiles = try await localStore.roomProfiles()
        let titles = Dictionary(uniqueKeysWithValues: profiles.map { ($0.roomID, $0.title) })
        let directIdentities = try await localStore.directRoomIdentities()
        let directTitles = Dictionary(uniqueKeysWithValues: directIdentities.map { ($0.roomID, $0.publicIdentity.displayName) })
        let groupRoomIDs = Set(profiles.map(\.roomID))
        let directRoomIDs = Set(directIdentities.map(\.roomID))
        let summaries = try await localStore.conversationSummaries()
        let messageItems: [V2ConversationListItem] = summaries.map { summary in
            let message = summary.lastMessage
            return V2ConversationListItem(
                id: summary.roomID.rawValue,
                title: titles[summary.roomID] ?? directTitles[summary.roomID] ?? Self.roomTitle(summary.roomID.rawValue),
                preview: Self.preview(for: message),
                lastActivity: message.createdAt,
                isOutgoing: message.senderUserID.rawValue == userID,
                kind: groupRoomIDs.contains(summary.roomID) ? .group : (directRoomIDs.contains(summary.roomID) ? .direct : .unknown)
            )
        }
        return Self.mergingEmptyProjectionItems(
            messageItems: messageItems,
            profiles: profiles,
            directIdentities: directIdentities
        )
    }

    static func mergingEmptyProjectionItems(
        messageItems: [V2ConversationListItem],
        profiles: [V2ClientRoomProfileProjection],
        directIdentities: [V2ClientDirectRoomIdentity]
    ) -> [V2ConversationListItem] {
        let messageRoomIDs = Set(messageItems.map(\.id))
        let emptyProfileItems: [V2ConversationListItem] = profiles.compactMap { profile in
            guard !messageRoomIDs.contains(profile.roomID.rawValue) else { return nil }
            return V2ConversationListItem(
                id: profile.roomID.rawValue,
                title: profile.title,
                preview: "暂无消息",
                lastActivity: profile.createdAt,
                isOutgoing: false,
                kind: .group
            )
        }
        let representedRoomIDs = messageRoomIDs.union(emptyProfileItems.map(\.id))
        let emptyDirectItems: [V2ConversationListItem] = directIdentities.compactMap { identity in
            // Direct-room profiles are durable sync projections. The local
            // lookup cache may temporarily be the only available title while
            // the creation sync is in flight, so it must still make the empty
            // direct room discoverable without exposing an opaque room ID.
            guard !representedRoomIDs.contains(identity.roomID.rawValue) else { return nil }
            return V2ConversationListItem(
                id: identity.roomID.rawValue,
                title: identity.publicIdentity.displayName,
                preview: "暂无消息",
                lastActivity: identity.updatedAt,
                isOutgoing: false,
                kind: .direct
            )
        }
        return (messageItems + emptyProfileItems + emptyDirectItems).sorted { lhs, rhs in
            lhs.lastActivity == rhs.lastActivity ? lhs.id < rhs.id : lhs.lastActivity > rhs.lastActivity
        }
    }

    func messages(in roomID: String, for userID: String) async throws -> [V2ConversationMessageItem] {
        let parsedRoomID = try RoomID(roomID)
        let messages = try await localStore.messages(in: parsedRoomID)
        let reactions = try await localStore.reactions(in: parsedRoomID)
        let reactionsByMessageID = Dictionary(grouping: reactions, by: \.messageID)
        return messages.map { message in
            .init(
                id: message.messageID.rawValue,
                roomSequence: message.roomSequence,
                revision: message.messageRevision,
                text: message.isWithdrawn ? "消息已撤回" : message.text,
                media: message.isWithdrawn ? [] : message.media,
                mentions: message.isWithdrawn ? [] : message.mentions,
                createdAt: message.createdAt,
                isOutgoing: message.senderUserID.rawValue == userID,
                isWithdrawn: message.isWithdrawn,
                reactions: Self.reactionSummaries(
                    reactionsByMessageID[message.messageID] ?? [],
                    currentUserID: userID
                )
            )
        }
    }

    private static func roomTitle(_ roomID: String) -> String {
        // A room ID is an opaque routing key, never product-facing identity.
        // Known group and direct titles are resolved above; this conservative
        // fallback is for an in-flight sync record whose profile has not yet
        // arrived.
        _ = roomID
        return "会话"
    }

    private static func preview(for message: V2ClientMessageProjection) -> String {
        if message.isWithdrawn { return "消息已撤回" }
        if !message.text.isEmpty { return message.text }
        return message.media.isEmpty ? "" : "[附件]"
    }

    private static func reactionSummaries(_ reactions: [V2ClientMessageReaction], currentUserID: String) -> [V2ConversationMessageReaction] {
        Dictionary(grouping: reactions, by: \.reaction)
            .map { reaction, entries in
                .init(
                    reaction: reaction,
                    count: entries.count,
                    includesCurrentUser: entries.contains { $0.actorUserID.rawValue == currentUserID }
                )
            }
            .sorted { $0.reaction < $1.reaction }
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
    private let userID: String
    private let sender: (any V2ConversationSending)?
    private let messageWithdrawer: (any V2MessageWithdrawing)?
    private let messageReactionChanger: (any V2MessageReactionChanging)?
    private let messageEditor: (any V2MessageEditing)?
    private let readReceiptReporter: (any V2ConversationReadReporting)?
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
    private(set) var items: [V2ConversationListItem] = []
    private(set) var state: State = .loading
    private(set) var directConversationFeedback: String?
    private(set) var groupConversationFeedback: String?
    private(set) var isOpeningDirectConversation = false
    private(set) var isCreatingGroupConversation = false
    private var explicitRoomTitles: [String: String] = [:]
    private var explicitRoomKinds: [String: V2ConversationListItem.Kind] = [:]
    private var refreshGeneration = 0

    init(
        dataSource: any V2ConversationDataSource,
        userID: String,
        sender: (any V2ConversationSending)? = nil,
        messageWithdrawer: (any V2MessageWithdrawing)? = nil,
        messageReactionChanger: (any V2MessageReactionChanging)? = nil,
        messageEditor: (any V2MessageEditing)? = nil,
        readReceiptReporter: (any V2ConversationReadReporting)? = nil,
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
        projectionChangeNotifier: V2ProjectionChangeNotifier? = nil
    ) {
        self.dataSource = dataSource
        self.userID = userID
        self.sender = sender
        self.messageWithdrawer = messageWithdrawer
        self.messageReactionChanger = messageReactionChanger
        self.messageEditor = messageEditor
        self.readReceiptReporter = readReceiptReporter
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
                explicitRoomTitles[roomID] = title.trimmingCharacters(in: .whitespacesAndNewlines)
                explicitRoomKinds[roomID] = .group
                groupConversationFeedback = nil
                return roomID
            case .queuedForRetry:
                groupConversationFeedback = "建群请求已安全保存，连接恢复后会继续。"
                return nil
            case .rejected(let code):
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
        } catch is CancellationError {
            return
        } catch {
            guard generation == refreshGeneration else { return }
            state = .failed
        }
    }

    func detailStore(
        for roomID: String,
        initialDraft: String? = nil
    ) -> V2ConversationDetailStore {
        let item = items.first(where: { $0.id == roomID })
        let title = explicitRoomTitles[roomID] ?? item?.title ?? "会话"
        let kind = explicitRoomKinds[roomID] ?? item?.kind ?? .unknown
        return .init(dataSource: dataSource, sender: sender, messageWithdrawer: messageWithdrawer, messageReactionChanger: messageReactionChanger, messageEditor: messageEditor, readReceiptReporter: readReceiptReporter, userID: userID, roomID: roomID, title: title, isGroupConversation: kind == .group, groupMemberDirectory: groupMemberDirectory, groupMembershipChanger: groupMembershipChanger, groupMemberMuter: groupMemberMuter, moderatedGroupMemberRemover: moderatedGroupMemberRemover, publicIdentityResolver: publicIdentityResolver, attachmentStager: attachmentStager, attachmentUploader: attachmentUploader, mediaDownloader: mediaDownloader, projectionChangeNotifier: projectionChangeNotifier, initialDraft: initialDraft)
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
    private let sender: (any V2ConversationSending)?
    private let messageWithdrawer: (any V2MessageWithdrawing)?
    private let messageReactionChanger: (any V2MessageReactionChanging)?
    private let messageEditor: (any V2MessageEditing)?
    private let readReceiptReporter: (any V2ConversationReadReporting)?
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
    private var nextGroupMemberCursor: String?
    private var refreshGeneration = 0
    private var inFlightMessageActionIDs: Set<String> = []
    var draft = ""
    var mentionHandlesText = ""

    let reactionPresets = ["👍", "❤️", "😂", "🎉", "😢", "😡"]

    init(dataSource: any V2ConversationDataSource, sender: (any V2ConversationSending)?, messageWithdrawer: (any V2MessageWithdrawing)? = nil, messageReactionChanger: (any V2MessageReactionChanging)? = nil, messageEditor: (any V2MessageEditing)? = nil, readReceiptReporter: (any V2ConversationReadReporting)? = nil, userID: String, roomID: String, title: String = "会话", isGroupConversation: Bool = false, groupMemberDirectory: (any V2GroupMemberDirectoryReading)? = nil, groupMembershipChanger: (any V2GroupMembershipChanging)? = nil, groupMemberMuter: (any V2GroupMemberMuting)? = nil, moderatedGroupMemberRemover: (any V2ModeratedGroupMemberRemoving)? = nil, publicIdentityResolver: (any V2ConversationPublicIdentityResolving)? = nil, attachmentStager: (any V2ConversationAttachmentStaging)? = nil, attachmentUploader: (any V2ConversationAttachmentUploading)? = nil, mediaDownloader: (any V2ConversationMediaDownloading)? = nil, projectionChangeNotifier: V2ProjectionChangeNotifier? = nil, initialDraft: String? = nil) {
        self.dataSource = dataSource
        self.sender = sender
        self.messageWithdrawer = messageWithdrawer
        self.messageReactionChanger = messageReactionChanger
        self.messageEditor = messageEditor
        self.readReceiptReporter = readReceiptReporter
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
        draft = initialDraft ?? ""
    }

    func refresh() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        state = .loading
        do {
            let refreshedMessages = try await dataSource.messages(in: roomID, for: userID)
            try Task.checkCancellation()
            guard generation == refreshGeneration else { return }
            messages = refreshedMessages
            let visibleMediaIDs = Set(refreshedMessages.lazy
                .filter { !$0.isWithdrawn }
                .flatMap(\.media)
                .map(\.mediaID))
            mediaDownloadStates = mediaDownloadStates.filter { visibleMediaIDs.contains($0.key) }
            state = .loaded
            await reportReadThroughVisibleMessages()
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

    private func reportReadThroughVisibleMessages() async {
        guard let readReceiptReporter,
              let lastVisibleSequence = messages.map(\.roomSequence).max()
        else { return }
        do {
            _ = try await readReceiptReporter.recordReadThrough(roomID: roomID, roomSequence: lastVisibleSequence)
        } catch is CancellationError {
            return
        } catch {
            // Reading local history must remain available even if the durable
            // receipt queue cannot currently accept an update.
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
        guard await uploadPendingAttachments() else { return }
        let media = attachments.compactMap { item -> V2MediaReference? in
            guard case .available(let reference) = item.state else { return nil }
            return reference
        }
        guard media.count == attachments.count else {
            sendFeedback = "附件尚未准备完成。"
            return
        }
        do {
            let mentions = try await resolvedMentions()
            try Task.checkCancellation()
            let outcome = try await sender.send(text: text, media: media, mentions: mentions, in: roomID)
            try Task.checkCancellation()
            switch outcome {
            case .accepted:
                sendFeedback = "已发送，正在同步。"
                await discardAttachmentsAfterDurableSend()
                draft = ""
                mentionHandlesText = ""
            case .queuedForRetry:
                sendFeedback = "已安全保存，连接恢复后会重试。"
                await discardAttachmentsAfterDurableSend()
                draft = ""
                mentionHandlesText = ""
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
        guard let publicIdentityResolver else {
            sendFeedback = "身份目录暂不可用，无法解析提及对象。"
            throw V2ConversationMentionInputError.invalidInput
        }
        var mentions: [V2MentionTarget] = []
        for handle in handles {
            if handle.lowercased() == "@all" {
                mentions.append(.everyone)
                continue
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
            return "发送频率已达上限，请稍后再试。"
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
        groupActorRole == "群主"
    }

    func canRemoveGroupMember(_ member: V2GroupMemberItem) -> Bool {
        guard member.id != userID, member.role != "群主" else { return false }
        return groupActorRole == "群主" || groupActorRole == "管理员"
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

    @Bindable var store: V2ConversationListStore
    let localE2EConversationLaunchFixture: V2LiveLocalAccountE2EConversationLaunchFixture?
    private let accountMenu: V2ConversationAccountMenu?
    @State private var navigationPath = NavigationPath()
    @State private var newConversationSheet: NewConversationSheet?
    @State private var directTargetUserID: String
    @State private var localE2EFixtureRoomID: String?
    @State private var groupTitle = ""
    @State private var groupMemberUserIDs = ""
    @State private var directSubmissionTask: Task<Void, Never>?
    @State private var groupSubmissionTask: Task<Void, Never>?

    init(
        store: V2ConversationListStore,
        localE2EConversationLaunchFixture: V2LiveLocalAccountE2EConversationLaunchFixture? = nil,
        accountMenu: V2ConversationAccountMenu? = nil
    ) {
        self.store = store
        self.localE2EConversationLaunchFixture = localE2EConversationLaunchFixture
        self.accountMenu = accountMenu
        _directTargetUserID = State(
            initialValue: localE2EConversationLaunchFixture?.directTargetHandle ?? ""
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
                        .accessibilityIdentifier("v2.conversation.\(item.id)")
                    }
                    .accessibilityIdentifier("v2.conversation.list")
                }
            }
            .navigationTitle("消息")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
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
                            : nil
                    )
                )
            }
            .task { await store.observeProjectionChanges() }
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
                            Button("取消") { newConversationSheet = nil }
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
                    }
                }
                }
            }
        }
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

private struct V2ConversationDetailView: View {
    private enum PresentedDetailSheet: Identifiable {
        case groupMembers
        case edit(V2ConversationMessageItem)

        var id: String {
            switch self {
            case .groupMembers:
                "groupMembers"
            case .edit(let message):
                "edit-\(message.id)"
            }
        }
    }

    @State private var store: V2ConversationDetailStore
    @State private var presentedDetailSheet: PresentedDetailSheet?
    @State private var isPresentingAttachmentImporter = false

    init(store: V2ConversationDetailStore) {
        _store = State(initialValue: store)
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
                    if store.messages.isEmpty {
                        ContentUnavailableView("暂无消息", systemImage: "bubble")
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(store.messages) { message in
                                    V2ConversationMessageRow(store: store, message: message) {
                                        presentedDetailSheet = .edit(message)
                                    }
                                }
                            }
                            .padding()
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
                        TextField("提及（@all 或 @handle）", text: $store.mentionHandlesText)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .disabled(store.isSending)
                            .accessibilityHint("输入 @all 或成员公开 ID，用逗号或换行分隔；最多 20 个")
                            .accessibilityIdentifier("v2.message.mentions")
                            .padding(.horizontal)
                            .padding(.top, 8)
                    }
                    HStack(alignment: .bottom) {
                        Button("添加附件", systemImage: "paperclip") {
                            isPresentingAttachmentImporter = true
                        }
                        .disabled(!store.canAddAttachment)
                        .tint(.primary)
                        .accessibilityHint("从文件中选择要发送的附件")
                        .accessibilityIdentifier("v2.message.attachment.add")
                        TextField("消息", text: $store.draft, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1 ... 4)
                            .disabled(store.isSending)
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
        .toolbar {
            if store.isGroupConversation {
                Button("成员", systemImage: "person.3") {
                    presentedDetailSheet = .groupMembers
                }
                .accessibilityHint("查看和管理群成员")
                .accessibilityIdentifier("v2.group.members")
            }
        }
        .sheet(item: $presentedDetailSheet) { sheet in
            switch sheet {
            case .groupMembers:
                V2GroupMembersSheet(store: store)
            case .edit(let message):
                V2MessageEditSheet(store: store, message: message)
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
    }

    private var canSendDraft: Bool {
        !store.isSending
            && (!store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.attachments.isEmpty)
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

    var body: some View {
        HStack {
            if message.isOutgoing { Spacer(minLength: 44) }
            V2ConversationMessageBubble(store: store, message: message, beginEditing: beginEditing)
            if !message.isOutgoing { Spacer(minLength: 44) }
        }
        .accessibilityIdentifier("v2.message.row.\(message.id)")
    }
}

private struct V2ConversationMessageBubble: View {
    @Bindable var store: V2ConversationDetailStore
    let message: V2ConversationMessageItem
    let beginEditing: () -> Void

    var body: some View {
        VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 3) {
            if !message.text.isEmpty {
                Text(message.text)
                    .foregroundStyle(message.isWithdrawn ? .secondary : .primary)
            }
            if !message.mentions.isEmpty {
                Text(mentionSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(mentionSummary)
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
                            index: index
                        )
                    }
                }
                .accessibilityIdentifier("v2.message.attachments.\(message.id)")
            }
            Text(message.createdAt, format: .dateTime.hour().minute())
                .font(.caption)
                .foregroundStyle(.primary)
            if store.canReactToMessage(message) {
                V2ConversationReactionControls(store: store, message: message)
            }
        }
        .padding(10)
        .background(message.isOutgoing ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .contextMenu {
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
        }
        .modifier(V2MessageAccessibilityActions(
            canEdit: store.canEditMessage(message),
            canWithdraw: store.canWithdrawMessage(message),
            edit: beginEditing,
            withdraw: { Task { await store.withdrawMessage(message) } }
        ))
    }

    private var attachmentSummary: String {
        "\(message.media.count) 个附件"
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
    let index: Int

    var body: some View {
        switch store.mediaDownloadState(for: media) {
        case .notDownloaded:
            downloadButton(title: "下载附件", systemImage: "arrow.down.circle")
        case .downloading:
            Label("正在下载附件", systemImage: "arrow.down.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("正在下载附件")
                .accessibilityIdentifier(identifier)
        case .downloaded(let downloaded):
            ShareLink(item: downloaded.fileURL) {
                Label("分享附件", systemImage: "square.and.arrow.up")
            }
            .font(.caption)
            .accessibilityLabel("分享附件")
            .accessibilityHint("打开系统分享菜单")
            .accessibilityIdentifier(identifier)
        case .failed:
            downloadButton(title: "重新下载附件", systemImage: "arrow.clockwise")
        }
    }

    @ViewBuilder
    private func downloadButton(title: String, systemImage: String) -> some View {
        Button(title, systemImage: systemImage) {
            Task { await store.downloadMedia(media, from: message) }
        }
        .font(.caption)
        .accessibilityHint("重新验证权限后下载到此设备")
        .accessibilityIdentifier(identifier)
    }

    private var identifier: String {
        "v2.message.media." + message.id + "." + String(index)
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
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
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
