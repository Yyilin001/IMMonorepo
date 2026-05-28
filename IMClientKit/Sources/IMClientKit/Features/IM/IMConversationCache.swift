import Foundation

public struct IMCacheMetadataState: Sendable, Equatable {
    public let selectedConversationID: String?
    public let lastSummaryRefreshAt: Date?
    public let summarySyncToken: String?
    public let summaryNextCursor: String?
    public let hasMoreConversationSummaries: Bool

    public init(
        selectedConversationID: String?,
        lastSummaryRefreshAt: Date?,
        summarySyncToken: String? = nil,
        summaryNextCursor: String? = nil,
        hasMoreConversationSummaries: Bool = false
    ) {
        self.selectedConversationID = selectedConversationID
        self.lastSummaryRefreshAt = lastSummaryRefreshAt
        self.summarySyncToken = summarySyncToken
        self.summaryNextCursor = summaryNextCursor
        self.hasMoreConversationSummaries = hasMoreConversationSummaries
    }
}

public enum IMDeferredDomainEventMissingKey: Codable, Sendable, Equatable, Hashable {
    case message(String)
    case conversation(String)
    case stream(conversationID: String, messageID: String)
}

public struct IMDeferredDomainEventState: Codable, Sendable, Equatable, Identifiable {
    public let eventID: UUID
    public let conversationID: String?
    public let missingKey: IMDeferredDomainEventMissingKey
    public let firstSeenAt: Date
    public let retryCount: Int
    public let ownerCursor: UInt64?
    public let ownerAggregateSequence: UInt64?
    public let eventPBBase64: String

    public var id: UUID { eventID }

    public init(
        eventID: UUID,
        conversationID: String?,
        missingKey: IMDeferredDomainEventMissingKey,
        firstSeenAt: Date,
        retryCount: Int,
        ownerCursor: UInt64? = nil,
        ownerAggregateSequence: UInt64? = nil,
        eventPBBase64: String
    ) {
        self.eventID = eventID
        self.conversationID = conversationID
        self.missingKey = missingKey
        self.firstSeenAt = firstSeenAt
        self.retryCount = retryCount
        self.ownerCursor = ownerCursor
        self.ownerAggregateSequence = ownerAggregateSequence
        self.eventPBBase64 = eventPBBase64
    }
}

public struct IMOwnerAggregateHighWatermarkState: Codable, Sendable, Equatable, Hashable {
    public let aggregateType: String
    public let aggregateID: String
    public let sequence: UInt64

    public init(aggregateType: String, aggregateID: String, sequence: UInt64) {
        self.aggregateType = aggregateType
        self.aggregateID = aggregateID
        self.sequence = sequence
    }
}

public struct IMDomainEventCacheState: Sendable, Equatable {
    public let cursor: UInt64
    public let appliedEventIDs: [UUID]
    public let ownerAggregateHighWatermarks: [IMOwnerAggregateHighWatermarkState]
    public let deferredEvents: [IMDeferredDomainEventState]
    public let fullRefreshConversationIDs: [String]

    public init(
        cursor: UInt64 = 0,
        appliedEventIDs: [UUID] = [],
        ownerAggregateHighWatermarks: [IMOwnerAggregateHighWatermarkState] = [],
        deferredEvents: [IMDeferredDomainEventState] = [],
        fullRefreshConversationIDs: [String] = []
    ) {
        self.cursor = cursor
        self.appliedEventIDs = appliedEventIDs
        self.ownerAggregateHighWatermarks = ownerAggregateHighWatermarks
        self.deferredEvents = deferredEvents
        self.fullRefreshConversationIDs = fullRefreshConversationIDs
    }
}

public struct IMSyncCursorState: Sendable, Equatable {
    public let conversationID: String
    public let hasLoadedMessages: Bool
    public let latestLoadedTimelineSequence: UInt64?
    public let oldestLoadedTimelineSequence: UInt64?
}

public struct IMConversationCacheSnapshot: Sendable, Equatable {
    public static let cachedMessageLimit = 200

    public let metadata: IMCacheMetadataState
    public let conversations: [IMCachedConversationState]
    public let cursors: [IMSyncCursorState]
    public let transferSnapshots: [IMTransferSnapshot]
    public let domainEventState: IMDomainEventCacheState
    public let diagnostics: IMCacheRestoreDiagnostics

    public var selectedConversationID: String? {
        metadata.selectedConversationID
    }

    public var lastSummaryRefreshAt: Date? {
        metadata.lastSummaryRefreshAt
    }

