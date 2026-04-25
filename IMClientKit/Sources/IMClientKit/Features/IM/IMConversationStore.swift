import Combine
import Foundation

public enum IMConversationKind: String, Codable, Equatable, Sendable {
    case direct
    case group
}

public enum IMConversationMemberRole: String, Codable, Equatable, Sendable {
    case owner
    case admin
    case member

    public var canAddMembers: Bool {
        self == .owner || self == .admin
    }

    public var canRenameConversation: Bool {
        self == .owner || self == .admin
    }

    public var canManageRoles: Bool {
        self == .owner
    }

    public func canRemove(memberWithRole targetRole: IMConversationMemberRole) -> Bool {
        switch self {
        case .owner:
            return targetRole != .owner
        case .admin:
            return targetRole == .member
        case .member:
            return false
        }
    }
}

public enum IMMessageDirection: String, Equatable, Sendable {
    case incoming
    case outgoing
}

public enum IMMessageDeliveryState: Equatable, Sendable {
    case preparing(message: String)
    case uploading(message: String)
    case uploaded
    case queued(message: String)
    case sending
    case sent
    case received
    case unknown(message: String)
    case failed(message: String)
}

public struct IMMessageLocalTransferState: Codable, Equatable, Sendable {
    public let sourceFilePath: String
    public let uploadID: String?
    public let taskID: IMTransferTaskID?

    public init(
        sourceFilePath: String,
        uploadID: String? = nil,
        taskID: IMTransferTaskID? = nil
    ) {
        self.sourceFilePath = sourceFilePath
        self.uploadID = uploadID
        self.taskID = taskID
    }

    public var sourceFileURL: URL {
        URL(fileURLWithPath: sourceFilePath)
    }

    public func withUploadID(_ uploadID: String?) -> IMMessageLocalTransferState {
        IMMessageLocalTransferState(
            sourceFilePath: sourceFilePath,
            uploadID: uploadID,
            taskID: taskID
        )
    }

    public func withTaskID(_ taskID: IMTransferTaskID?) -> IMMessageLocalTransferState {
        IMMessageLocalTransferState(
            sourceFilePath: sourceFilePath,
            uploadID: uploadID,
            taskID: taskID
        )
    }
}

public struct IMMessageLocalDownloadProgressSnapshot: Codable, Equatable, Sendable {
    public let transferredBytes: Int64
    public let totalBytes: Int64?
    public let resumedBytes: Int64

    public init(
        transferredBytes: Int64,
        totalBytes: Int64?,
        resumedBytes: Int64 = 0
    ) {
        self.transferredBytes = transferredBytes
        self.totalBytes = totalBytes
        self.resumedBytes = resumedBytes
    }

    public init(_ progress: FileTransferProgress) {
        self.init(
            transferredBytes: progress.transferredBytes,
            totalBytes: progress.totalBytes,
            resumedBytes: progress.resumedBytes
        )
    }

    public var progress: FileTransferProgress {
        FileTransferProgress(
            transferredBytes: transferredBytes,
            totalBytes: totalBytes,
            resumedBytes: resumedBytes
        )
    }
}

public struct IMMessageBackgroundTransferReference: Codable, Equatable, Sendable {
    public let sessionIdentifier: String
    public let taskIdentifier: Int

    public init(sessionIdentifier: String, taskIdentifier: Int) {
        self.sessionIdentifier = sessionIdentifier
        self.taskIdentifier = taskIdentifier
    }
}

public enum IMMessageLocalDownloadStatus: Codable, Equatable, Sendable {
    case downloading(
        progress: IMMessageLocalDownloadProgressSnapshot?,
        backgroundTransfer: IMMessageBackgroundTransferReference?
    )
    case waitingForConnectivity(
        progress: IMMessageLocalDownloadProgressSnapshot?,
        backgroundTransfer: IMMessageBackgroundTransferReference?
    )
    case paused(progress: IMMessageLocalDownloadProgressSnapshot?)
    case downloaded
    case failed(message: String)
}

public struct IMMessageLocalDownloadState: Codable, Equatable, Sendable {
    public let destinationFilePath: String
    public let status: IMMessageLocalDownloadStatus
    public let taskID: IMTransferTaskID?

    public init(
        destinationFilePath: String,
        status: IMMessageLocalDownloadStatus,
        taskID: IMTransferTaskID? = nil
    ) {
        self.destinationFilePath = destinationFilePath
        self.status = status
        self.taskID = taskID
    }

    public var destinationFileURL: URL {
        URL(fileURLWithPath: destinationFilePath)
    }
}

public struct IMRecoverableOutgoingMediaUpload: Equatable, Sendable {
    public let localMessageID: String
    public let conversationID: String
    public let asset: IMMediaAsset
    public let transferState: IMMessageLocalTransferState
    public let deliveryState: IMMessageDeliveryState

    public init(
        localMessageID: String,
        conversationID: String,
        asset: IMMediaAsset,
        transferState: IMMessageLocalTransferState,
        deliveryState: IMMessageDeliveryState
    ) {
        self.localMessageID = localMessageID
        self.conversationID = conversationID
        self.asset = asset
        self.transferState = transferState
        self.deliveryState = deliveryState
    }
}

public struct IMConversationMessage: Identifiable, Equatable, Sendable {
    public let id: String
    public let conversationID: String
    public let clientMessageID: String?
    public var serverMessageID: String?
    public var senderUserID: UUID?
    public var serverSequence: UInt64?
    public var content: IMMessageContent
    public let direction: IMMessageDirection
    public var createdAt: Date
    public var deliveryState: IMMessageDeliveryState
    public var localTransferState: IMMessageLocalTransferState?
    public var localDownloadState: IMMessageLocalDownloadState?

    public var text: String {
        content.previewText
    }

    public var mediaAsset: IMMediaAsset? {
        content.presentation.mediaAsset
    }

    public var isRecoverableOutgoingMediaUpload: Bool {
        guard direction == .outgoing,
              localTransferState != nil,
              mediaAsset != nil
        else {
            return false
        }

        switch deliveryState {
        case .preparing, .uploading, .uploaded:
            return true
        case .queued, .sending, .sent, .received, .unknown, .failed:
            return false
        }
    }

    public init(
        id: String,
        conversationID: String,
        clientMessageID: String?,
        serverMessageID: String?,
        senderUserID: UUID?,
        serverSequence: UInt64?,
        content: IMMessageContent,
        direction: IMMessageDirection,
        createdAt: Date,
        deliveryState: IMMessageDeliveryState,
        localTransferState: IMMessageLocalTransferState? = nil,
        localDownloadState: IMMessageLocalDownloadState? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.clientMessageID = clientMessageID
        self.serverMessageID = serverMessageID
        self.senderUserID = senderUserID
        self.serverSequence = serverSequence
        self.content = content
        self.direction = direction
        self.createdAt = createdAt
        self.deliveryState = deliveryState
        self.localTransferState = localTransferState
        self.localDownloadState = localDownloadState
    }
}

public enum IMReplyReferenceResolutionState: Equatable, Sendable {
    case loaded
    case unavailable
    case recalled
}

public struct IMReplyReferenceResolution: Equatable, Sendable {
    public let state: IMReplyReferenceResolutionState
    public let text: String

    public init(state: IMReplyReferenceResolutionState, text: String) {
        self.state = state
        self.text = text
    }
}

public extension IMConversationMessage {
    func resolvedReplyReference(in messages: [IMConversationMessage]) -> IMReplyReferenceResolution? {
        MessageDerivedStateReducer().resolveReplyReference(for: self, in: messages)
    }
}

public struct IMConversationMember: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let email: String
    public let role: IMConversationMemberRole
}

public struct IMDirectPeer: Equatable, Sendable {
    public let id: UUID
    public let email: String
    public let displayName: String?
    public let avatarPreset: UserAvatarPreset?

    public init(
        id: UUID,
        email: String,
        displayName: String? = nil,
        avatarPreset: UserAvatarPreset? = nil
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.avatarPreset = avatarPreset
    }
}

public struct IMConversation: Identifiable, Equatable, Sendable {
    public let id: String
    public var title: String
    public var kind: IMConversationKind
    public var directMessagingState: IMDirectMessagingState?
    public var directPeer: IMDirectPeer?
    public var notice: String?
    public var avatarPreset: IMConversationAvatarPreset?
    public var memberCount: Int
    public var memberUserIDs: [UUID]
    public var members: [IMConversationMember]
    public var messages: [IMConversationMessage]
    public var lastMessagePreviewText: String
    public var hasMoreHistory: Bool
    public var serverLastReadSequence: UInt64
    public var serverUnreadCount: Int
    public var localUnreadDelta: Int
    public var isPinned: Bool
    public var pinnedAt: Date?
    public var isMuted: Bool
    public var draftText: String
    public var draftUpdatedAt: Date?
    public var updatedAt: Date

    public var unreadCount: Int {
        max(0, serverUnreadCount + localUnreadDelta)
    }

    public var lastMessagePreview: String {
        lastMessagePreviewText
    }

    public var isDirectMessagingFrozen: Bool {
        kind == .direct && directMessagingState == .frozenAfterUnfriend
    }

