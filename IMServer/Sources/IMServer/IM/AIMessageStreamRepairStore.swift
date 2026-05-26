import Fluent
import Vapor

struct AIMessageStreamRepairStore {
    private static let pageSize = 100

    let app: Application

    func auditConsistency() async throws -> [AIMessageStreamConsistencyIssue] {
        var issues: [AIMessageStreamConsistencyIssue] = []
        for shard in app.conversationShardRouter.allCommandDatabases() {
            issues.append(contentsOf: try await auditIndexes(on: shard.database))
            issues.append(contentsOf: try await auditMessagesMissingIndex(on: shard.database))
        }
        return issues
    }

    @discardableResult
    func repair(index: AIMessageStreamIndex, reason: AIStreamRepairReason, now: Date) async throws -> Bool {
        try await AIMessageStreamWriteStore(app: app).repair(index: index, reason: reason, now: now)
    }

    private func auditIndexes(on database: any Database) async throws -> [AIMessageStreamConsistencyIssue] {
        var issues: [AIMessageStreamConsistencyIssue] = []
        let indexes = try await AIMessageStreamIndex.query(on: database).all()
        for index in indexes {
            guard let message = try await ConversationMessage.query(on: database)
                .filter(\.$id == index.messageID)
                .filter(\.$conversation.$id == index.conversationID)
                .first()
            else {
                issues.append(.init(kind: .missingMessage, streamID: index.streamID, messageID: index.messageID, conversationID: index.conversationID))
                continue
            }
            guard let streamState = try message.decodedDerivedState().streamState,
                  streamState.streamID == index.streamID
            else {
                issues.append(.init(kind: .missingDerivedState, streamID: index.streamID, messageID: index.messageID, conversationID: index.conversationID))
                continue
            }
            if streamState.state != index.lifecycleState {
                issues.append(.init(kind: .stateMismatch, streamID: index.streamID, messageID: index.messageID, conversationID: index.conversationID))
            }
            if index.lastChunkIndex < streamState.lastChunkIndex {
                issues.append(.init(kind: .chunkIndexRegressed, streamID: index.streamID, messageID: index.messageID, conversationID: index.conversationID))
            }
            if index.lifecycleState != .streaming, index.terminalAt == nil {
                issues.append(.init(kind: .missingTerminalAt, streamID: index.streamID, messageID: index.messageID, conversationID: index.conversationID))
            }
        }
        return issues
    }

    private func auditMessagesMissingIndex(on database: any Database) async throws -> [AIMessageStreamConsistencyIssue] {
        var issues: [AIMessageStreamConsistencyIssue] = []
        var offset = 0
        while true {
            let messages = try await ConversationMessage.query(on: database)
                .filter(\.$kind == IMMessageContentType.richText.rawValue)
                .sort(\.$createdAt)
                .range(offset..<(offset + Self.pageSize))
                .all()
            guard !messages.isEmpty else {
                break
            }
            for message in messages {
                guard let messageID = message.id,
                      let streamState = try message.decodedDerivedState().streamState,
                      try await AIMessageStreamIndex.find(streamState.streamID, on: database) == nil
                else {
                    continue
                }
                issues.append(.init(
                    kind: .missingIndex,
                    streamID: streamState.streamID,
                    messageID: messageID,
                    conversationID: message.$conversation.id
                ))
            }
            guard messages.count == Self.pageSize else {
                break
            }
            offset += Self.pageSize
        }
        return issues
    }
}