    public static let empty = IMConversationCacheSnapshot(
        metadata: IMCacheMetadataState(
            selectedConversationID: nil,
            lastSummaryRefreshAt: nil,
            summarySyncToken: nil,
            summaryNextCursor: nil,
            hasMoreConversationSummaries: false
        ),
        conversations: [],
        cursors: [],
        transferSnapshots: [],
        domainEventState: IMDomainEventCacheState(),
        diagnostics: IMCacheRestoreDiagnostics()
    )

    init(
        metadata: IMCacheMetadataState,
        conversations: [IMCachedConversationState],
        cursors: [IMSyncCursorState],
        transferSnapshots: [IMTransferSnapshot] = [],
        domainEventState: IMDomainEventCacheState = IMDomainEventCacheState(),
        diagnostics: IMCacheRestoreDiagnostics = IMCacheRestoreDiagnostics()
    ) {
        self.metadata = metadata
        self.conversations = conversations
        self.cursors = cursors
        self.transferSnapshots = transferSnapshots
        self.domainEventState = domainEventState
        self.diagnostics = diagnostics
    }

    init(
        conversations: [IMCachedConversationState],
        selectedConversationID: String?,
        lastSummaryRefreshAt: Date?,
        summarySyncToken: String?,
        summaryNextCursor: String?,
        hasMoreConversationSummaries: Bool,
        transferSnapshots: [IMTransferSnapshot] = [],
        domainEventState: IMDomainEventCacheState = IMDomainEventCacheState()
    ) {
        self.init(
            metadata: IMCacheMetadataState(
                selectedConversationID: selectedConversationID,
                lastSummaryRefreshAt: lastSummaryRefreshAt,
                summarySyncToken: summarySyncToken,
                summaryNextCursor: summaryNextCursor,
                hasMoreConversationSummaries: hasMoreConversationSummaries
            ),
            conversations: conversations,
            cursors: conversations.map { conversation in
                IMSyncCursorState(
                    conversationID: conversation.id,
                    hasLoadedMessages: conversation.hasLoadedMessages,
                    latestLoadedTimelineSequence: conversation.latestLoadedTimelineSequence,
                    oldestLoadedTimelineSequence: conversation.oldestLoadedTimelineSequence
                )
            },
            transferSnapshots: transferSnapshots,
            domainEventState: domainEventState
        )
    }
}

public struct IMCachedConversationState: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let kind: IMConversationKind
    public let directMessagingState: IMDirectMessagingState?
    public let directPeer: IMDirectPeer?
    public let notice: String?
    public let avatarPreset: IMConversationAvatarPreset?
    public let memberCount: Int
    public let memberUserIDs: [UUID]
    public let messages: [IMCachedMessageState]
    public let pendingMessages: [IMCachedPendingMessageState]
    public let notices: [IMCachedTimelineNoticeState]
    public let hasLoadedMessages: Bool
    public let lastMessagePreviewText: String
    public let hasMoreHistory: Bool
    public let latestLoadedTimelineSequence: UInt64?
    public let oldestLoadedTimelineSequence: UInt64?
    public let serverLastReadSequence: UInt64
    public let serverUnreadCount: Int
    public let isPinned: Bool
    public let pinnedAt: Date?
    public let isMuted: Bool
    public let draftText: String
    public let draftUpdatedAt: Date?
    public let updatedAt: Date

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
        messages: [IMCachedMessageState],
        pendingMessages: [IMCachedPendingMessageState] = [],
        notices: [IMCachedTimelineNoticeState] = [],
        hasLoadedMessages: Bool,
        lastMessagePreviewText: String,
        hasMoreHistory: Bool,
        latestLoadedTimelineSequence: UInt64?,
        oldestLoadedTimelineSequence: UInt64?,
        serverLastReadSequence: UInt64,
        serverUnreadCount: Int,
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
        self.messages = messages
        self.pendingMessages = pendingMessages
        self.notices = notices
        self.hasLoadedMessages = hasLoadedMessages
        self.lastMessagePreviewText = lastMessagePreviewText
        self.hasMoreHistory = hasMoreHistory
        self.latestLoadedTimelineSequence = latestLoadedTimelineSequence
        self.oldestLoadedTimelineSequence = oldestLoadedTimelineSequence
        self.serverLastReadSequence = serverLastReadSequence
        self.serverUnreadCount = serverUnreadCount
        self.isPinned = isPinned
        self.pinnedAt = pinnedAt
        self.isMuted = isMuted
        self.draftText = draftText
        self.draftUpdatedAt = draftUpdatedAt
        self.updatedAt = updatedAt
    }
}

