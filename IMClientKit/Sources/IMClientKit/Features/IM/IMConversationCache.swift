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

public struct IMSyncCursorState: Sendable, Equatable {
    public let conversationID: String
    public let hasLoadedMessages: Bool
    public let latestSyncedServerSequence: UInt64?
    public let oldestLoadedServerSequence: UInt64?
}

public struct IMConversationCacheSnapshot: Sendable, Equatable {
    public static let cachedMessageLimit = 200

    public let metadata: IMCacheMetadataState
    public let conversations: [IMCachedConversationState]
    public let cursors: [IMSyncCursorState]
    public let transferSnapshots: [IMTransferSnapshot]

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
        transferSnapshots: []
    )

    init(
        metadata: IMCacheMetadataState,
        conversations: [IMCachedConversationState],
        cursors: [IMSyncCursorState],
        transferSnapshots: [IMTransferSnapshot] = []
    ) {
        self.metadata = metadata
        self.conversations = conversations
        self.cursors = cursors
        self.transferSnapshots = transferSnapshots
    }

    init(
        conversations: [IMCachedConversationState],
        selectedConversationID: String?,
        lastSummaryRefreshAt: Date?,
        summarySyncToken: String?,
        summaryNextCursor: String?,
        hasMoreConversationSummaries: Bool,
        transferSnapshots: [IMTransferSnapshot] = []
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
                    latestSyncedServerSequence: conversation.latestSyncedServerSequence,
                    oldestLoadedServerSequence: conversation.oldestLoadedServerSequence
                )
            },
            transferSnapshots: transferSnapshots
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
    public let hasLoadedMessages: Bool
    public let lastMessagePreviewText: String
    public let hasMoreHistory: Bool
    public let latestSyncedServerSequence: UInt64?
    public let oldestLoadedServerSequence: UInt64?
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
        hasLoadedMessages: Bool,
        lastMessagePreviewText: String,
        hasMoreHistory: Bool,
        latestSyncedServerSequence: UInt64?,
        oldestLoadedServerSequence: UInt64?,
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
        self.hasLoadedMessages = hasLoadedMessages
        self.lastMessagePreviewText = lastMessagePreviewText
        self.hasMoreHistory = hasMoreHistory
        self.latestSyncedServerSequence = latestSyncedServerSequence
        self.oldestLoadedServerSequence = oldestLoadedServerSequence
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

public struct IMCachedMessageState: Identifiable, Sendable, Equatable {
    public let id: String
    public let conversationID: String
    public let clientMessageID: String?
    public let serverMessageID: String?
    public let senderUserID: UUID?
    public let serverSequence: UInt64?
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
        serverMessageID: String?,
        senderUserID: UUID?,
        serverSequence: UInt64?,
        content: IMMessageContent,
        derivedState: MessageDerivedState = MessageDerivedState(),
        direction: IMMessageDirection,
        createdAt: Date,
        deliveryState: IMMessageDeliveryState,
        transferTaskID: TransferTaskID? = nil,
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
        self.derivedState = content.derivedState.isRecalled ? content.derivedState : derivedState
        self.direction = direction
        self.createdAt = createdAt
        self.deliveryState = deliveryState
        self.transferTaskID = transferTaskID
        self.localTransferState = localTransferState
        self.localDownloadState = localDownloadState
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
