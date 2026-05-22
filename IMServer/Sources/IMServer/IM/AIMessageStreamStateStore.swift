import Vapor

// Facade for AI stream state. Keep transaction details in the read/write/repair
// stores so provider, policy, and fanout code cannot bypass the state boundary.
struct AIMessageStreamPublishEnvelope: Sendable {
    let response: IMMessageStreamResponse
    let recipients: [UUID]
    let eventType: IMTCPConversationEventType
    let actorUserID: UUID
    let shouldPublish: Bool
}

struct AIMessageStreamStartEnvelope: Sendable {
    let response: IMMessageStreamResponse
    let recipientUserIDs: [UUID]
}

enum AIStreamRepairReason: Equatable, Sendable {
    case serverRestarted
    case streamLost

    var errorCode: String {
        switch self {
        case .serverRestarted:
            "server_restarted"
        case .streamLost:
            "stream_lost"
        }
    }

    var errorMessage: String {
        switch self {
        case .serverRestarted:
            "AI stream was interrupted by server restart."
        case .streamLost:
            "AI stream was interrupted before a terminal state was persisted."
        }
    }
}

struct AIMessageStreamConsistencyIssue: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case missingIndex
        case missingMessage
        case missingDerivedState
        case stateMismatch
        case chunkIndexRegressed
        case missingTerminalAt
    }

    let kind: Kind
    let streamID: String
    let messageID: UUID?
    let conversationID: UUID?
}

protocol AIMessageStreamStateReading {
    func snapshot(
        conversationID: UUID,
        messageID: UUID,
        userID: UUID
    ) async throws -> IMMessageStreamResponse
}

protocol AIMessageStreamStateWriting {
    func createInitialStreamingMessage(
        streamID: String,
        conversationID: UUID,
        userID: UUID
    ) async throws -> AIMessageStreamStartEnvelope

    @discardableResult
    func updateSnapshot(
        streamID: String,
        conversationID: UUID,
        messageID: UUID,
        partialText: String,
        chunkIndex: Int,
        state: MessageStreamLifecycleState,
        errorCode: String?,
        errorMessage: String?
    ) async throws -> IMMessageResponse

    @discardableResult
    func finalize(
        streamID: String,
        conversationID: UUID,
        messageID: UUID,
        userID: UUID,
        finalText: String,
        state: MessageStreamLifecycleState,
        errorCode: String?,
        errorMessage: String?
    ) async throws -> AIMessageStreamPublishEnvelope
}

protocol AIMessageStreamRepairing {
    @discardableResult
    func backfillMissingStreamIndexes(now: Date) async throws -> Int

    func auditConsistency() async throws -> [AIMessageStreamConsistencyIssue]

    @discardableResult
    func repair(index: AIMessageStreamIndex, reason: AIStreamRepairReason, now: Date) async throws -> Bool
}

struct AIMessageStreamStateStore {
    let app: Application

    func createInitialStreamingMessage(
        streamID: String,
        conversationID: UUID,
        userID: UUID
    ) async throws -> AIMessageStreamStartEnvelope {
        try await AIMessageStreamWriteStore(app: app).createInitialStreamingMessage(
            streamID: streamID,
            conversationID: conversationID,
            userID: userID
        )
    }

    func snapshot(
        conversationID: UUID,
        messageID: UUID,
        userID: UUID
    ) async throws -> IMMessageStreamResponse {
        try await AIMessageStreamReadStore(app: app).snapshot(
            conversationID: conversationID,
            messageID: messageID,
            userID: userID
        )
    }

    @discardableResult
    func updateSnapshot(
        streamID: String,
        conversationID: UUID,
        messageID: UUID,
        partialText: String,
        chunkIndex: Int,
        state: MessageStreamLifecycleState,
        errorCode: String? = nil,
        errorMessage: String? = nil
    ) async throws -> IMMessageResponse {
        try await AIMessageStreamWriteStore(app: app).updateSnapshot(
            streamID: streamID,
            conversationID: conversationID,
            messageID: messageID,
            partialText: partialText,
            chunkIndex: chunkIndex,
            state: state,
            errorCode: errorCode,
            errorMessage: errorMessage
        )
    }

    @discardableResult
    func finalize(
        streamID: String,
        conversationID: UUID,
        messageID: UUID,
        userID: UUID,
        finalText: String,
        state: MessageStreamLifecycleState,
        errorCode: String?,
        errorMessage: String?
    ) async throws -> AIMessageStreamPublishEnvelope {
        try await AIMessageStreamWriteStore(app: app).finalize(
            streamID: streamID,
            conversationID: conversationID,
            messageID: messageID,
            userID: userID,
            finalText: finalText,
            state: state,
            errorCode: errorCode,
            errorMessage: errorMessage
        )
    }

    @discardableResult
    func backfillMissingStreamIndexes(now: Date = Date()) async throws -> Int {
        try await AIMessageStreamRepairStore(app: app).backfillMissingStreamIndexes(now: now)
    }

    func auditConsistency() async throws -> [AIMessageStreamConsistencyIssue] {
        try await AIMessageStreamRepairStore(app: app).auditConsistency()
    }

    @discardableResult
    func repair(index: AIMessageStreamIndex, reason: AIStreamRepairReason, now: Date) async throws -> Bool {
        try await AIMessageStreamRepairStore(app: app).repair(index: index, reason: reason, now: now)
    }
}

extension AIMessageStreamStateStore: AIMessageStreamStateReading, AIMessageStreamStateWriting, AIMessageStreamRepairing {}