public struct IMCachedTimelineNoticeState: Identifiable, Codable, Sendable, Equatable {
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

    private enum CodingKeys: String, CodingKey {
        case id
        case conversationID
        case timelineSequence
        case eventType
        case actorUserID
        case targetUserIDs
        case noticeKind
        case params
        case fallbackText
        case createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(String.self, forKey: .id),
            conversationID: container.decode(String.self, forKey: .conversationID),
            timelineSequence: container.decode(UInt64.self, forKey: .timelineSequence),
            eventType: container.decode(String.self, forKey: .eventType),
            actorUserID: container.decodeIfPresent(UUID.self, forKey: .actorUserID),
            targetUserIDs: container.decode([UUID].self, forKey: .targetUserIDs),
            noticeKind: container.decode(String.self, forKey: .noticeKind),
            params: container.decodeIfPresent([String: String].self, forKey: .params) ?? [:],
            fallbackText: container.decode(String.self, forKey: .fallbackText),
            createdAt: container.decode(Date.self, forKey: .createdAt)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(conversationID, forKey: .conversationID)
        try container.encode(timelineSequence, forKey: .timelineSequence)
        try container.encode(eventType, forKey: .eventType)
        try container.encodeIfPresent(actorUserID, forKey: .actorUserID)
        try container.encode(targetUserIDs, forKey: .targetUserIDs)
        try container.encode(noticeKind, forKey: .noticeKind)
        try container.encode(params, forKey: .params)
        try container.encode(fallbackText, forKey: .fallbackText)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

public struct IMCachedMessageState: Identifiable, Sendable, Equatable {
    public let id: String
    public let conversationID: String
    public let clientMessageID: String?
    public let serverMessageID: String
    public let senderUserID: UUID
    public let serverSequence: UInt64
    public let timelineSequence: UInt64
    public let content: IMMessageContent
    public let derivedState: MessageDerivedState
    public let direction: IMMessageDirection
    public let createdAt: Date
    public let deliveryState: IMMessageDeliveryState
    public let transferTaskID: TransferTaskID?
    public let localTransferState: IMMessageLocalTransferState?
    public let localDownloadState: IMMessageLocalDownloadState?

