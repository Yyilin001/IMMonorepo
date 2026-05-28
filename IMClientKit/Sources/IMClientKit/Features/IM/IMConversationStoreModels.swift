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

public enum IMConversationMessageValidationError: Error, Equatable, Sendable {
    case missingServerMessageID
    case invalidServerSequence(UInt64)
    case invalidTimelineSequence(UInt64)
}

public enum IMTimelineNoticeValidationError: Error, Equatable, Sendable {
    case missingID
    case missingConversationID
    case invalidTimelineSequence(UInt64)
    case missingNoticeKind
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
    public var serverMessageID: String
    public var senderUserID: UUID
    public var serverSequence: UInt64
    public var timelineSequence: UInt64
    public var content: IMMessageContent
    public var derivedState: MessageDerivedState
    public let direction: IMMessageDirection
    public var createdAt: Date
    public var deliveryState: IMMessageDeliveryState
    public var transferTaskID: TransferTaskID?
    public var localTransferState: IMMessageLocalTransferState?
    public var localDownloadState: IMMessageLocalDownloadState?

    public var text: String {
        MessagePresentation(aggregate: aggregate).previewText
    }

    public var aggregate: MessageAggregate {
        content.aggregate(derivedState: derivedState)
    }

    public var mediaAsset: IMMediaAsset? {
        MessagePresentation(aggregate: aggregate).mediaAsset
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
        serverMessageID: String,
        senderUserID: UUID,
        serverSequence: UInt64,
        timelineSequence: UInt64,
        content: IMMessageContent,
        derivedState: MessageDerivedState = MessageDerivedState(),
        direction: IMMessageDirection,
        createdAt: Date,
        deliveryState: IMMessageDeliveryState,
        transferTaskID: TransferTaskID? = nil,
        localTransferState: IMMessageLocalTransferState? = nil,
        localDownloadState: IMMessageLocalDownloadState? = nil
    ) throws {
        guard !serverMessageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IMConversationMessageValidationError.missingServerMessageID
        }
        guard serverSequence > 0 else {
            throw IMConversationMessageValidationError.invalidServerSequence(serverSequence)
        }
        guard timelineSequence > 0 else {
            throw IMConversationMessageValidationError.invalidTimelineSequence(timelineSequence)
        }
        self.id = id
        self.conversationID = conversationID
        self.clientMessageID = clientMessageID
        self.serverMessageID = serverMessageID
        self.senderUserID = senderUserID
        self.serverSequence = serverSequence
        self.timelineSequence = timelineSequence
        self.content = content
        self.derivedState = content.derivedState.isRecalled ? content.derivedState : derivedState
        self.direction = direction
        self.createdAt = createdAt
        self.deliveryState = deliveryState
        self.transferTaskID = transferTaskID
        self.localTransferState = localTransferState
        self.localDownloadState = localDownloadState
    }
}

public struct IMPendingConversationMessage: Identifiable, Equatable, Sendable {
    public let id: String
    public let localMessageID: String
    public let clientMessageID: String
    public let conversationID: String
    public let senderUserID: UUID
    public var content: IMMessageContent
    public var createdAt: Date
    public var deliveryState: IMMessageDeliveryState
    public var transferTaskID: TransferTaskID?
    public var localTransferState: IMMessageLocalTransferState?
    public var localDownloadState: IMMessageLocalDownloadState?

    public var direction: IMMessageDirection { .outgoing }

    public var text: String {
        MessagePresentation(aggregate: aggregate).previewText
    }

    public var aggregate: MessageAggregate {
        content.aggregate(derivedState: MessageDerivedState())
    }

    public var mediaAsset: IMMediaAsset? {
        MessagePresentation(aggregate: aggregate).mediaAsset
    }