    public var canSendMessages: Bool {
        !isDirectMessagingFrozen
    }

    public var directMessagingStatusMessage: String? {
        guard isDirectMessagingFrozen else {
            return nil
        }

        return "你们已不是好友，当前会话不能继续发送消息。"
    }

    public init(
        id: String,
        title: String,
        kind: IMConversationKind,
        directMessagingState: IMDirectMessagingState? = nil,
        directPeer: IMDirectPeer? = nil,
        notice: String? = nil,
        avatarPreset: IMConversationAvatarPreset? = nil,
        memberCount: Int,
        memberUserIDs: [UUID],
        members: [IMConversationMember],
        messages: [IMConversationMessage],
        lastMessagePreviewText: String,
        hasMoreHistory: Bool,
        serverLastReadSequence: UInt64,
        serverUnreadCount: Int,
        localUnreadDelta: Int,
        isPinned: Bool = false,
        pinnedAt: Date? = nil,
        isMuted: Bool = false,
        draftText: String = "",
        draftUpdatedAt: Date? = nil,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.directMessagingState = directMessagingState
        self.directPeer = directPeer
        self.notice = notice
        self.avatarPreset = avatarPreset
        self.memberCount = memberCount
        self.memberUserIDs = memberUserIDs
        self.members = members
        self.messages = messages
        self.lastMessagePreviewText = lastMessagePreviewText
        self.hasMoreHistory = hasMoreHistory
        self.serverLastReadSequence = serverLastReadSequence
        self.serverUnreadCount = serverUnreadCount
        self.localUnreadDelta = localUnreadDelta
        self.isPinned = isPinned
        self.pinnedAt = pinnedAt
        self.isMuted = isMuted
        self.draftText = draftText
        self.draftUpdatedAt = draftUpdatedAt
        self.updatedAt = updatedAt
    }
}

public struct IMOutgoingMessageRequest: Sendable {
    public let requestID: UUID
    public let localMessageID: String
    public let payload: IMTCPMessagePayload
}

public struct IMOutgoingMediaPlaceholder: Sendable {
    public let localMessageID: String
    public let clientMessageID: String
}

public struct IMConversationQueueSummary: Equatable, Sendable {
    public let queuedCount: Int
    public let sendingCount: Int
    public let retryableIssueCount: Int

    public var hasPendingWork: Bool {
        queuedCount > 0 || sendingCount > 0 || retryableIssueCount > 0
    }

    public init(queuedCount: Int, sendingCount: Int, retryableIssueCount: Int) {
        self.queuedCount = queuedCount
        self.sendingCount = sendingCount
        self.retryableIssueCount = retryableIssueCount
    }
}

public struct IMConversationEventApplyOutcome: Equatable, Sendable {
    public let shouldReloadMembersForConversationID: String?
}

@MainActor
public final class IMConversationStore: ObservableObject {
    @Published public private(set) var conversations: [IMConversation] = []
    @Published public private(set) var selectedConversationID: String?
    @Published public private(set) var statusMessage: String?
    @Published public private(set) var isLoadingConversations = false
    @Published public private(set) var conversationSummaryNextCursor: String?
    @Published public private(set) var hasMoreConversationSummaries = false
    @Published public private(set) var isLoadingMoreConversationSummaries = false
    @Published public private(set) var isLoadingMembers = false
    @Published public private(set) var isLoadingMessages = false
    @Published public private(set) var searchText = ""
    @Published public private(set) var replyJumpConversationID: String?
    @Published public private(set) var replyJumpTargetMessageID: String?
    @Published public private(set) var replyJumpMatchedMessageID: String?
    @Published public private(set) var replyJumpState: IMReplyJumpState = .idle

    private let listReadModel = ConversationListReadModel()
    private var detailState = ConversationDetailState()
    private var outgoingQueueState = OutgoingQueueState()
    private var conversationSearchState = ConversationSearchState()
    private let messageTimelineState = MessageTimelineState()
    private let messageDerivedStateReducer = MessageDerivedStateReducer()

    public var selectedConversation: IMConversation? {
        listReadModel.selectedConversation(
            in: conversations,
            selectedConversationID: selectedConversationID
        )
    }

    public init() { }

    public var totalUnreadCount: Int {
        listReadModel.totalUnreadCount(in: conversations.filter { !$0.isMuted })
    }

    public var conversationSummaryPaginationAnchorID: String? {
        conversations.last?.id
    }

    public func queueSummary(for conversationID: String) -> IMConversationQueueSummary {
        listReadModel.queueSummary(
            in: conversations,
            for: conversationID,
            summarize: queueSummary(for:)
        )
    }

    public func totalQueueSummary() -> IMConversationQueueSummary {
        listReadModel.totalQueueSummary(
            in: conversations,
            summarize: queueSummary(for:)
        )
    }

    public func reset() {
        conversations = []
        selectedConversationID = nil
        statusMessage = nil
        isLoadingConversations = false
        conversationSummaryNextCursor = nil
        hasMoreConversationSummaries = false
        isLoadingMoreConversationSummaries = false
        detailState.reset()
        outgoingQueueState.reset()
        isLoadingMembers = detailState.isLoadingMembers
        isLoadingMessages = detailState.isLoadingMessages
        conversationSearchState.reset()
        searchText = conversationSearchState.text
        syncReplyJumpState()
    }

    public func setConversationSearchText(_ value: String) {
        conversationSearchState.setText(value)
        searchText = conversationSearchState.text
    }

    public var filteredConversations: [IMConversation] {
        conversationSearchState.filteredConversations(from: conversations)
    }

    public func openConversation(id: String) {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            statusMessage = "当前没有可用会话。"
            return
        }