    public var text: String {
        content.presentation(derivedState: derivedState).previewText
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

public struct IMCachedPendingMessageState: Identifiable, Sendable, Equatable, Codable {
    public let id: String
    public let localMessageID: String
    public let clientMessageID: String
    public let conversationID: String
    public let senderUserID: UUID
    public let content: IMMessageContent
    public let createdAt: Date
    public let deliveryState: IMMessageDeliveryState
    public let transferTaskID: TransferTaskID?
    public let localTransferState: IMMessageLocalTransferState?
    public let localDownloadState: IMMessageLocalDownloadState?

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

    private enum CodingKeys: String, CodingKey {
        case id
        case localMessageID
        case clientMessageID
        case conversationID
        case senderUserID
        case content
        case createdAt
        case deliveryStateRawValue
        case deliveryFailureMessage
        case transferTaskID
        case localTransferState
        case localDownloadState
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawValue = try container.decode(String.self, forKey: .deliveryStateRawValue)
        let failureMessage = try container.decodeIfPresent(String.self, forKey: .deliveryFailureMessage)
        self.init(
            localMessageID: try container.decode(String.self, forKey: .localMessageID),
            clientMessageID: try container.decode(String.self, forKey: .clientMessageID),
            conversationID: try container.decode(String.self, forKey: .conversationID),
            senderUserID: try container.decode(UUID.self, forKey: .senderUserID),
            content: try container.decode(IMMessageContent.self, forKey: .content),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            deliveryState: Self.deliveryState(rawValue: rawValue, message: failureMessage),
            transferTaskID: try container.decodeIfPresent(TransferTaskID.self, forKey: .transferTaskID),
            localTransferState: try container.decodeIfPresent(IMMessageLocalTransferState.self, forKey: .localTransferState),
            localDownloadState: try container.decodeIfPresent(IMMessageLocalDownloadState.self, forKey: .localDownloadState)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(localMessageID, forKey: .localMessageID)
        try container.encode(clientMessageID, forKey: .clientMessageID)
        try container.encode(conversationID, forKey: .conversationID)
        try container.encode(senderUserID, forKey: .senderUserID)
        try container.encode(content, forKey: .content)
        try container.encode(createdAt, forKey: .createdAt)
        let encodedDeliveryState = Self.encodedDeliveryState(deliveryState)
        try container.encode(encodedDeliveryState.rawValue, forKey: .deliveryStateRawValue)
        try container.encodeIfPresent(encodedDeliveryState.message, forKey: .deliveryFailureMessage)
        try container.encodeIfPresent(transferTaskID, forKey: .transferTaskID)
        try container.encodeIfPresent(localTransferState, forKey: .localTransferState)
        try container.encodeIfPresent(localDownloadState, forKey: .localDownloadState)
    }

    private static func encodedDeliveryState(_ state: IMMessageDeliveryState) -> (rawValue: String, message: String?) {
        switch state {
        case .preparing(let message):
            return ("preparing", message)
        case .uploading(let message):
            return ("uploading", message)
        case .uploaded:
            return ("uploaded", nil)
        case .queued(let message):
            return ("queued", message)
        case .sending:
            return ("sending", nil)
        case .sent:
            return ("sent", nil)
        case .received:
            return ("received", nil)
        case .unknown(let message):
            return ("unknown", message)
        case .failed(let message):
            return ("failed", message)
        }
    }

    private static func deliveryState(rawValue: String, message: String?) -> IMMessageDeliveryState {
        switch rawValue {
        case "preparing":
            return .preparing(message: message ?? "正在准备发送。")
        case "uploading":
            return .uploading(message: message ?? "正在上传附件。")
        case "uploaded":
            return .uploaded
        case "queued":
            return .queued(message: message ?? "等待 IM 长连接恢复后发送。")
        case "sending":
            return .sending
        case "sent":
            return .sent
        case "received":
            return .received
        case "failed":
            return .failed(message: message ?? "消息发送失败。")
        case "unknown":
            return .unknown(message: message ?? "发送状态未确认。")
        default:
            return .unknown(message: message ?? "发送状态未确认。")
        }
    }
}

public protocol IMConversationCaching: Sendable {
    func loadSnapshot(for ownerUserID: UUID) async throws -> IMConversationCacheSnapshot
    func saveSnapshot(_ snapshot: IMConversationCacheSnapshot, for ownerUserID: UUID) async throws
    func clearSnapshot(for ownerUserID: UUID) async throws
    func clearAll() async throws
}

public struct IMConversationCacheHandler: Sendable {
    private let loadSnapshotHandler: @Sendable (UUID) async throws -> IMConversationCacheSnapshot
    private let saveSnapshotHandler: @Sendable (IMConversationCacheSnapshot, UUID) async throws -> Void
    private let clearSnapshotHandler: @Sendable (UUID) async throws -> Void
    private let clearAllHandler: @Sendable () async throws -> Void

    public init<Cache: IMConversationCaching>(_ cache: Cache) {
        loadSnapshotHandler = { ownerUserID in
            try await cache.loadSnapshot(for: ownerUserID)
        }
        saveSnapshotHandler = { snapshot, ownerUserID in
            try await cache.saveSnapshot(snapshot, for: ownerUserID)
        }
        clearSnapshotHandler = { ownerUserID in
            try await cache.clearSnapshot(for: ownerUserID)
        }
        clearAllHandler = {
            try await cache.clearAll()
        }
    }

    public func loadSnapshot(for ownerUserID: UUID) async throws -> IMConversationCacheSnapshot {
        try await loadSnapshotHandler(ownerUserID)
    }

    public func saveSnapshot(_ snapshot: IMConversationCacheSnapshot, for ownerUserID: UUID) async throws {
        try await saveSnapshotHandler(snapshot, ownerUserID)
    }

    public func clearSnapshot(for ownerUserID: UUID) async throws {
        try await clearSnapshotHandler(ownerUserID)
    }

    public func clearAll() async throws {
        try await clearAllHandler()
    }
}

public struct NoopIMConversationCache: IMConversationCaching {
    public init() { }

    public func loadSnapshot(for ownerUserID: UUID) async throws -> IMConversationCacheSnapshot {
        _ = ownerUserID
        return .empty
    }

    public func saveSnapshot(_ snapshot: IMConversationCacheSnapshot, for ownerUserID: UUID) async throws {
        _ = snapshot
        _ = ownerUserID
    }

    public func clearSnapshot(for ownerUserID: UUID) async throws {
        _ = ownerUserID
    }

    public func clearAll() async throws { }
}