    public var isRecoverableOutgoingMediaUpload: Bool {
        guard localTransferState != nil, mediaAsset != nil else {
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
        localMessageID: String,
        clientMessageID: String,
        conversationID: String,
        senderUserID: UUID,
        content: IMMessageContent,
        createdAt: Date,
        deliveryState: IMMessageDeliveryState,
        transferTaskID: TransferTaskID? = nil,
        localTransferState: IMMessageLocalTransferState? = nil,
        localDownloadState: IMMessageLocalDownloadState? = nil
    ) {
        self.id = localMessageID
        self.localMessageID = localMessageID
        self.clientMessageID = clientMessageID
        self.conversationID = conversationID
        self.senderUserID = senderUserID
        self.content = content
        self.createdAt = createdAt
        self.deliveryState = deliveryState
        self.transferTaskID = transferTaskID
        self.localTransferState = localTransferState
        self.localDownloadState = localDownloadState
    }
}

public struct IMTimelineNotice: Identifiable, Equatable, Sendable {
    public let id: String
    public let conversationID: String
    public let timelineSequence: UInt64
    public let eventType: String
    public let actorUserID: UUID?
    public let targetUserIDs: [UUID]
    public let noticeKind: String
    public let params: [String: String]
    public let fallbackText: String
    public let createdAt: Date

    public init(
        id: String,
        conversationID: String,
        timelineSequence: UInt64,
        eventType: String,
        actorUserID: UUID?,
        targetUserIDs: [UUID],
        noticeKind: String,
        params: [String: String] = [:],
        fallbackText: String,
        createdAt: Date
    ) throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IMTimelineNoticeValidationError.missingID
        }
        guard !conversationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IMTimelineNoticeValidationError.missingConversationID
        }
        guard timelineSequence > 0 else {
            throw IMTimelineNoticeValidationError.invalidTimelineSequence(timelineSequence)
        }
        guard !noticeKind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IMTimelineNoticeValidationError.missingNoticeKind
        }
        self.id = id
        self.conversationID = conversationID
        self.timelineSequence = timelineSequence
        self.eventType = eventType
        self.actorUserID = actorUserID
        self.targetUserIDs = targetUserIDs
        self.noticeKind = noticeKind
        self.params = params
        self.fallbackText = fallbackText
        self.createdAt = createdAt
    }
}

public enum IMConversationTimelineItem: Identifiable, Equatable, Sendable {
    case message(IMConversationMessage)
    case notice(IMTimelineNotice)
    case pendingMessage(IMPendingConversationMessage)

    public var id: String {
        switch self {
        case .message(let message):
            return "message:\(message.id)"
        case .notice(let notice):
            return "notice:\(notice.id)"
        case .pendingMessage(let message):
            return "pendingMessage:\(message.id)"
        }
    }

    public var timelineSequence: UInt64? {
        switch self {
        case .message(let message):
            return message.timelineSequence
        case .notice(let notice):
            return notice.timelineSequence
        case .pendingMessage:
            return nil
        }
    }

    public var pendingSortDate: Date? {
        switch self {
        case .pendingMessage(let message):
            return message.createdAt
        case .message, .notice:
            return nil
        }
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

    var resolvedTransferTaskID: TransferTaskID? {
        transferTaskID ?? localTransferState?.taskID ?? localDownloadState?.taskID
    }
}

public extension IMPendingConversationMessage {
    var resolvedTransferTaskID: TransferTaskID? {
        transferTaskID ?? localTransferState?.taskID ?? localDownloadState?.taskID
    }
}

public struct IMConversationMember: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let email: String
    public let displayName: String?
    public let avatarPreset: UserAvatarPreset?
    public let role: IMConversationMemberRole
    public let memberNickname: String?
    public let displayTitle: String