        _ = ensureConversationIndex(for: trimmedID)
        selectedConversationID = trimmedID
        statusMessage = nil
        sortConversations()
    }

    public func replaceConversationSummaries(_ responses: [IMConversationSummaryResponseBody]) {
        applyConversationSummaryContents(responses)
    }

    public func applyConversationSummaryPage(_ responses: [IMConversationSummaryResponseBody]) {
        for response in responses {
            upsertConversationSummaryContent(response)
        }
    }

    public func applyConversationSummaryChanges(
        upserts: [IMConversationSummaryResponseBody],
        removedConversationIDs: [UUID]
    ) {
        for response in upserts {
            upsertConversationSummaryContent(response)
        }

        for conversationID in removedConversationIDs {
            removeConversation(id: conversationID.uuidString)
        }
    }

    public func replaceConversationSummaryWindow(
        _ responses: [IMConversationSummaryResponseBody],
        nextCursor: String?,
        hasMore: Bool
    ) {
        let existingByID = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
        let previousSelectedConversationID = selectedConversationID

        conversations = responses.map { response in
            let conversationID = response.id.uuidString
            return conversationSummary(
                from: response,
                existing: existingByID[conversationID]
            )
        }

        conversationSummaryNextCursor = nextCursor
        hasMoreConversationSummaries = hasMore
        isLoadingMoreConversationSummaries = false

        if let previousSelectedConversationID,
           conversations.contains(where: { $0.id == previousSelectedConversationID }) {
            selectedConversationID = previousSelectedConversationID
        } else {
            selectedConversationID = conversations.first?.id
        }

        statusMessage = nil
        sortConversations()
    }

    public func appendConversationSummaryWindow(
        _ responses: [IMConversationSummaryResponseBody],
        nextCursor: String?,
        hasMore: Bool
    ) {
        for response in responses {
            upsertConversationSummaryContent(response)
        }

        conversationSummaryNextCursor = nextCursor
        hasMoreConversationSummaries = hasMore
        isLoadingMoreConversationSummaries = false
    }

    public func removeConversationSummaries(notIn conversationIDs: Set<String>) {
        let trimmedIDs = Set(
            conversationIDs
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )

        conversations.removeAll { !trimmedIDs.contains($0.id) }

        if let selectedConversationID, !trimmedIDs.contains(selectedConversationID) {
            self.selectedConversationID = conversations.first?.id
        }
    }

    public func applyConversationSummaryContents(_ responses: [IMConversationSummaryResponseBody]) {
        let existingByID = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
        let serverIDs = Set(responses.map { $0.id.uuidString })
        let previousSelectedConversationID = selectedConversationID

        var merged = responses.map { response in
            let conversationID = response.id.uuidString
            let existing = existingByID[conversationID]
            let conversationKind = IMConversationKind(rawValue: response.kind) ?? .group
            let directPeer = directPeer(from: response, conversationKind: conversationKind)
            let previewText = messageDerivedStateReducer.mergedSummaryPreviewText(
                existing: existing,
                responseLastMessage: response.lastMessage
            )

            return IMConversation(
                id: conversationID,
                title: normalizedTitle(
                    response.title,
                    conversationID: conversationID,
                    conversationKind: conversationKind,
                    directPeer: directPeer
                ),
                kind: conversationKind,
                directMessagingState: directMessagingState(
                    from: response.directMessagingState,
                    conversationKind: conversationKind
                ),
                directPeer: directPeer,
                notice: response.notice,
                avatarPreset: response.avatarPreset,
                memberCount: response.memberCount,
                memberUserIDs: response.memberUserIDs.sorted { $0.uuidString < $1.uuidString },
                members: existing?.members ?? [],
                messages: existing?.messages ?? [],
                lastMessagePreviewText: previewText,
                hasMoreHistory: existing?.hasMoreHistory ?? false,
                serverLastReadSequence: UInt64(response.lastReadSequence),
                serverUnreadCount: response.unreadCount,
                localUnreadDelta: existing?.localUnreadDelta ?? 0,
                isPinned: response.isPinned,
                pinnedAt: response.pinnedAt,
                isMuted: response.isMuted,
                draftText: existing?.draftText ?? "",
                draftUpdatedAt: existing?.draftUpdatedAt,
                updatedAt: response.updatedAt
            )
        }

        merged.append(contentsOf: conversations.filter { !serverIDs.contains($0.id) })
        conversations = merged

        if let previousSelectedConversationID,
           conversations.contains(where: { $0.id == previousSelectedConversationID }) {
            selectedConversationID = previousSelectedConversationID
        } else {
            selectedConversationID = conversations.first?.id
        }

        statusMessage = nil
        sortConversations()
    }

    public func applyConversationSummaryContent(_ response: IMConversationSummaryResponseBody) {
        upsertConversationSummaryContent(response)
    }

    public func removeConversation(id: String) {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            return
        }

        conversations.removeAll { $0.id == trimmedID }
        detailState.removeConversation(id: trimmedID)

        if selectedConversationID == trimmedID {
            selectedConversationID = conversations.first?.id
        } else if selectedConversationID != nil,
                  conversations.contains(where: { $0.id == selectedConversationID }) {
            // Preserve current selection when removing another conversation.
        } else {
            selectedConversationID = conversations.first?.id
        }

        syncReplyJumpState()
    }

    public func markConversationRead(id: String) {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty,
              let index = conversations.firstIndex(where: { $0.id == trimmedID })
        else {
            return
        }

        if let latestLoadedSequence = latestLoadedServerSequence(for: trimmedID) {
            conversations[index].serverLastReadSequence = latestLoadedSequence
        }
        resetUnreadState(for: index)
    }

    public func applyServerSummaryReadState(
        lastReadSequence: UInt64,
        unreadCount: Int,
        for conversationID: String
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty,
              let index = conversations.firstIndex(where: { $0.id == trimmedConversationID })
        else {
            return
        }

        let previousServerLastReadSequence = conversations[index].serverLastReadSequence
        let previousServerUnreadCount = conversations[index].serverUnreadCount
        let previousLocalUnreadDelta = conversations[index].localUnreadDelta
        conversations[index].serverLastReadSequence = lastReadSequence
        conversations[index].serverUnreadCount = max(0, unreadCount)
        conversations[index].localUnreadDelta = reconciledLocalUnreadDelta(
            for: trimmedConversationID,
            previousServerLastReadSequence: previousServerLastReadSequence,
            previousServerUnreadCount: previousServerUnreadCount,
            previousLocalUnreadDelta: previousLocalUnreadDelta,
            updatedServerLastReadSequence: lastReadSequence,
            updatedServerUnreadCount: max(0, unreadCount)
        )
    }

    public func applyServerSummaryReadStates(_ responses: [IMConversationSummaryResponseBody]) {
        for response in responses {
            applyServerSummaryReadState(response)
        }
    }

    public func applyServerSummaryReadState(_ response: IMConversationSummaryResponseBody) {
        applyServerSummaryReadState(
            lastReadSequence: UInt64(response.lastReadSequence),
            unreadCount: response.unreadCount,
            for: response.id.uuidString
        )
    }

    public func applyServerExplicitReadResponse(_ response: IMConversationReadResponseBody) {
        applyServerReadState(
            lastReadSequence: UInt64(response.lastReadSequence),
            unreadCount: response.unreadCount,
            for: response.conversationID.uuidString
        )
    }

    public func applyServerReadState(
        lastReadSequence: UInt64,
        unreadCount: Int,
        for conversationID: String
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty,
              let index = conversations.firstIndex(where: { $0.id == trimmedConversationID })
        else {
            return
        }

        conversations[index].serverLastReadSequence = lastReadSequence
        conversations[index].serverUnreadCount = max(0, unreadCount)
        conversations[index].localUnreadDelta = 0
    }

    public func applyRealtimeUnreadIncrement(for conversationID: String) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty,
              let index = conversations.firstIndex(where: { $0.id == trimmedConversationID })
        else {
            return
        }

        guard selectedConversationID != trimmedConversationID else {
            resetUnreadState(for: index)
            return
        }

        conversations[index].localUnreadDelta += 1
    }

    public func applyServerUnreadCount(_ unreadCount: Int, for conversationID: String) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty,
              let index = conversations.firstIndex(where: { $0.id == trimmedConversationID })
        else {
            return
        }

        conversations[index].serverUnreadCount = max(0, unreadCount)
    }

    public func applyConversationEvent(
        _ payload: IMTCPConversationEventPayload,
        currentUserID: UUID
    ) -> IMConversationEventApplyOutcome {
        let conversationID = payload.conversation.id.uuidString
        let selectedConversationIDBeforeApply = selectedConversationID

        switch payload.eventType {
        case .conversationCreated:
            applyConversationSummaryContent(payload.conversation)
            applyServerSummaryReadState(payload.conversation)
            return IMConversationEventApplyOutcome(
                shouldReloadMembersForConversationID: selectedConversationIDBeforeApply == conversationID ? conversationID : nil
            )

        case .membersAdded, .memberLeft, .membersUpdated:
            applyConversationSummaryContent(payload.conversation)
            applyServerSummaryReadState(payload.conversation)
            return IMConversationEventApplyOutcome(
                shouldReloadMembersForConversationID: selectedConversationIDBeforeApply == conversationID ? conversationID : nil
            )

        case .conversationRemovedForSelf:
            removeConversation(id: conversationID)
            return IMConversationEventApplyOutcome(shouldReloadMembersForConversationID: nil)

        case .summaryUpdated:
            applyConversationSummaryContent(payload.conversation)
            applyServerSummaryReadState(payload.conversation)
            return IMConversationEventApplyOutcome(shouldReloadMembersForConversationID: nil)

        case .messageRecalled:
            applyConversationSummaryContent(payload.conversation)
            applyServerSummaryReadState(payload.conversation)
            if let message = payload.message {
                applyRecalledMessage(message, currentUserID: currentUserID)
            }
            return IMConversationEventApplyOutcome(shouldReloadMembersForConversationID: nil)
        }
    }

    public func replaceMessages(
        in conversationID: String,
        messages responses: [IMConversationMessageResponseBody],
        currentUserID: UUID
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        let index = ensureConversationIndex(for: trimmedConversationID)
        let serverMessages = makeMessages(from: responses, currentUserID: currentUserID)
        let mergedMessages = mergeMessages(
            existing: conversations[index].messages,
            serverMessages: serverMessages,
            preserveExistingServerMessages: false
        )
        conversations[index].messages = mergedMessages
        conversations[index].lastMessagePreviewText = mergedMessages.last?.text ?? conversations[index].lastMessagePreviewText
        conversations[index].updatedAt = mergedMessages.last?.createdAt ?? conversations[index].updatedAt
        conversations[index].hasMoreHistory = hasOlderHistory(in: serverMessages)
        refreshLoadedMessageCursors(
            for: trimmedConversationID,
            messages: mergedMessages
        )
        statusMessage = nil
        sortConversations()
    }

    public func appendMessages(
        in conversationID: String,
        messages responses: [IMConversationMessageResponseBody],
        currentUserID: UUID
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        let index = ensureConversationIndex(for: trimmedConversationID)
        let serverMessages = makeMessages(from: responses, currentUserID: currentUserID)
        let mergedMessages = mergeMessages(
            existing: conversations[index].messages,
            serverMessages: serverMessages,
            preserveExistingServerMessages: true
        )

        conversations[index].messages = mergedMessages
        conversations[index].lastMessagePreviewText = mergedMessages.last?.text ?? conversations[index].lastMessagePreviewText
        conversations[index].updatedAt = mergedMessages.last?.createdAt ?? conversations[index].updatedAt
        refreshLatestSyncedCursor(
            for: trimmedConversationID,
            messages: mergedMessages
        )
        statusMessage = nil
        sortConversations()
    }

    public func replaceMembers(
        in conversationID: String,
        members responses: [IMConversationMemberResponseBody]
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        let index = ensureConversationIndex(for: trimmedConversationID)
        let members = responses
            .map {
                IMConversationMember(
                    id: $0.id,
                    email: $0.email,
                    role: $0.role
                )
            }
            .sorted(by: sortMembers)

        conversations[index].members = members
        conversations[index].memberUserIDs = members.map(\.id).sorted { $0.uuidString < $1.uuidString }
        conversations[index].memberCount = members.count
        statusMessage = nil
    }

    public func updateDraft(_ text: String, for conversationID: String) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty,
              let index = conversations.firstIndex(where: { $0.id == trimmedConversationID })
        else {
            return
        }

        conversations[index].draftText = text
        conversations[index].draftUpdatedAt = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : Date()
    }

    public func draftText(for conversationID: String) -> String {
        conversations.first(where: { $0.id == conversationID })?.draftText ?? ""
    }

    public func applyConversationPreferences(
        conversationID: String,
        isPinned: Bool,
        pinnedAt: Date?,
        isMuted: Bool
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty,
              let index = conversations.firstIndex(where: { $0.id == trimmedConversationID })
        else {
            return
        }

        conversations[index].isPinned = isPinned
        conversations[index].pinnedAt = pinnedAt
        conversations[index].isMuted = isMuted
        sortConversations()
    }

    public func applyConversationMetadata(
        conversationID: String,
        title: String?,
        notice: String?,
        avatarPreset: IMConversationAvatarPreset?
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty,
              let index = conversations.firstIndex(where: { $0.id == trimmedConversationID })
        else {
            return
        }

        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedTitle, !trimmedTitle.isEmpty {
            conversations[index].title = trimmedTitle
        }
        conversations[index].notice = notice?.trimmingCharacters(in: .whitespacesAndNewlines)
        conversations[index].avatarPreset = avatarPreset
        sortConversations()
    }

    public func prependMessages(
        in conversationID: String,
        messages responses: [IMConversationMessageResponseBody],
        currentUserID: UUID
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        let index = ensureConversationIndex(for: trimmedConversationID)
        let serverMessages = makeMessages(from: responses, currentUserID: currentUserID)
        let mergedMessages = mergeMessages(
            existing: conversations[index].messages,
            serverMessages: serverMessages,
            preserveExistingServerMessages: true
        )

        conversations[index].messages = mergedMessages
        conversations[index].lastMessagePreviewText = mergedMessages.last?.text ?? conversations[index].lastMessagePreviewText
        conversations[index].updatedAt = mergedMessages.last?.createdAt ?? conversations[index].updatedAt
        conversations[index].hasMoreHistory = hasOlderHistory(in: serverMessages)
        refreshLoadedMessageCursors(
            for: trimmedConversationID,
            messages: mergedMessages
        )
        statusMessage = nil
        sortConversations()
    }

    public func prepareOutgoingText(
        _ text: String,
        conversationID: String,
        senderUserID: UUID
    ) -> IMOutgoingMessageRequest? {
        prepareOutgoingText(
            text,
            conversationID: conversationID,
            senderUserID: senderUserID,
            deliveryState: .sending,
            shouldRegisterPendingRequest: true
        )
    }

    @discardableResult
    public func queueOutgoingText(
        _ text: String,
        conversationID: String,
        senderUserID: UUID,
        message: String = "等待 IM 长连接恢复后发送。"
    ) -> Bool {
        prepareOutgoingText(
            text,
            conversationID: conversationID,
            senderUserID: senderUserID,
            deliveryState: .queued(message: message),
            shouldRegisterPendingRequest: false
        ) != nil
    }

    public func prepareOutgoingReply(
        reference: IMReplyReference,
        text: String,
        conversationID: String,
        senderUserID: UUID
    ) -> IMOutgoingMessageRequest? {
        prepareOutgoingMessage(
            .reply(
                reference: reference,
                text: text.trimmingCharacters(in: .whitespacesAndNewlines)
            ),
            conversationID: conversationID,
            senderUserID: senderUserID,
            deliveryState: .sending,
            shouldRegisterPendingRequest: true
        )
    }

    @discardableResult
    public func queueOutgoingReply(
        reference: IMReplyReference,
        text: String,
        conversationID: String,
        senderUserID: UUID,
        message: String = "等待 IM 长连接恢复后发送。"
    ) -> Bool {
        prepareOutgoingMessage(
            .reply(
                reference: reference,
                text: text.trimmingCharacters(in: .whitespacesAndNewlines)
            ),
            conversationID: conversationID,
            senderUserID: senderUserID,
            deliveryState: .queued(message: message),
            shouldRegisterPendingRequest: false
        ) != nil
    }

    public func stageOutgoingMediaUpload(
        asset: IMMediaAsset,
        conversationID: String,
        senderUserID: UUID,
        sourceFileURL: URL
    ) -> IMOutgoingMediaPlaceholder? {
        let content = mediaContent(for: asset)
        guard content.isUserComposable else {
            statusMessage = "当前消息类型不支持发送。"
            return nil
        }

        return appendOutgoingMessage(
            content,
            conversationID: conversationID,
            senderUserID: senderUserID,
            deliveryState: .preparing(message: "正在准备上传附件。"),
            shouldRegisterPendingRequest: false,
            localTransferState: IMMessageLocalTransferState(sourceFilePath: sourceFileURL.path)
        ).placeholder
    }

    public func markOutgoingPreparing(localMessageID: String, message: String, uploadID: String? = nil) {
        mutateMessage(id: localMessageID) { item in
            item.deliveryState = .preparing(message: message)
            if let uploadID, let transferState = item.localTransferState {
                item.localTransferState = transferState.withUploadID(uploadID)
            }
        }
    }

    public func markOutgoingUploading(localMessageID: String, message: String, uploadID: String? = nil) {
        mutateMessage(id: localMessageID) { item in
            item.deliveryState = .uploading(message: message)
            if let uploadID, let transferState = item.localTransferState {
                item.localTransferState = transferState.withUploadID(uploadID)
            }
        }
    }

    public func markOutgoingUploadFailed(localMessageID: String, message: String) {
        mutateMessage(id: localMessageID) { item in
            item.deliveryState = .failed(message: message)
        }
        statusMessage = message
    }

    public func abandonRecoverableOutgoingMediaUpload(localMessageID: String, message: String) {
        mutateMessage(id: localMessageID) { item in
            item.deliveryState = .failed(message: message)
            item.localTransferState = nil
        }
        statusMessage = message
    }

    public func updateLocalDownloadState(
        messageID: String,
        state: IMMessageLocalDownloadState?
    ) {
        mutateMessage(id: messageID) { item in
            item.localDownloadState = state
        }
    }

    public func prepareUploadedOutgoingMedia(
        asset: IMMediaAsset,
        localMessageID: String,
        conversationID: String
    ) -> IMOutgoingMessageRequest? {
        updateUploadedOutgoingMedia(
            asset: asset,
            localMessageID: localMessageID,
            conversationID: conversationID,
            deliveryState: .sending,
            shouldRegisterPendingRequest: true
        )
    }

    @discardableResult
    public func queueUploadedOutgoingMedia(
        asset: IMMediaAsset,
        localMessageID: String,
        conversationID: String,
        message: String = "等待 IM 长连接恢复后发送。"
    ) -> Bool {
        updateUploadedOutgoingMedia(
            asset: asset,
            localMessageID: localMessageID,
            conversationID: conversationID,
            deliveryState: .queued(message: message),
            shouldRegisterPendingRequest: false
        ) != nil
    }

    public func recoverableOutgoingMediaUploads() -> [IMRecoverableOutgoingMediaUpload] {
        conversations.flatMap { conversation in
            conversation.messages.compactMap { message in
                guard let transferState = message.localTransferState,
                      let asset = message.mediaAsset,
                      message.isRecoverableOutgoingMediaUpload,
                      message.serverMessageID == nil,
                      message.serverSequence == nil
                else {
                    return nil
                }

                return IMRecoverableOutgoingMediaUpload(
                    localMessageID: message.id,
                    conversationID: conversation.id,
                    asset: asset,
                    transferState: transferState,
                    deliveryState: message.deliveryState
                )
            }
        }
    }

    private func prepareOutgoingMessage(
        _ content: IMMessageContent,
        conversationID: String,
        senderUserID: UUID,
        deliveryState: IMMessageDeliveryState,
        shouldRegisterPendingRequest: Bool,
        localTransferState: IMMessageLocalTransferState? = nil
    ) -> IMOutgoingMessageRequest? {
        appendOutgoingMessage(
            content,
            conversationID: conversationID,
            senderUserID: senderUserID,
            deliveryState: deliveryState,
            shouldRegisterPendingRequest: shouldRegisterPendingRequest,
            localTransferState: localTransferState
        ).request
    }

    private func prepareOutgoingText(
        _ text: String,
        conversationID: String,
        senderUserID: UUID,
        deliveryState: IMMessageDeliveryState,
        shouldRegisterPendingRequest: Bool
    ) -> IMOutgoingMessageRequest? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            statusMessage = "消息内容不能为空。"
            return nil
        }

        return prepareOutgoingMessage(
            .text(trimmedText),
            conversationID: conversationID,
            senderUserID: senderUserID,
            deliveryState: deliveryState,
            shouldRegisterPendingRequest: shouldRegisterPendingRequest
        )
    }

    public func retryOutgoingMessage(
        localMessageID: String,
        conversationID: String
    ) -> IMOutgoingMessageRequest? {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessageID = localMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty, !trimmedMessageID.isEmpty else {
            statusMessage = "消息重试失败：会话或消息无效。"
            return nil
        }

        guard let conversationIndex = conversations.firstIndex(where: { $0.id == trimmedConversationID }),
              let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == trimmedMessageID })
        else {
            statusMessage = "消息重试失败：本地消息不存在。"
            return nil
        }

        var message = conversations[conversationIndex].messages[messageIndex]
        guard message.direction == .outgoing, message.content.isUserComposable else {
            statusMessage = "只能重试自己发送的消息。"
            return nil
        }

        guard isRetryableFailure(message) else {
            statusMessage = "该消息失败原因不可重试。"
            return nil
        }

        let clientMessageID = message.clientMessageID ?? message.id
        let requestID = UUID()
        message.deliveryState = .sending
        message.serverMessageID = nil
        message.serverSequence = nil
        conversations[conversationIndex].messages[messageIndex] = message
        outgoingQueueState.registerPendingRequest(requestID, localMessageID: message.id)
        selectedConversationID = trimmedConversationID
        statusMessage = nil
        sortConversations()

        return IMOutgoingMessageRequest(
            requestID: requestID,
            localMessageID: message.id,
            payload: IMTCPMessagePayload(
                clientMessageID: clientMessageID,
                messageID: nil,
                conversationID: trimmedConversationID,
                senderUserID: nil,
                serverSequence: nil,
                serverTimestamp: nil,
                content: message.content
            )
        )
    }

    @discardableResult
    public func queueRetryableOutgoingMessage(
        localMessageID: String,
        conversationID: String,
        message queueMessage: String = "等待 IM 长连接恢复后发送。"
    ) -> Bool {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessageID = localMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty, !trimmedMessageID.isEmpty else {
            statusMessage = "消息排队失败：会话或消息无效。"
            return false
        }

        guard let conversationIndex = conversations.firstIndex(where: { $0.id == trimmedConversationID }),
              let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == trimmedMessageID })
        else {
            statusMessage = "消息排队失败：本地消息不存在。"
            return false
        }

        var message = conversations[conversationIndex].messages[messageIndex]
        guard isRetryableFailure(message) else {
            statusMessage = "该消息失败原因不可排队重试。"
            return false
        }

        outgoingQueueState.removePendingRequests(for: message.id)
        message.deliveryState = .queued(message: queueMessage)
        message.serverMessageID = nil
        message.serverSequence = nil
        conversations[conversationIndex].messages[messageIndex] = message
        selectedConversationID = trimmedConversationID
        statusMessage = nil
        sortConversations()
        return true
    }

    @discardableResult
    public func cancelQueuedOutgoingMessage(
        localMessageID: String,
        conversationID: String
    ) -> Bool {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessageID = localMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty, !trimmedMessageID.isEmpty else {
            statusMessage = "取消发送失败：会话或消息无效。"
            return false
        }

        guard let conversationIndex = conversations.firstIndex(where: { $0.id == trimmedConversationID }),
              let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == trimmedMessageID })
        else {
            statusMessage = "取消发送失败：本地消息不存在。"
            return false
        }

        let message = conversations[conversationIndex].messages[messageIndex]
        guard message.direction == .outgoing, message.content.isUserComposable, message.isQueued else {
            statusMessage = "只能取消尚未发送的消息。"
            return false
        }

        outgoingQueueState.removePendingRequests(for: message.id)
        conversations[conversationIndex].messages.remove(at: messageIndex)
        refreshConversationPresentationAfterLocalMessageRemoval(at: conversationIndex)
        selectedConversationID = trimmedConversationID
        statusMessage = nil
        sortConversations()
        return true
    }

    public func queuedOutgoingMessageRequests(limit: Int) -> [IMOutgoingMessageRequest] {
        let limitedCount = max(0, limit)
        guard limitedCount > 0 else {
            return []
        }

        var queuedMessages: [(conversationID: String, message: IMConversationMessage)] = []
        for conversation in conversations {
            for message in conversation.messages
                where message.direction == .outgoing && message.content.isUserComposable && message.isQueued {
                queuedMessages.append((conversation.id, message))
            }
        }

        queuedMessages.sort { left, right in
            if left.message.createdAt == right.message.createdAt {
                return left.message.id < right.message.id
            }
            return left.message.createdAt < right.message.createdAt
        }

        var requests: [IMOutgoingMessageRequest] = []
        for (conversationID, queuedMessage) in queuedMessages.prefix(limitedCount) {
            guard let request = startQueuedOutgoingMessage(
                localMessageID: queuedMessage.id,
                conversationID: conversationID
            ) else {
                continue
            }
            requests.append(request)
        }

        return requests
    }

    public func markOutgoingQueued(requestID: UUID, message: String) {
        guard let localMessageID = outgoingQueueState.removePendingRequest(requestID) else {
            return
        }

        mutateMessage(id: localMessageID) { item in
            item.deliveryState = .queued(message: message)
            item.serverMessageID = nil
            item.serverSequence = nil
        }
    }

    public func isRetryableFailure(_ message: IMConversationMessage) -> Bool {
        guard message.direction == .outgoing else {
            return false
        }

        switch message.deliveryState {
        case .preparing, .uploading, .uploaded:
            return false
        case .queued, .unknown:
            return true
        case .failed(let failureMessage):
            return !Self.nonRetryableOutgoingFailureMessages.contains(failureMessage)
        case .sending, .sent, .received:
            return false
        }
    }

    private func queueSummary(for messages: [IMConversationMessage]) -> IMConversationQueueSummary {
        var queuedCount = 0
        var sendingCount = 0
        var retryableIssueCount = 0

        for message in messages where message.direction == .outgoing {
            switch message.deliveryState {
            case .preparing, .uploading, .uploaded:
                sendingCount += 1
            case .queued:
                queuedCount += 1
            case .sending:
                sendingCount += 1
            case .unknown:
                retryableIssueCount += 1
            case .failed:
                if isRetryableFailure(message) {
                    retryableIssueCount += 1
                }
            case .sent, .received:
                break
            }
        }

        return IMConversationQueueSummary(
            queuedCount: queuedCount,
            sendingCount: sendingCount,
            retryableIssueCount: retryableIssueCount
        )
    }

    public func applyOutgoingAcknowledgement(requestID: UUID?, payload: IMTCPAckPayload) {
        guard let requestID, let localMessageID = outgoingQueueState.removePendingRequest(requestID) else {
            return
        }

        mutateMessage(id: localMessageID) { message in
            message.serverMessageID = payload.messageID
            if payload.status == "accepted" {
                message.deliveryState = .sent
            } else {
                let failureMessage = outgoingAcknowledgementFailureMessage(for: payload.status)
                message.deliveryState = .failed(message: failureMessage)
                statusMessage = failureMessage
            }
        }
    }

    public func markOutgoingFailure(requestID: UUID, message: String) {
        guard let localMessageID = outgoingQueueState.removePendingRequest(requestID) else {
            statusMessage = message
            return
        }

        mutateMessage(id: localMessageID) { item in
            item.deliveryState = .failed(message: message)
        }
        statusMessage = message
    }

    public func markAllPendingMessagesFailed(message: String) {
        let pendingMessageIDs = outgoingQueueState.drainPendingMessageIDs()

        for localMessageID in pendingMessageIDs {
            mutateMessage(id: localMessageID) { item in
                item.deliveryState = .failed(message: message)
            }
        }

        if !pendingMessageIDs.isEmpty {
            statusMessage = message
        }
    }

    public func markAllPendingMessagesUnknown(message: String) {
        let pendingMessageIDs = outgoingQueueState.drainPendingMessageIDs()

        for localMessageID in pendingMessageIDs {
            mutateMessage(id: localMessageID) { item in
                item.deliveryState = .unknown(message: message)
            }
        }

        if !pendingMessageIDs.isEmpty {
            statusMessage = message
        }
    }

    public func receiveIncomingMessage(_ payload: IMTCPMessagePayload, currentUserID: UUID) {
        let index = ensureConversationIndex(for: payload.conversationID)
        let stableMessageID = payload.messageID ?? payload.clientMessageID ?? UUID().uuidString
        let effectiveTimestamp = payload.serverTimestamp ?? Date()

        if payload.senderUserID == currentUserID,
           let clientMessageID = payload.clientMessageID,
           let existingIndex = conversations[index].messages.firstIndex(where: { $0.clientMessageID == clientMessageID }) {
            conversations[index].messages[existingIndex].serverMessageID = payload.messageID
            conversations[index].messages[existingIndex].serverSequence = payload.serverSequence
            conversations[index].messages[existingIndex].createdAt = effectiveTimestamp
            conversations[index].messages[existingIndex].deliveryState = .sent
            conversations[index].updatedAt = effectiveTimestamp
            conversations[index].lastMessagePreviewText = conversations[index].messages[existingIndex].text
            refreshLatestSyncedCursor(
                for: payload.conversationID,
                messages: conversations[index].messages
            )
            sortConversations()
            return
        }

        let alreadyExists = conversations[index].messages.contains {
            $0.id == stableMessageID
                || ($0.serverMessageID != nil && $0.serverMessageID == payload.messageID)
                || ($0.clientMessageID != nil && $0.clientMessageID == payload.clientMessageID)
        }
        guard !alreadyExists else {
            return
        }

        let message = IMConversationMessage(
            id: stableMessageID,
            conversationID: payload.conversationID,
            clientMessageID: payload.clientMessageID,
            serverMessageID: payload.messageID,
            senderUserID: payload.senderUserID,
            serverSequence: payload.serverSequence,
            content: payload.content,
            direction: payload.senderUserID == currentUserID ? .outgoing : .incoming,
            createdAt: effectiveTimestamp,
            deliveryState: payload.senderUserID == currentUserID ? .sent : .received
        )

        conversations[index].messages.append(message)
        conversations[index].lastMessagePreviewText = message.text
        conversations[index].updatedAt = message.createdAt
        refreshLatestSyncedCursor(
            for: payload.conversationID,
            messages: conversations[index].messages
        )

        applyIncomingMessageUnreadState(for: payload.conversationID)

        statusMessage = nil
        sortConversations()
    }

    public func applyRecalledMessage(
        _ response: IMConversationMessageResponseBody,
        currentUserID: UUID
    ) {
        let conversationID = response.conversationID.uuidString
        let stableMessageID = response.id.uuidString
        let effectiveTimestamp = response.createdAt ?? Date()
        let index = ensureConversationIndex(for: conversationID)

        if let messageIndex = conversations[index].messages.firstIndex(where: {
            $0.id == stableMessageID || $0.serverMessageID == stableMessageID
        }) {
            conversations[index].messages[messageIndex].serverMessageID = stableMessageID
            conversations[index].messages[messageIndex].serverSequence = UInt64(response.serverSequence)
            conversations[index].messages[messageIndex].senderUserID = response.senderUserID
            conversations[index].messages[messageIndex].content = response.content
            conversations[index].messages[messageIndex].createdAt = effectiveTimestamp
            conversations[index].messages[messageIndex].deliveryState =
                conversations[index].messages[messageIndex].direction == .outgoing ? .sent : .received
        } else {
            conversations[index].messages.append(
                IMConversationMessage(
                    id: stableMessageID,
                    conversationID: conversationID,
                    clientMessageID: response.clientMessageID,
                    serverMessageID: stableMessageID,
                    senderUserID: response.senderUserID,
                    serverSequence: UInt64(response.serverSequence),
                    content: response.content,
                    direction: response.senderUserID == currentUserID ? .outgoing : .incoming,
                    createdAt: effectiveTimestamp,
                    deliveryState: response.senderUserID == currentUserID ? .sent : .received
                )
            )
        }

        conversations[index].lastMessagePreviewText = conversations[index].messages.last?.text
            ?? conversations[index].lastMessagePreviewText
        conversations[index].updatedAt = max(conversations[index].updatedAt, effectiveTimestamp)
        sortConversations()
    }

    public func hasLoadedMessages(for conversationID: String) -> Bool {
        detailState.hasLoadedMessages(for: conversationID)
    }

    public func canLoadOlderMessages(for conversationID: String) -> Bool {
        conversations.first(where: { $0.id == conversationID })?.hasMoreHistory ?? false
    }

    public func oldestLoadedServerSequence(for conversationID: String) -> UInt64? {
        detailState.oldestLoadedServerSequence(
            for: conversationID,
            conversations: conversations
        )
    }

    public func syncCursor(for conversationID: String) -> IMSyncCursorState? {
        detailState.syncCursor(
            for: conversationID,
            conversations: conversations
        )
    }

    public func setLatestSyncedServerSequence(_ sequence: UInt64?, for conversationID: String) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        detailState.setLatestSyncedServerSequence(sequence, for: trimmedConversationID)
    }

    public func setOldestLoadedServerSequence(_ sequence: UInt64?, for conversationID: String) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        detailState.setOldestLoadedServerSequence(sequence, for: trimmedConversationID)
    }

    public func trimCachedMessageWindow(limit: Int = IMConversationCacheSnapshot.cachedMessageLimit) {
        let effectiveLimit = max(0, limit)
        for index in conversations.indices {
            conversations[index].messages = trimmedCachedMessages(
                conversations[index].messages,
                limit: effectiveLimit
            )
            refreshLoadedMessageCursors(
                for: conversations[index].id,
                messages: conversations[index].messages
            )
        }
    }

    public func latestLoadedServerSequence(for conversationID: String) -> UInt64? {
        detailState.latestLoadedServerSequence(
            for: conversationID,
            conversations: conversations
        )
    }

    public func gapSyncTargets(from summaries: [IMConversationSummaryResponseBody]) -> [String] {
        summaries.compactMap { summary in
            let conversationID = summary.id.uuidString
            let serverLatestSequence = UInt64(max(0, summary.lastMessage?.serverSequence ?? 0))
            guard
                let localLatestSequence = latestLoadedServerSequence(for: conversationID),
                serverLatestSequence > localLatestSequence
            else {
                return nil
            }

            return conversationID
        }
    }

    public func serverLastReadSequence(for conversationID: String) -> UInt64? {
        conversations.first(where: { $0.id == conversationID })?.serverLastReadSequence
    }

    public func setLoadingConversations(_ isLoading: Bool) {
        isLoadingConversations = isLoading
    }

    public func setLoadingMoreConversationSummaries(_ isLoading: Bool) {
        isLoadingMoreConversationSummaries = isLoading
    }

    public func setLoadingMembers(_ isLoading: Bool) {
        detailState.isLoadingMembers = isLoading
        isLoadingMembers = isLoading
    }

    public func setLoadingMessages(_ isLoading: Bool) {
        detailState.isLoadingMessages = isLoading
        isLoadingMessages = isLoading
    }

    public func setStatusMessage(_ message: String?) {
        statusMessage = message
    }

    public func containsConversation(id conversationID: String) -> Bool {
        conversations.contains { $0.id == conversationID }
    }

    public func localMessageID(
        matchingReferencedMessageID targetMessageID: String,
        in conversationID: String
    ) -> String? {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTargetMessageID = targetMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty, !trimmedTargetMessageID.isEmpty,
              let conversation = conversations.first(where: { $0.id == trimmedConversationID })
        else {
            return nil
        }

        return messageTimelineState.localMessageID(
            matchingReferencedMessageID: trimmedTargetMessageID,
            in: conversation.messages
        )
    }

    public func beginReplyJump(
        to targetMessageID: String,
        in conversationID: String
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTargetMessageID = targetMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty, !trimmedTargetMessageID.isEmpty else {
            return
        }

        detailState.startReplyJump(in: trimmedConversationID, targetMessageID: trimmedTargetMessageID)
        syncReplyJumpState()
    }

    public func resolveReplyJump(
        matchedMessageID: String,
        in conversationID: String
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMatchedMessageID = matchedMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty, !trimmedMatchedMessageID.isEmpty else {
            return
        }

        detailState.resolveReplyJump(matchedMessageID: trimmedMatchedMessageID, in: trimmedConversationID)
        syncReplyJumpState()
    }

    public func exhaustReplyJump(
        to targetMessageID: String,
        in conversationID: String
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTargetMessageID = targetMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty, !trimmedTargetMessageID.isEmpty else {
            return
        }

        detailState.exhaustReplyJump(in: trimmedConversationID, targetMessageID: trimmedTargetMessageID)
        syncReplyJumpState()
    }

    public func clearReplyJump() {
        detailState.clearReplyJump()
        syncReplyJumpState()
    }

    public func makeCacheSnapshot(
        lastSummaryRefreshAt: Date?,
        summarySyncToken: String? = nil
    ) -> IMConversationCacheSnapshot {
        ConversationCacheSnapshotMapper.makeSnapshot(
            conversations: conversations,
            selectedConversationID: selectedConversationID,
            detailState: detailState,
            lastSummaryRefreshAt: lastSummaryRefreshAt,
            summarySyncToken: summarySyncToken,
            summaryNextCursor: conversationSummaryNextCursor,
            hasMoreConversationSummaries: hasMoreConversationSummaries,
            trimMessages: { messages, limit in
                trimmedCachedMessages(messages, limit: limit)
            }
        )
    }

    public func restoreCacheSnapshot(_ snapshot: IMConversationCacheSnapshot) {
        let restoredState = ConversationCacheSnapshotMapper.restore(
            from: snapshot,
            restoreDeliveryState: Self.restoredDeliveryState(_:)
        )
        conversations = restoredState.conversations
        selectedConversationID = restoredState.selectedConversationID
        detailState = restoredState.detailState
        conversationSummaryNextCursor = snapshot.metadata.summaryNextCursor
        hasMoreConversationSummaries = snapshot.metadata.hasMoreConversationSummaries
        isLoadingMoreConversationSummaries = false
        isLoadingMembers = detailState.isLoadingMembers
        isLoadingMessages = detailState.isLoadingMessages

        statusMessage = nil
        syncReplyJumpState()
        sortConversations()
    }

    private func ensureConversationIndex(for conversationID: String) -> Int {
        if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
            return index
        }

        let conversation = IMConversation(
            id: conversationID,
            title: fallbackTitle(for: conversationID),
            kind: .group,
            directMessagingState: nil,
            directPeer: nil,
            notice: nil,
            avatarPreset: nil,
            memberCount: 0,
            memberUserIDs: [],
            members: [],
            messages: [],
            lastMessagePreviewText: "暂无消息",
            hasMoreHistory: false,
            serverLastReadSequence: 0,
            serverUnreadCount: 0,
            localUnreadDelta: 0,
            isPinned: false,
            pinnedAt: nil,
            isMuted: false,
            draftText: "",
            draftUpdatedAt: nil,
            updatedAt: .distantPast
        )
        conversations.append(conversation)
        return conversations.count - 1
    }

    private func upsertConversationSummaryContent(_ response: IMConversationSummaryResponseBody) {
        let conversationID = response.id.uuidString
        let index = ensureConversationIndex(for: conversationID)
        conversations[index] = conversationSummary(
            from: response,
            existing: conversations[index]
        )

        statusMessage = nil
        sortConversations()
    }

    private func conversationSummary(
        from response: IMConversationSummaryResponseBody,
        existing: IMConversation?
    ) -> IMConversation {
        let conversationID = response.id.uuidString
        let conversationKind = IMConversationKind(rawValue: response.kind) ?? .group
        let directPeer = directPeer(from: response, conversationKind: conversationKind)
        let previewText = messageDerivedStateReducer.mergedSummaryPreviewText(
            existing: existing,
            responseLastMessage: response.lastMessage
        )

        return IMConversation(
            id: conversationID,
            title: normalizedTitle(
                response.title,
                conversationID: conversationID,
                conversationKind: conversationKind,
                directPeer: directPeer
            ),
            kind: conversationKind,
            directMessagingState: directMessagingState(
                from: response.directMessagingState,
                conversationKind: conversationKind
            ),
            directPeer: directPeer,
            notice: response.notice,
            avatarPreset: response.avatarPreset,
            memberCount: response.memberCount,
            memberUserIDs: response.memberUserIDs.sorted { $0.uuidString < $1.uuidString },
            members: (existing?.members ?? []).filter { response.memberUserIDs.contains($0.id) },
            messages: existing?.messages ?? [],
            lastMessagePreviewText: previewText,
            hasMoreHistory: existing?.hasMoreHistory ?? false,
            serverLastReadSequence: UInt64(response.lastReadSequence),
            serverUnreadCount: response.unreadCount,
            localUnreadDelta: existing?.localUnreadDelta ?? 0,
            isPinned: response.isPinned,
            pinnedAt: response.pinnedAt,
            isMuted: response.isMuted,
            draftText: existing?.draftText ?? "",
            draftUpdatedAt: existing?.draftUpdatedAt,
            updatedAt: response.updatedAt
        )
    }

    private func applyIncomingMessageUnreadState(for conversationID: String) {
        if selectedConversationID == nil {
            selectedConversationID = conversationID
        }

        applyRealtimeUnreadIncrement(for: conversationID)
    }

    private func refreshLoadedMessageCursors(
        for conversationID: String,
        messages: [IMConversationMessage]
    ) {
        detailState.refreshLoadedMessageCursors(for: conversationID, messages: messages)
    }

    private func refreshLatestSyncedCursor(
        for conversationID: String,
        messages: [IMConversationMessage]
    ) {
        detailState.refreshLatestSyncedCursor(for: conversationID, messages: messages)
    }

    private func trimmedCachedMessages(
        _ messages: [IMConversationMessage],
        limit: Int
    ) -> [IMConversationMessage] {
        guard limit > 0, messages.count > limit else {
            return limit == 0 ? [] : messages
        }

        return Array(messages.suffix(limit))
    }

    private func resetUnreadState(for conversationIndex: Int) {
        conversations[conversationIndex].serverUnreadCount = 0
        conversations[conversationIndex].localUnreadDelta = 0
    }

    private func syncReplyJumpState() {
        replyJumpConversationID = detailState.replyJumpConversationID
        replyJumpTargetMessageID = detailState.replyJumpTargetMessageID
        replyJumpMatchedMessageID = detailState.replyJumpMatchedMessageID
        replyJumpState = detailState.replyJumpState
    }

    private func reconciledLocalUnreadDelta(
        for conversationID: String,
        previousServerLastReadSequence: UInt64,
        previousServerUnreadCount: Int,
        previousLocalUnreadDelta: Int,
        updatedServerLastReadSequence: UInt64,
        updatedServerUnreadCount: Int
    ) -> Int {
        guard previousLocalUnreadDelta > 0 else {
            return 0
        }

        guard updatedServerUnreadCount > 0 else {
            return 0
        }

        guard latestLoadedServerSequence(for: conversationID) != nil else {
            return previousLocalUnreadDelta
        }

        let previousTotalUnreadCount = previousServerUnreadCount + previousLocalUnreadDelta
        if updatedServerLastReadSequence > previousServerLastReadSequence
            || updatedServerUnreadCount >= previousTotalUnreadCount {
            return 0
        }

        return previousLocalUnreadDelta
    }

    private func mutateMessage(id: String, update: (inout IMConversationMessage) -> Void) {
        for conversationIndex in conversations.indices {
            guard let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == id }) else {
                continue
            }

            update(&conversations[conversationIndex].messages[messageIndex])
            conversations[conversationIndex].updatedAt = messageTimelineState.latestUpdatedAt(
                in: conversations[conversationIndex].messages,
                fallback: conversations[conversationIndex].messages[messageIndex].createdAt
            )
            conversations[conversationIndex].lastMessagePreviewText = messageTimelineState.latestPreviewText(
                in: conversations[conversationIndex].messages,
                fallback: conversations[conversationIndex].lastMessagePreviewText
            )
            sortConversations()
            return
        }
    }

    private func refreshConversationPresentationAfterLocalMessageRemoval(at conversationIndex: Int) {
        guard conversations.indices.contains(conversationIndex) else {
            return
        }

        if let latestMessage = conversations[conversationIndex].messages.last {
            conversations[conversationIndex].lastMessagePreviewText = messageTimelineState.latestPreviewText(
                in: conversations[conversationIndex].messages,
                fallback: latestMessage.text
            )
            conversations[conversationIndex].updatedAt = messageTimelineState.latestUpdatedAt(
                in: conversations[conversationIndex].messages,
                fallback: latestMessage.createdAt
            )
        } else {
            conversations[conversationIndex].lastMessagePreviewText = ""
        }
    }

    private func sortConversations() {
        conversations.sort { left, right in
            if left.isPinned != right.isPinned {
                return left.isPinned && !right.isPinned
            }

            if left.isPinned && right.isPinned {
                switch (left.pinnedAt, right.pinnedAt) {
                case let (lhs?, rhs?) where lhs != rhs:
                    return lhs > rhs
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    break
                }
            }

            if left.updatedAt == right.updatedAt {
                return left.id < right.id
            }
            return left.updatedAt > right.updatedAt
        }
    }

    private func normalizedTitle(
        _ title: String?,
        conversationID: String,
        conversationKind: IMConversationKind,
        directPeer: IMDirectPeer?
    ) -> String {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }
        if conversationKind == .direct,
           let directPeer,
           !directPeer.email.isEmpty {
            return directPeer.email
        }
        return fallbackTitle(for: conversationID)
    }

    private func makeMessages(
        from responses: [IMConversationMessageResponseBody],
        currentUserID: UUID
    ) -> [IMConversationMessage] {
        responses.map { response in
            IMConversationMessage(
                id: response.id.uuidString,
                conversationID: response.conversationID.uuidString,
                clientMessageID: response.clientMessageID,
                serverMessageID: response.id.uuidString,
                senderUserID: response.senderUserID,
                serverSequence: UInt64(response.serverSequence),
                content: response.content,
                direction: response.senderUserID == currentUserID ? .outgoing : .incoming,
                createdAt: response.createdAt ?? .distantPast,
                deliveryState: response.senderUserID == currentUserID ? .sent : .received
            )
        }
    }

    private func mergeMessages(
        existing: [IMConversationMessage],
        serverMessages: [IMConversationMessage],
        preserveExistingServerMessages: Bool
    ) -> [IMConversationMessage] {
        var merged = preserveExistingServerMessages
            ? existing
            : existing.filter { message in
                message.serverMessageID == nil && message.serverSequence == nil
            }

        for serverMessage in serverMessages {
            if let existingIndex = merged.firstIndex(where: { Self.matches($0, serverMessage) }) {
                merged[existingIndex] = serverMessage
            } else {
                merged.append(serverMessage)
            }
        }

        return merged.sorted(by: Self.messageComparator)
    }

    private func hasOlderHistory(in serverMessages: [IMConversationMessage]) -> Bool {
        guard let oldestSequence = serverMessages.compactMap(\.serverSequence).min() else {
            return false
        }

        return oldestSequence > 1
    }

    private func sortMembers(lhs: IMConversationMember, rhs: IMConversationMember) -> Bool {
        let lhsPriority = memberRolePriority(lhs.role)
        let rhsPriority = memberRolePriority(rhs.role)
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }

        return lhs.email < rhs.email
    }

    private func memberRolePriority(_ role: IMConversationMemberRole) -> Int {
        switch role {
        case .owner:
            return 0
        case .admin:
            return 1
        case .member:
            return 2
        }
    }

    private func fallbackTitle(for conversationID: String) -> String {
        "会话 \(conversationID.prefix(8).lowercased())"
    }

    private func directMessagingState(
        from rawValue: String?,
        conversationKind: IMConversationKind
    ) -> IMDirectMessagingState? {
        guard conversationKind == .direct else {
            return nil
        }

        guard let rawValue,
              let state = IMDirectMessagingState(rawValue: rawValue)
        else {
            return .active
        }

        return state
    }

    private func directPeer(
        from response: IMConversationSummaryResponseBody,
        conversationKind: IMConversationKind
    ) -> IMDirectPeer? {
        guard conversationKind == .direct,
              let directPeer = response.directPeer
        else {
            return nil
        }

        return IMDirectPeer(
            id: directPeer.id,
            email: directPeer.email,
            displayName: directPeer.displayName,
            avatarPreset: directPeer.avatarPreset
        )
    }

    private func outgoingAcknowledgementFailureMessage(for status: String) -> String {
        switch status {
        case "direct_conversation_frozen":
            return "你们已不是好友，当前会话不能继续发送消息。"
        case "stranger_direct_message_limit_reached":
            return "你们还不是好友，对方回复前只能发送一条消息。"
        case "invalid_conversation_id":
            return "会话 ID 无效。"
        case "conversation_unavailable":
            return "会话不存在或你已不在该会话中。"
        case "unsupported_message_content":
            return "当前消息类型不支持发送。"
        case "empty_text_body":
            return "消息内容不能为空。"
        case "internal_error":
            return "消息发送失败，请稍后重试。"
        default:
            return "消息发送失败：\(status)"
        }
    }

    private static func restoredDeliveryState(_ state: IMMessageDeliveryState) -> IMMessageDeliveryState {
        switch state {
        case .sending:
            return .unknown(message: "发送状态未确认，请重试。")
        case .preparing, .uploading, .uploaded:
            return state
        case .queued, .sent, .received, .unknown, .failed:
            return state
        }
    }

    private func startQueuedOutgoingMessage(
        localMessageID: String,
        conversationID: String
    ) -> IMOutgoingMessageRequest? {
        guard let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == localMessageID })
        else {
            return nil
        }

        var message = conversations[conversationIndex].messages[messageIndex]
        guard message.direction == .outgoing, message.isQueued else {
            return nil
        }

        let clientMessageID = message.clientMessageID ?? message.id
        let requestID = UUID()
        message.deliveryState = .sending
        message.serverMessageID = nil
        message.serverSequence = nil
        conversations[conversationIndex].messages[messageIndex] = message
        outgoingQueueState.registerPendingRequest(requestID, localMessageID: message.id)
        sortConversations()

        return IMOutgoingMessageRequest(
            requestID: requestID,
            localMessageID: message.id,
            payload: IMTCPMessagePayload(
                clientMessageID: clientMessageID,
                messageID: nil,
                conversationID: conversationID,
                senderUserID: nil,
                serverSequence: nil,
                serverTimestamp: nil,
                content: message.content
            )
        )
    }

    private static let nonRetryableOutgoingFailureMessages: Set<String> = [
        "你们已不是好友，当前会话不能继续发送消息。",
        "你们还不是好友，对方回复前只能发送一条消息。",
        "会话 ID 无效。",
        "会话不存在或你已不在该会话中。",
        "当前消息类型不支持发送。",
        "消息内容不能为空。",
        "附件上传失败，请稍后重试。"
    ]

    private func appendOutgoingMessage(
        _ content: IMMessageContent,
        conversationID: String,
        senderUserID: UUID,
        deliveryState: IMMessageDeliveryState,
        shouldRegisterPendingRequest: Bool,
        localTransferState: IMMessageLocalTransferState? = nil
    ) -> (placeholder: IMOutgoingMediaPlaceholder?, request: IMOutgoingMessageRequest?) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            statusMessage = "当前没有可用会话。"
            return (nil, nil)
        }

        guard content.isUserComposable else {
            statusMessage = "当前消息类型不支持发送。"
            return (nil, nil)
        }

        guard !content.previewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "消息内容不能为空。"
            return (nil, nil)
        }

        let requestID = UUID()
        let clientMessageID = UUID().uuidString
        let localMessageID = clientMessageID
        let createdAt = Date()
        let index = ensureConversationIndex(for: trimmedConversationID)
        let message = IMConversationMessage(
            id: localMessageID,
            conversationID: trimmedConversationID,
            clientMessageID: clientMessageID,
            serverMessageID: nil,
            senderUserID: senderUserID,
            serverSequence: nil,
            content: content,
            direction: .outgoing,
            createdAt: createdAt,
            deliveryState: deliveryState,
            localTransferState: localTransferState
        )

        conversations[index].messages.append(message)
        conversations[index].lastMessagePreviewText = content.previewText
        conversations[index].updatedAt = createdAt
        conversations[index].draftText = ""
        conversations[index].draftUpdatedAt = nil
        resetUnreadState(for: index)
        selectedConversationID = trimmedConversationID
        if shouldRegisterPendingRequest {
            outgoingQueueState.registerPendingRequest(requestID, localMessageID: localMessageID)
        }
        statusMessage = nil
        sortConversations()

        let payload = IMTCPMessagePayload(
            clientMessageID: clientMessageID,
            messageID: nil,
            conversationID: trimmedConversationID,
            senderUserID: nil,
            serverSequence: nil,
            serverTimestamp: nil,
            content: content
        )
        let request = shouldRegisterPendingRequest
            ? IMOutgoingMessageRequest(
                requestID: requestID,
                localMessageID: localMessageID,
                payload: payload
            )
            : nil
        return (
            IMOutgoingMediaPlaceholder(localMessageID: localMessageID, clientMessageID: clientMessageID),
            request
        )
    }

    private func updateUploadedOutgoingMedia(
        asset: IMMediaAsset,
        localMessageID: String,
        conversationID: String,
        deliveryState: IMMessageDeliveryState,
        shouldRegisterPendingRequest: Bool
    ) -> IMOutgoingMessageRequest? {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLocalMessageID = localMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty, !trimmedLocalMessageID.isEmpty else {
            return nil
        }
        guard let conversationIndex = conversations.firstIndex(where: { $0.id == trimmedConversationID }),
              let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == trimmedLocalMessageID })
        else {
            statusMessage = "附件消息不存在。"
            return nil
        }

        let content = mediaContent(for: asset)
        guard content.isUserComposable else {
            statusMessage = "当前消息类型不支持发送。"
            return nil
        }

        let requestID = UUID()
        var message = conversations[conversationIndex].messages[messageIndex]
        message.content = content
        message.deliveryState = deliveryState
        message.serverMessageID = nil
        message.serverSequence = nil
        message.localTransferState = nil
        conversations[conversationIndex].messages[messageIndex] = message
        conversations[conversationIndex].lastMessagePreviewText = content.previewText
        conversations[conversationIndex].updatedAt = message.createdAt
        selectedConversationID = trimmedConversationID
        if shouldRegisterPendingRequest {
            outgoingQueueState.registerPendingRequest(requestID, localMessageID: message.id)
        }
        statusMessage = nil
        sortConversations()

        guard shouldRegisterPendingRequest else {
            return nil
        }

        return IMOutgoingMessageRequest(
            requestID: requestID,
            localMessageID: message.id,
            payload: IMTCPMessagePayload(
                clientMessageID: message.clientMessageID ?? message.id,
                messageID: nil,
                conversationID: trimmedConversationID,
                senderUserID: nil,
                serverSequence: nil,
                serverTimestamp: nil,
                content: content
            )
        )
    }

    private func mediaContent(for asset: IMMediaAsset) -> IMMessageContent {
        switch asset.kind {
        case .image:
            return .image(asset)
        case .audio:
            return .audio(asset)
        case .file:
            return .file(asset)
        }
    }

    private static func matches(_ left: IMConversationMessage, _ right: IMConversationMessage) -> Bool {
        if let leftServerMessageID = left.serverMessageID,
           let rightServerMessageID = right.serverMessageID,
           leftServerMessageID == rightServerMessageID {
            return true
        }

        if let leftClientMessageID = left.clientMessageID,
           let rightClientMessageID = right.clientMessageID,
           leftClientMessageID == rightClientMessageID {
            return true
        }

        if let leftServerSequence = left.serverSequence,
           let rightServerSequence = right.serverSequence,
           leftServerSequence == rightServerSequence,
           left.conversationID == right.conversationID {
            return true
        }

        return false
    }

    private static let messageComparator: (IMConversationMessage, IMConversationMessage) -> Bool = { left, right in
        switch (left.serverSequence, right.serverSequence) {
        case let (leftSequence?, rightSequence?):
            if leftSequence == rightSequence {
                if left.createdAt == right.createdAt {
                    return left.id < right.id
                }
                return left.createdAt < right.createdAt
            }
            return leftSequence < rightSequence
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            if left.createdAt == right.createdAt {
                return left.id < right.id
            }
            return left.createdAt < right.createdAt
        }
    }
}

private extension IMConversationMessage {
    var isQueued: Bool {
        if case .queued = deliveryState {
            return true
        }

        return false
    }
}
