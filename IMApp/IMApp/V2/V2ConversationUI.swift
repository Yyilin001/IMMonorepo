import Foundation
import IMV2ClientKit
import IMV2Core
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// App-facing, value-only view data. The UI never reads SQLite rows or sync
/// event payloads directly, which keeps navigation and rendering testable.
struct V2ConversationListItem: Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let preview: String
    let lastActivity: Date
    let isOutgoing: Bool
}

struct V2ConversationMessageItem: Hashable, Identifiable, Sendable {
    let id: String
    let roomSequence: UInt64
    let revision: UInt64
    let text: String
    /// Opaque media IDs from the local projection. The UI may show that a
    /// message has attachments, but never receives a provider URL here.
    let media: [V2MediaReference]
    let createdAt: Date
    let isOutgoing: Bool
    let isWithdrawn: Bool
    let reactions: [V2ConversationMessageReaction]

    init(id: String, roomSequence: UInt64 = 1, revision: UInt64, text: String, media: [V2MediaReference] = [], createdAt: Date, isOutgoing: Bool, isWithdrawn: Bool, reactions: [V2ConversationMessageReaction] = []) {
        self.id = id
        self.roomSequence = roomSequence
        self.revision = revision
        self.text = text
        self.media = media
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
        let summaries = try await localStore.conversationSummaries()
        let messageItems: [V2ConversationListItem] = summaries.map { summary in
            let message = summary.lastMessage
            return V2ConversationListItem(
                id: summary.roomID.rawValue,
                title: titles[summary.roomID] ?? Self.roomTitle(summary.roomID.rawValue),
                preview: Self.preview(for: message),
                lastActivity: message.createdAt,
                isOutgoing: message.senderUserID.rawValue == userID
            )
        }
        let knownRoomIDs = Set(messageItems.map(\.id))
        let emptyItems: [V2ConversationListItem] = profiles.compactMap { profile in
            guard !knownRoomIDs.contains(profile.roomID.rawValue) else { return nil }
            return V2ConversationListItem(
                id: profile.roomID.rawValue,
                title: profile.title,
                preview: "暂无消息",
                lastActivity: profile.createdAt,
                isOutgoing: false
            )
        }
        return (messageItems + emptyItems).sorted { lhs, rhs in
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
        "会话 " + String(roomID.suffix(6))
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
    private let groupConversationCreator: (any V2GroupConversationCreating)?
    private let groupMemberDirectory: (any V2GroupMemberDirectoryReading)?
    private let groupMembershipChanger: (any V2GroupMembershipChanging)?
    private let attachmentStager: (any V2ConversationAttachmentStaging)?
    private let attachmentUploader: (any V2ConversationAttachmentUploading)?
    private let mediaDownloader: (any V2ConversationMediaDownloading)?
    private(set) var items: [V2ConversationListItem] = []
    private(set) var state: State = .loading
    private(set) var directConversationFeedback: String?
    private(set) var groupConversationFeedback: String?

    init(
        dataSource: any V2ConversationDataSource,
        userID: String,
        sender: (any V2ConversationSending)? = nil,
        messageWithdrawer: (any V2MessageWithdrawing)? = nil,
        messageReactionChanger: (any V2MessageReactionChanging)? = nil,
        messageEditor: (any V2MessageEditing)? = nil,
        readReceiptReporter: (any V2ConversationReadReporting)? = nil,
        directConversationOpener: (any V2DirectConversationOpening)? = nil,
        groupConversationCreator: (any V2GroupConversationCreating)? = nil,
        groupMemberDirectory: (any V2GroupMemberDirectoryReading)? = nil,
        groupMembershipChanger: (any V2GroupMembershipChanging)? = nil,
        attachmentStager: (any V2ConversationAttachmentStaging)? = nil,
        attachmentUploader: (any V2ConversationAttachmentUploading)? = nil,
        mediaDownloader: (any V2ConversationMediaDownloading)? = nil
    ) {
        self.dataSource = dataSource
        self.userID = userID
        self.sender = sender
        self.messageWithdrawer = messageWithdrawer
        self.messageReactionChanger = messageReactionChanger
        self.messageEditor = messageEditor
        self.readReceiptReporter = readReceiptReporter
        self.directConversationOpener = directConversationOpener
        self.groupConversationCreator = groupConversationCreator
        self.groupMemberDirectory = groupMemberDirectory
        self.groupMembershipChanger = groupMembershipChanger
        self.attachmentStager = attachmentStager
        self.attachmentUploader = attachmentUploader
        self.mediaDownloader = mediaDownloader
    }

    func createGroupConversation(title: String, memberUserIDsText: String) async -> String? {
        let members = memberUserIDsText
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            groupConversationFeedback = "请输入群名称。"
            return nil
        }
        guard Set(members).count == members.count else {
            groupConversationFeedback = "成员用户 ID 不能重复。"
            return nil
        }
        guard let groupConversationCreator else {
            groupConversationFeedback = "实时网关尚未可用，无法创建群聊。"
            return nil
        }
        do {
            switch try await groupConversationCreator.createConversation(title: title, initialMemberUserIDs: members) {
            case .created(let roomID):
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
        state = .loading
        do {
            items = try await dataSource.conversationSummaries(for: userID)
            state = .loaded
        } catch is CancellationError {
            return
        } catch {
            state = .failed
        }
    }

    func detailStore(for roomID: String) -> V2ConversationDetailStore {
        .init(dataSource: dataSource, sender: sender, messageWithdrawer: messageWithdrawer, messageReactionChanger: messageReactionChanger, messageEditor: messageEditor, readReceiptReporter: readReceiptReporter, userID: userID, roomID: roomID, groupMemberDirectory: groupMemberDirectory, groupMembershipChanger: groupMembershipChanger, attachmentStager: attachmentStager, attachmentUploader: attachmentUploader, mediaDownloader: mediaDownloader)
    }

    func openDirectConversation(targetUserID: String) async -> String? {
        let target = targetUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            directConversationFeedback = "请输入对方的用户 ID。"
            return nil
        }
        guard let directConversationOpener else {
            directConversationFeedback = "实时网关尚未可用，无法新建会话。"
            return nil
        }
        do {
            let roomID = try await directConversationOpener.openConversation(with: target)
            directConversationFeedback = nil
            return roomID
        } catch is CancellationError {
            return nil
        } catch {
            directConversationFeedback = "无法创建会话，请检查用户 ID 和网络连接。"
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
    private let attachmentStager: (any V2ConversationAttachmentStaging)?
    private let attachmentUploader: (any V2ConversationAttachmentUploading)?
    private let mediaDownloader: (any V2ConversationMediaDownloading)?
    let roomID: String
    private(set) var messages: [V2ConversationMessageItem] = []
    private(set) var state: State = .loading
    private(set) var sendFeedback: String?
    private(set) var messageActionFeedback: String?
    private(set) var groupMembers: [V2GroupMemberItem] = []
    private(set) var groupMemberRevision: UInt64?
    private(set) var groupActorRole: String?
    private(set) var canLoadMoreGroupMembers = false
    private(set) var groupMemberFeedback: String?
    private(set) var attachments: [V2ConversationAttachmentItem] = []
    private(set) var mediaDownloadStates: [MediaID: V2ConversationMediaDownloadState] = [:]
    private var nextGroupMemberCursor: String?
    var draft = ""

    let reactionPresets = ["👍", "❤️", "😂", "🎉", "😢", "😡"]

    init(dataSource: any V2ConversationDataSource, sender: (any V2ConversationSending)?, messageWithdrawer: (any V2MessageWithdrawing)? = nil, messageReactionChanger: (any V2MessageReactionChanging)? = nil, messageEditor: (any V2MessageEditing)? = nil, readReceiptReporter: (any V2ConversationReadReporting)? = nil, userID: String, roomID: String, groupMemberDirectory: (any V2GroupMemberDirectoryReading)? = nil, groupMembershipChanger: (any V2GroupMembershipChanging)? = nil, attachmentStager: (any V2ConversationAttachmentStaging)? = nil, attachmentUploader: (any V2ConversationAttachmentUploading)? = nil, mediaDownloader: (any V2ConversationMediaDownloading)? = nil) {
        self.dataSource = dataSource
        self.sender = sender
        self.messageWithdrawer = messageWithdrawer
        self.messageReactionChanger = messageReactionChanger
        self.messageEditor = messageEditor
        self.readReceiptReporter = readReceiptReporter
        self.userID = userID
        self.roomID = roomID
        self.groupMemberDirectory = groupMemberDirectory
        self.groupMembershipChanger = groupMembershipChanger
        self.attachmentStager = attachmentStager
        self.attachmentUploader = attachmentUploader
        self.mediaDownloader = mediaDownloader
    }

    func refresh() async {
        state = .loading
        do {
            messages = try await dataSource.messages(in: roomID, for: userID)
            let visibleMediaIDs = Set(messages.lazy
                .filter { !$0.isWithdrawn }
                .flatMap(\.media)
                .map(\.mediaID))
            mediaDownloadStates = mediaDownloadStates.filter { visibleMediaIDs.contains($0.key) }
            state = .loaded
            await reportReadThroughVisibleMessages()
        } catch is CancellationError {
            return
        } catch {
            state = .failed
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
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        guard let sender else {
            sendFeedback = "实时网关尚未可用，无法发送。"
            return
        }
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
            switch try await sender.send(text: text, media: media, in: roomID) {
            case .accepted:
                sendFeedback = "已发送，正在同步。"
                await discardAttachmentsAfterDurableSend()
                draft = ""
            case .queuedForRetry:
                sendFeedback = "已安全保存，连接恢复后会重试。"
                await discardAttachmentsAfterDurableSend()
                draft = ""
            case .rejected(let code):
                sendFeedback = "发送被拒绝（\(code)）。"
            }
            await refresh()
        } catch is CancellationError {
            return
        } catch {
            sendFeedback = "无法保存待发送消息。"
        }
    }

    var canAddAttachment: Bool {
        attachments.count < V2MessageCommandLimits.maxMediaAttachments
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
        message.isOutgoing && !message.isWithdrawn && message.revision > 0
    }

    func withdrawMessage(_ message: V2ConversationMessageItem) async {
        guard canWithdrawMessage(message) else { return }
        guard let messageWithdrawer else {
            messageActionFeedback = "撤回暂不可用。"
            return
        }
        do {
            switch try await messageWithdrawer.withdraw(
                messageID: message.id,
                in: roomID,
                expectedMessageRevision: message.revision
            ) {
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
        !message.isWithdrawn
    }

    func canEditMessage(_ message: V2ConversationMessageItem) -> Bool {
        message.isOutgoing && !message.isWithdrawn && message.revision > 0
    }

    /// Returns whether it is safe for the editor to close. Rejected commands
    /// leave the text visible so the user can revise or retry it.
    func editMessage(_ message: V2ConversationMessageItem, text: String) async -> Bool {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canEditMessage(message), !trimmedText.isEmpty else { return false }
        guard let messageEditor else {
            messageActionFeedback = "编辑暂不可用。"
            return false
        }
        do {
            switch try await messageEditor.edit(
                messageID: message.id,
                in: roomID,
                expectedMessageRevision: message.revision,
                text: trimmedText
            ) {
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
        guard let messageReactionChanger else {
            messageActionFeedback = "反应暂不可用。"
            return
        }
        let action: V2MessageReactionAction = message.reactions.first(where: { $0.reaction == reaction })?.includesCurrentUser == true ? .remove : .add
        do {
            switch try await messageReactionChanger.changeReaction(
                messageID: message.id,
                in: roomID,
                reaction: reaction,
                action: action
            ) {
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

    func loadGroupMembers(reset: Bool = false) async {
        guard let groupMemberDirectory else {
            groupMemberFeedback = "成员目录暂不可用。"
            return
        }
        let cursor = reset ? nil : nextGroupMemberCursor
        if !reset, cursor == nil, !groupMembers.isEmpty { return }
        do {
            let page = try await groupMemberDirectory.members(in: roomID, cursor: cursor)
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

    func changeGroupMembership(targetUserID: String, action: V2RoomMembershipAction) async {
        let target = targetUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            groupMemberFeedback = "请输入成员用户 ID。"
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
        do {
            switch try await groupMembershipChanger.changeMembership(
                roomID: roomID,
                targetUserID: target,
                action: action,
                expectedMembershipRevision: revision
            ) {
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

struct V2ConversationListView: View {
    @Bindable var store: V2ConversationListStore
    @State private var navigationPath = NavigationPath()
    @State private var isPresentingDirectConversation = false
    @State private var isPresentingGroupConversation = false
    @State private var directTargetUserID = ""
    @State private var groupTitle = ""
    @State private var groupMemberUserIDs = ""

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
                Button("新建群聊", systemImage: "person.3") {
                    isPresentingGroupConversation = true
                }
                .accessibilityIdentifier("v2.conversation.new-group")
                Button("新建私聊", systemImage: "square.and.pencil") {
                    isPresentingDirectConversation = true
                }
                .accessibilityIdentifier("v2.conversation.new-direct")
                Button("刷新", systemImage: "arrow.clockwise") {
                    Task { await store.refresh() }
                }
                .accessibilityIdentifier("v2.conversation.refresh")
            }
            .navigationDestination(for: String.self) { roomID in
                V2ConversationDetailView(store: store.detailStore(for: roomID))
            }
            .task { await store.refresh() }
            .sheet(isPresented: $isPresentingDirectConversation) {
                NavigationStack {
                    Form {
                        Section("对方用户 ID") {
                            TextField("用户 ID", text: $directTargetUserID)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
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
                            Button("取消") { isPresentingDirectConversation = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("开始") {
                                Task {
                                    if let roomID = await store.openDirectConversation(targetUserID: directTargetUserID) {
                                        directTargetUserID = ""
                                        isPresentingDirectConversation = false
                                        navigationPath.append(roomID)
                                    }
                                }
                            }
                            .accessibilityIdentifier("v2.conversation.direct-submit")
                        }
                    }
                }
            }
            .sheet(isPresented: $isPresentingGroupConversation) {
                NavigationStack {
                    Form {
                        Section("群名称") {
                            TextField("群名称", text: $groupTitle)
                                .accessibilityIdentifier("v2.conversation.group-title")
                        }
                        Section("初始成员") {
                            TextEditor(text: $groupMemberUserIDs)
                                .frame(minHeight: 110)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .accessibilityLabel("初始成员用户 ID")
                                .accessibilityHint("用逗号或换行分隔；可留空创建仅自己的群聊")
                                .accessibilityIdentifier("v2.conversation.group-members")
                            Text("用逗号或换行分隔用户 ID。")
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
                            Button("取消") { isPresentingGroupConversation = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("创建") {
                                Task {
                                    if let roomID = await store.createGroupConversation(title: groupTitle, memberUserIDsText: groupMemberUserIDs) {
                                        groupTitle = ""
                                        groupMemberUserIDs = ""
                                        isPresentingGroupConversation = false
                                        navigationPath.append(roomID)
                                    }
                                }
                            }
                            .disabled(groupTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("v2.conversation.group-submit")
                        }
                    }
                }
            }
        }
    }
}

private struct V2ConversationDetailView: View {
    @State private var store: V2ConversationDetailStore
    @State private var isPresentingGroupMembers = false
    @State private var messageBeingEdited: V2ConversationMessageItem?
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
                                        messageBeingEdited = message
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
                    HStack(alignment: .bottom) {
                        Button("添加附件", systemImage: "paperclip") {
                            isPresentingAttachmentImporter = true
                        }
                        .disabled(!store.canAddAttachment)
                        .accessibilityHint("从文件中选择要发送的附件")
                        .accessibilityIdentifier("v2.message.attachment.add")
                        TextField("消息", text: $store.draft, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1 ... 4)
                            .accessibilityIdentifier("v2.message.draft")
                        Button("发送") { Task { await store.sendDraft() } }
                            .disabled(store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && store.attachments.isEmpty)
                            .accessibilityIdentifier("v2.message.send")
                    }
                    .padding()
                    if let sendFeedback = store.sendFeedback {
                        Text(sendFeedback)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                            .padding(.bottom, 8)
                            .accessibilityIdentifier("v2.message.send-feedback")
                    }
                    if let messageActionFeedback = store.messageActionFeedback {
                        Text(messageActionFeedback)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                            .padding(.bottom, 8)
                            .accessibilityIdentifier("v2.message.action-feedback")
                    }
                }
            }
        }
        .navigationTitle("会话 " + String(store.roomID.suffix(6)))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("成员", systemImage: "person.3") {
                isPresentingGroupMembers = true
            }
            .accessibilityIdentifier("v2.group.members")
        }
        .sheet(isPresented: $isPresentingGroupMembers) {
            V2GroupMembersSheet(store: store)
        }
        .sheet(item: $messageBeingEdited) { message in
            V2MessageEditSheet(store: store, message: message)
        }
        .fileImporter(
            isPresented: $isPresentingAttachmentImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await store.stageAttachment(from: url) }
        }
        .task { await store.refresh() }
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
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.displayName)
                    .lineLimit(1)
                Text(attachmentStatusText(for: attachment.state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("移除", role: .destructive) {
                Task { await store.removeAttachment(id: attachment.id) }
            }
            .accessibilityLabel(removalLabel)
            .accessibilityIdentifier(removeIdentifier)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(attachmentStatusText(for: attachment.state))
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
        .accessibilityIdentifier("v2.message.\(message.id)")
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
                .font(.caption2)
                .foregroundStyle(.secondary)
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
                .accessibilityIdentifier("v2.message.withdraw.\(message.id)")
            }
        }
    }

    private var attachmentSummary: String {
        "\(message.media.count) 个附件"
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
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text == message.text)
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
            }
            .accessibilityLabel("添加反应")
            .accessibilityIdentifier("v2.message.reaction-picker.\(message.id)")
        }
    }
}

private struct V2GroupMembersSheet: View {
    @Bindable var store: V2ConversationDetailStore
    @Environment(\.dismiss) private var dismiss
    @State private var newMemberUserID = ""

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
                        TextField("成员用户 ID", text: $newMemberUserID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("v2.group.members.add-input")
                        Button("添加") {
                            let target = newMemberUserID
                            newMemberUserID = ""
                            Task { await store.changeGroupMembership(targetUserID: target, action: .add) }
                        }
                        .disabled(newMemberUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("v2.group.members.add")
                    }
                }
                ForEach(store.groupMembers) { member in
                    HStack {
                        Text(member.id).textSelection(.enabled)
                        Spacer()
                        Text(member.role).foregroundStyle(.secondary)
                        if store.canRemoveGroupMember(member) {
                            Button("移除", role: .destructive) {
                                Task { await store.changeGroupMembership(targetUserID: member.id, action: .remove) }
                            }
                            .accessibilityIdentifier("v2.group.member.remove.\(member.id)")
                        }
                    }
                    .accessibilityIdentifier("v2.group.member.\(member.id)")
                }
                if store.canLoadMoreGroupMembers {
                    Button("加载更多") { Task { await store.loadGroupMembers() } }
                        .accessibilityIdentifier("v2.group.members.load-more")
                }
                if let feedback = store.groupMemberFeedback {
                    Text(feedback).foregroundStyle(.secondary)
                        .accessibilityIdentifier("v2.group.members.feedback")
                }
            }
            .overlay {
                if store.groupMembers.isEmpty, store.groupMemberFeedback == nil {
                    ProgressView("正在读取成员…")
                }
            }
            .navigationTitle("群成员")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("刷新") { Task { await store.loadGroupMembers(reset: true) } }
                }
            }
            .task { await store.loadGroupMembers(reset: true) }
        }
    }
}