    public init(
        id: UUID,
        email: String,
        displayName: String? = nil,
        avatarPreset: UserAvatarPreset? = nil,
        role: IMConversationMemberRole,
        memberNickname: String? = nil,
        displayTitle: String? = nil
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.avatarPreset = avatarPreset
        self.role = role
        self.memberNickname = memberNickname
        self.displayTitle = displayTitle ?? memberNickname ?? displayName ?? email
    }
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
    public var muteAll: Bool
    public var memberCount: Int
    public var memberUserIDs: [UUID]
    public var members: [IMConversationMember]
    public var messages: [IMConversationMessage]
    public var pendingMessages: [IMPendingConversationMessage]
    public var notices: [IMTimelineNotice]
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
        !isDirectMessagingFrozen && !muteAll
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
        muteAll: Bool = false,
        memberCount: Int,
        memberUserIDs: [UUID],
        members: [IMConversationMember],
        messages: [IMConversationMessage],
        pendingMessages: [IMPendingConversationMessage] = [],
        notices: [IMTimelineNotice] = [],
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
        self.muteAll = muteAll
        self.memberCount = memberCount
        self.memberUserIDs = memberUserIDs
        self.members = members
        self.messages = messages
        self.pendingMessages = pendingMessages
        self.notices = notices
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

    public var timelineItems: [IMConversationTimelineItem] {
        let messageItems = messages.map(IMConversationTimelineItem.message)
        let pendingItems = pendingMessages.map(IMConversationTimelineItem.pendingMessage)
        return (messageItems + notices.map(IMConversationTimelineItem.notice) + pendingItems)
            .sorted { lhs, rhs in
                switch (lhs.timelineSequence, rhs.timelineSequence) {
                case let (left?, right?):
                    if left == right {
                        return lhs.id < rhs.id
                    }
                    return left < right
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    let leftDate = lhs.pendingSortDate ?? .distantFuture
                    let rightDate = rhs.pendingSortDate ?? .distantFuture
                    if leftDate == rightDate {
                        return lhs.id < rhs.id
                    }
                    return leftDate < rightDate
                }
            }
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
    public let shouldFetchDomainEvents: Bool
    public let didConsumeEvent: Bool

    public init(
        shouldReloadMembersForConversationID: String?,
        shouldFetchDomainEvents: Bool = false,
        didConsumeEvent: Bool = true
    ) {
        self.shouldReloadMembersForConversationID = shouldReloadMembersForConversationID
        self.shouldFetchDomainEvents = shouldFetchDomainEvents
        self.didConsumeEvent = didConsumeEvent
    }
}

public enum IMDeferredDomainEventReplayResult: Equatable, Sendable {
    case applied(UUID)
    case stillMissingDependency(UUID)
    case invalidPayload(UUID?)
    case expired(UUID)
    case requiresFullTimelineRefresh(String)
}

public struct IMDomainEventDebugMetrics: Equatable, Sendable {
    public var invalidDomainEventMetadata = 0
    public var missingRequiredNotice = 0
    public var deferredStored = 0
    public var deferredEncodeFailed = 0
    public var deferredNotDeferrable = 0
    public var deferredReplayApplied = 0
    public var deferredExpired = 0
    public var deferredFullRefreshRequested = 0
    public var cacheDroppedCanonicalMessages = 0
    public var cacheDroppedTimelineNotices = 0
    public var invalidCanonicalMessageDTOs = 0
    public var invalidProjectionDTOs = 0
    public var sequenceDecodeOverflow = 0
    public var realtimeMissingDeliveryRow = 0
    public var catchUpCursorGap = 0
    public var catchUpStoppedBeforeCursorAdvance = 0
    public var invalidDeferredPayload = 0

    public init() {}
}

public struct IMConversationMemberPageState: Equatable, Sendable {
    public var items: [IMConversationMember]
    public var query: String
    public var nextCursor: String?
    public var total: Int
    public var limit: Int
    public var isLoading: Bool
    public var isLoadingMore: Bool

    public var canLoadMore: Bool {
        nextCursor != nil
    }

    public init(
        items: [IMConversationMember] = [],
        query: String = "",
        nextCursor: String? = nil,
        total: Int = 0,
        limit: Int = 50,
        isLoading: Bool = false,
        isLoadingMore: Bool = false
    ) {
        self.items = items
        self.query = query
        self.nextCursor = nextCursor
        self.total = total
        self.limit = limit
        self.isLoading = isLoading
        self.isLoadingMore = isLoadingMore
    }
}
