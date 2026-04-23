import Foundation
import SwiftData

public struct IMCacheMetadataState: Sendable, Equatable {
    public let selectedConversationID: String?
    public let lastSummaryRefreshAt: Date?
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

    public var selectedConversationID: String? {
        metadata.selectedConversationID
    }

    public var lastSummaryRefreshAt: Date? {
        metadata.lastSummaryRefreshAt
    }

    public static let empty = IMConversationCacheSnapshot(
        metadata: IMCacheMetadataState(selectedConversationID: nil, lastSummaryRefreshAt: nil),
        conversations: [],
        cursors: []
    )

    init(
        metadata: IMCacheMetadataState,
        conversations: [IMCachedConversationState],
        cursors: [IMSyncCursorState]
    ) {
        self.metadata = metadata
        self.conversations = conversations
        self.cursors = cursors
    }

    init(
        conversations: [IMCachedConversationState],
        selectedConversationID: String?,
        lastSummaryRefreshAt: Date?
    ) {
        self.init(
            metadata: IMCacheMetadataState(
                selectedConversationID: selectedConversationID,
                lastSummaryRefreshAt: lastSummaryRefreshAt
            ),
            conversations: conversations,
            cursors: conversations.map { conversation in
                IMSyncCursorState(
                    conversationID: conversation.id,
                    hasLoadedMessages: conversation.hasLoadedMessages,
                    latestSyncedServerSequence: conversation.latestSyncedServerSequence,
                    oldestLoadedServerSequence: conversation.oldestLoadedServerSequence
                )
            }
        )
    }
}

public struct IMCachedConversationState: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let kind: IMConversationKind
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
    public let updatedAt: Date
}

public struct IMCachedMessageState: Identifiable, Sendable, Equatable {
    public let id: String
    public let conversationID: String
    public let clientMessageID: String?
    public let serverMessageID: String?
    public let senderUserID: UUID?
    public let serverSequence: UInt64?
    public let kind: String
    public let text: String
    public let direction: IMMessageDirection
    public let createdAt: Date
    public let deliveryState: IMMessageDeliveryState
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

@Model
public final class IMCacheMetadataEntity {
    @Attribute(.unique) var recordID: String
    public var ownerUserID: String
    public var selectedConversationID: String?
    public var lastSummaryRefreshAt: Date?

    init(
        recordID: String,
        ownerUserID: String,
        selectedConversationID: String?,
        lastSummaryRefreshAt: Date?
    ) {
        self.recordID = recordID
        self.ownerUserID = ownerUserID
        self.selectedConversationID = selectedConversationID
        self.lastSummaryRefreshAt = lastSummaryRefreshAt
    }
}

@Model
public final class IMCachedConversationSummaryEntity {
    @Attribute(.unique) var recordID: String
    public var ownerUserID: String
    public var conversationID: String
    public var title: String
    public var kindRawValue: String
    public var memberCount: Int
    public var memberUserIDsBlob: String
    public var lastMessagePreviewText: String
    public var updatedAt: Date
    public var serverLastReadSequence: Int
    public var serverUnreadCount: Int

    init(
        recordID: String,
        ownerUserID: String,
        conversationID: String,
        title: String,
        kindRawValue: String,
        memberCount: Int,
        memberUserIDsBlob: String,
        lastMessagePreviewText: String,
        updatedAt: Date,
        serverLastReadSequence: Int,
        serverUnreadCount: Int
    ) {
        self.recordID = recordID
        self.ownerUserID = ownerUserID
        self.conversationID = conversationID
        self.title = title
        self.kindRawValue = kindRawValue
        self.memberCount = memberCount
        self.memberUserIDsBlob = memberUserIDsBlob
        self.lastMessagePreviewText = lastMessagePreviewText
        self.updatedAt = updatedAt
        self.serverLastReadSequence = serverLastReadSequence
        self.serverUnreadCount = serverUnreadCount
    }
}

@Model
public final class IMCachedMessageEntity {
    @Attribute(.unique) var recordID: String
    public var ownerUserID: String
    public var conversationID: String
    public var messageID: String
    public var clientMessageID: String?
    public var senderUserID: String?
    public var serverSequence: Int?
    public var kind: String
    public var textPreview: String
    public var directionRawValue: String
    public var createdAt: Date
    public var deliveryStateRawValue: String
    public var deliveryFailureMessage: String?

    init(
        recordID: String,
        ownerUserID: String,
        conversationID: String,
        messageID: String,
        clientMessageID: String?,
        senderUserID: String?,
        serverSequence: Int?,
        kind: String,
        textPreview: String,
        directionRawValue: String,
        createdAt: Date,
        deliveryStateRawValue: String,
        deliveryFailureMessage: String?
    ) {
        self.recordID = recordID
        self.ownerUserID = ownerUserID
        self.conversationID = conversationID
        self.messageID = messageID
        self.clientMessageID = clientMessageID
        self.senderUserID = senderUserID
        self.serverSequence = serverSequence
        self.kind = kind
        self.textPreview = textPreview
        self.directionRawValue = directionRawValue
        self.createdAt = createdAt
        self.deliveryStateRawValue = deliveryStateRawValue
        self.deliveryFailureMessage = deliveryFailureMessage
    }
}

@Model
public final class IMSyncCursorEntity {
    @Attribute(.unique) var recordID: String
    public var ownerUserID: String
    public var conversationID: String
    public var hasLoadedMessages: Bool
    public var latestSyncedServerSequence: Int
    public var oldestLoadedServerSequence: Int

    init(
        recordID: String,
        ownerUserID: String,
        conversationID: String,
        hasLoadedMessages: Bool,
        latestSyncedServerSequence: Int,
        oldestLoadedServerSequence: Int
    ) {
        self.recordID = recordID
        self.ownerUserID = ownerUserID
        self.conversationID = conversationID
        self.hasLoadedMessages = hasLoadedMessages
        self.latestSyncedServerSequence = latestSyncedServerSequence
        self.oldestLoadedServerSequence = oldestLoadedServerSequence
    }
}

@ModelActor
public actor IMConversationCacheModelActor {
    public func loadSnapshot(for ownerUserID: String) throws -> IMConversationCacheSnapshot {
        let metadataDescriptor = FetchDescriptor<IMCacheMetadataEntity>(
            predicate: #Predicate { $0.ownerUserID == ownerUserID }
        )
        let summaryDescriptor = FetchDescriptor<IMCachedConversationSummaryEntity>(
            predicate: #Predicate { $0.ownerUserID == ownerUserID }
        )
        let messageDescriptor = FetchDescriptor<IMCachedMessageEntity>(
            predicate: #Predicate { $0.ownerUserID == ownerUserID }
        )
        let cursorDescriptor = FetchDescriptor<IMSyncCursorEntity>(
            predicate: #Predicate { $0.ownerUserID == ownerUserID }
        )

        let metadata = try modelContext.fetch(metadataDescriptor).first
        let summaries = try modelContext.fetch(summaryDescriptor)
        let messages = try modelContext.fetch(messageDescriptor)
        let cursors = try modelContext.fetch(cursorDescriptor)

        let messagesByConversationID = Dictionary(grouping: messages, by: \.conversationID)
        let cursorsByConversationID = Dictionary(uniqueKeysWithValues: cursors.map { ($0.conversationID, $0) })
        let cursorStates = cursors.map { cursor in
            IMSyncCursorState(
                conversationID: cursor.conversationID,
                hasLoadedMessages: cursor.hasLoadedMessages,
                latestSyncedServerSequence: Self.sequenceValue(
                    from: cursor.latestSyncedServerSequence,
                    fallback: nil
                ),
                oldestLoadedServerSequence: cursor.hasLoadedMessages
                    ? Self.sequenceValue(from: cursor.oldestLoadedServerSequence, fallback: nil)
                    : nil
            )
        }

        let conversations = summaries.map { summary in
            let cachedMessages = (messagesByConversationID[summary.conversationID] ?? [])
                .map(Self.cachedMessageState(from:))
                .sorted(by: Self.cachedMessageComparator)
            let cursor = cursorsByConversationID[summary.conversationID]

            return IMCachedConversationState(
                id: summary.conversationID,
                title: summary.title,
                kind: IMConversationKind(rawValue: summary.kindRawValue) ?? .group,
                memberCount: summary.memberCount,
                memberUserIDs: Self.decodeUUIDs(from: summary.memberUserIDsBlob),
                messages: cachedMessages,
                hasLoadedMessages: cursor?.hasLoadedMessages ?? false,
                lastMessagePreviewText: summary.lastMessagePreviewText,
                hasMoreHistory: (cursor?.hasLoadedMessages ?? false) && (cursor?.oldestLoadedServerSequence ?? 0) > 1,
                latestSyncedServerSequence: Self.sequenceValue(
                    from: cursor?.latestSyncedServerSequence,
                    fallback: cachedMessages.compactMap(\.serverSequence).max()
                ),
                oldestLoadedServerSequence: (cursor?.hasLoadedMessages ?? false)
                    ? Self.sequenceValue(
                        from: cursor?.oldestLoadedServerSequence,
                        fallback: cachedMessages.compactMap(\.serverSequence).min()
                    )
                    : nil,
                serverLastReadSequence: UInt64(max(0, summary.serverLastReadSequence)),
                serverUnreadCount: max(0, summary.serverUnreadCount),
                updatedAt: summary.updatedAt
            )
        }
        .sorted { left, right in
            if left.updatedAt == right.updatedAt {
                return left.id < right.id
            }
            return left.updatedAt > right.updatedAt
        }

        return IMConversationCacheSnapshot(
            metadata: IMCacheMetadataState(
                selectedConversationID: metadata?.selectedConversationID,
                lastSummaryRefreshAt: metadata?.lastSummaryRefreshAt
            ),
            conversations: conversations,
            cursors: cursorStates
        )
    }

    public func saveSnapshot(_ snapshot: IMConversationCacheSnapshot, for ownerUserID: String) throws {
        try deleteMetadata(for: ownerUserID)
        try deleteEntities(for: ownerUserID, summaries: true)
        try deleteEntities(for: ownerUserID, summaries: false)
        try deleteCursors(for: ownerUserID)

        modelContext.insert(
            IMCacheMetadataEntity(
                recordID: Self.metadataRecordID(ownerUserID: ownerUserID),
                ownerUserID: ownerUserID,
                selectedConversationID: snapshot.metadata.selectedConversationID,
                lastSummaryRefreshAt: snapshot.metadata.lastSummaryRefreshAt
            )
        )

        let cursorsByConversationID = Dictionary(
            uniqueKeysWithValues: snapshot.cursors.map { ($0.conversationID, $0) }
        )

        for conversation in snapshot.conversations {
            let cursor = cursorsByConversationID[conversation.id]

            modelContext.insert(
                IMCachedConversationSummaryEntity(
                    recordID: Self.summaryRecordID(ownerUserID: ownerUserID, conversationID: conversation.id),
                    ownerUserID: ownerUserID,
                    conversationID: conversation.id,
                    title: conversation.title,
                    kindRawValue: conversation.kind.rawValue,
                    memberCount: conversation.memberCount,
                    memberUserIDsBlob: Self.encodeUUIDs(conversation.memberUserIDs),
                    lastMessagePreviewText: conversation.lastMessagePreviewText,
                    updatedAt: conversation.updatedAt,
                    serverLastReadSequence: Int(min(conversation.serverLastReadSequence, UInt64(Int.max))),
                    serverUnreadCount: max(0, conversation.serverUnreadCount)
                )
            )

            modelContext.insert(
                IMSyncCursorEntity(
                    recordID: Self.cursorRecordID(ownerUserID: ownerUserID, conversationID: conversation.id),
                    ownerUserID: ownerUserID,
                    conversationID: conversation.id,
                    hasLoadedMessages: cursor?.hasLoadedMessages ?? conversation.hasLoadedMessages,
                    latestSyncedServerSequence: Int(min(
                        cursor?.latestSyncedServerSequence ?? conversation.latestSyncedServerSequence ?? 0,
                        UInt64(Int.max)
                    )),
                    oldestLoadedServerSequence: Int(min(
                        cursor?.oldestLoadedServerSequence ?? conversation.oldestLoadedServerSequence ?? 0,
                        UInt64(Int.max)
                    ))
                )
            )

            for message in conversation.messages {
                modelContext.insert(
                    IMCachedMessageEntity(
                        recordID: Self.messageRecordID(ownerUserID: ownerUserID, conversationID: conversation.id, messageID: message.id),
                        ownerUserID: ownerUserID,
                        conversationID: conversation.id,
                        messageID: message.id,
                        clientMessageID: message.clientMessageID,
                        senderUserID: message.senderUserID?.uuidString,
                        serverSequence: message.serverSequence.map { Int(min($0, UInt64(Int.max))) },
                        kind: message.kind,
                        textPreview: message.text,
                        directionRawValue: message.direction.rawValue,
                        createdAt: message.createdAt,
                        deliveryStateRawValue: Self.deliveryStateRawValue(from: message.deliveryState),
                        deliveryFailureMessage: Self.deliveryFailureMessage(from: message.deliveryState)
                    )
                )
            }
        }

        try modelContext.save()
    }

    public func clearSnapshot(for ownerUserID: String) throws {
        try deleteMetadata(for: ownerUserID)
        try deleteEntities(for: ownerUserID, summaries: true)
        try deleteEntities(for: ownerUserID, summaries: false)
        try deleteCursors(for: ownerUserID)
        try modelContext.save()
    }

    public func clearAll() throws {
        try deleteAllMetadata()
        try deleteAllSummaries()
        try deleteAllMessages()
        try deleteAllCursors()
        try modelContext.save()
    }

    private func deleteMetadata(for ownerUserID: String) throws {
        let descriptor = FetchDescriptor<IMCacheMetadataEntity>(
            predicate: #Predicate { $0.ownerUserID == ownerUserID }
        )
        try modelContext.fetch(descriptor).forEach(modelContext.delete)
    }

    private func deleteEntities(for ownerUserID: String, summaries: Bool) throws {
        if summaries {
            let descriptor = FetchDescriptor<IMCachedConversationSummaryEntity>(
                predicate: #Predicate { $0.ownerUserID == ownerUserID }
            )
            try modelContext.fetch(descriptor).forEach(modelContext.delete)
        } else {
            let descriptor = FetchDescriptor<IMCachedMessageEntity>(
                predicate: #Predicate { $0.ownerUserID == ownerUserID }
            )
            try modelContext.fetch(descriptor).forEach(modelContext.delete)
        }
    }

    private func deleteCursors(for ownerUserID: String) throws {
        let descriptor = FetchDescriptor<IMSyncCursorEntity>(
            predicate: #Predicate { $0.ownerUserID == ownerUserID }
        )
        try modelContext.fetch(descriptor).forEach(modelContext.delete)
    }

    private func deleteAllMetadata() throws {
        try modelContext.fetch(FetchDescriptor<IMCacheMetadataEntity>()).forEach(modelContext.delete)
    }

    private func deleteAllSummaries() throws {
        try modelContext.fetch(FetchDescriptor<IMCachedConversationSummaryEntity>()).forEach(modelContext.delete)
    }

    private func deleteAllMessages() throws {
        try modelContext.fetch(FetchDescriptor<IMCachedMessageEntity>()).forEach(modelContext.delete)
    }

    private func deleteAllCursors() throws {
        try modelContext.fetch(FetchDescriptor<IMSyncCursorEntity>()).forEach(modelContext.delete)
    }

    private static func cachedMessageState(from entity: IMCachedMessageEntity) -> IMCachedMessageState {
        IMCachedMessageState(
            id: entity.messageID,
            conversationID: entity.conversationID,
            clientMessageID: entity.clientMessageID,
            serverMessageID: entity.serverSequence == nil ? nil : entity.messageID,
            senderUserID: entity.senderUserID.flatMap(UUID.init(uuidString:)),
            serverSequence: entity.serverSequence.map(UInt64.init),
            kind: entity.kind,
            text: entity.textPreview,
            direction: IMMessageDirection(rawValue: entity.directionRawValue) ?? .incoming,
            createdAt: entity.createdAt,
            deliveryState: deliveryState(
                rawValue: entity.deliveryStateRawValue,
                failureMessage: entity.deliveryFailureMessage
            )
        )
    }

    private static func cachedMessageComparator(_ left: IMCachedMessageState, _ right: IMCachedMessageState) -> Bool {
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

    private static func summaryRecordID(ownerUserID: String, conversationID: String) -> String {
        "\(ownerUserID)|summary|\(conversationID)"
    }

    private static func metadataRecordID(ownerUserID: String) -> String {
        "\(ownerUserID)|metadata"
    }

    private static func cursorRecordID(ownerUserID: String, conversationID: String) -> String {
        "\(ownerUserID)|cursor|\(conversationID)"
    }

    private static func messageRecordID(ownerUserID: String, conversationID: String, messageID: String) -> String {
        "\(ownerUserID)|message|\(conversationID)|\(messageID)"
    }

    private static func encodeUUIDs(_ uuids: [UUID]) -> String {
        uuids.map(\.uuidString).sorted().joined(separator: ",")
    }

    private static func decodeUUIDs(from blob: String) -> [UUID] {
        blob.split(separator: ",")
            .compactMap { UUID(uuidString: String($0)) }
            .sorted { $0.uuidString < $1.uuidString }
    }

    private static func deliveryStateRawValue(from state: IMMessageDeliveryState) -> String {
        switch state {
        case .sending:
            return "sending"
        case .sent:
            return "sent"
        case .received:
            return "received"
        case .failed:
            return "failed"
        }
    }

    private static func deliveryFailureMessage(from state: IMMessageDeliveryState) -> String? {
        if case .failed(let message) = state {
            return message
        }
        return nil
    }

    private static func deliveryState(rawValue: String, failureMessage: String?) -> IMMessageDeliveryState {
        switch rawValue {
        case "sending":
            return .sending
        case "sent":
            return .sent
        case "received":
            return .received
        case "failed":
            return .failed(message: failureMessage ?? "unknown")
        default:
            return .received
        }
    }

    private static func sequenceValue(
        from rawValue: Int?,
        fallback: UInt64?
    ) -> UInt64? {
        if let rawValue, rawValue > 0 {
            return UInt64(rawValue)
        }

        return fallback
    }
}

public final class SwiftDataIMConversationCache: IMConversationCaching, @unchecked Sendable {
    private let modelActor: IMConversationCacheModelActor

    init(modelContainer: ModelContainer) {
        self.modelActor = IMConversationCacheModelActor(modelContainer: modelContainer)
    }

    public func loadSnapshot(for ownerUserID: UUID) async throws -> IMConversationCacheSnapshot {
        try await modelActor.loadSnapshot(for: ownerUserID.uuidString)
    }

    public func saveSnapshot(_ snapshot: IMConversationCacheSnapshot, for ownerUserID: UUID) async throws {
        try await modelActor.saveSnapshot(snapshot, for: ownerUserID.uuidString)
    }

    public func clearSnapshot(for ownerUserID: UUID) async throws {
        try await modelActor.clearSnapshot(for: ownerUserID.uuidString)
    }

    public func clearAll() async throws {
        try await modelActor.clearAll()
    }

    public static func makeDefaultHandler() -> IMConversationCacheHandler {
        do {
            let container = try ModelContainer(
                for: IMCacheMetadataEntity.self,
                IMCachedConversationSummaryEntity.self,
                IMCachedMessageEntity.self,
                IMSyncCursorEntity.self
            )
            return IMConversationCacheHandler(
                SwiftDataIMConversationCache(modelContainer: container)
            )
        } catch {
            return IMConversationCacheHandler(NoopIMConversationCache())
        }
    }
}
