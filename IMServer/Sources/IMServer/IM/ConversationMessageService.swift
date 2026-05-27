import Fluent
import Vapor

struct ConversationMessageService {
    private enum RecallPolicy {
        static let window: TimeInterval = 2 * 60
    }

    private enum EditPolicy {
        static let window: TimeInterval = 15 * 60
    }

    let db: any Database

    func recallMessage(
        in conversationID: UUID,
        messageID: UUID,
        requesterUserID: UUID,
        on database: any Database
    ) async throws -> ConversationMessage {
        guard let message = try await ConversationMessage.query(on: database)
            .filter(\.$id == messageID)
            .filter(\.$conversation.$id == conversationID)
            .first()
        else {
            throw Abort(.notFound, reason: "消息不存在。")
        }

        guard message.$sender.id == requesterUserID else {
            throw Abort(.forbidden, reason: "只能撤回自己发送的消息。")
        }

        let messageCreatedAt = message.createdAt ?? .distantPast
        guard Date().timeIntervalSince(messageCreatedAt) <= RecallPolicy.window else {
            throw Abort(.badRequest, reason: "消息发送超过 2 分钟后不能撤回。")
        }

        let derivedState = try message.decodedDerivedState()
        guard !derivedState.isRecalled else {
            throw Abort(.badRequest, reason: "该消息已经撤回。")
        }

        try message.replaceDerivedState(.init(
            recallState: .recalled,
            edits: derivedState.edits,
            reactions: derivedState.reactions,
            streamState: derivedState.streamState
        ))
        try await message.update(on: database)
        return message
    }

    func editMessage(
        in conversationID: UUID,
        messageID: UUID,
        body rawBody: IMRichTextContent,
        requesterUserID: UUID,
        on database: any Database
    ) async throws -> ConversationMessage {
        let body = try IMRealtimeMessageService(fixedDatabaseForLowLevelTest: database).normalizedRichTextForCommand(rawBody)
        try await validateMentionTargets(in: body, conversationID: conversationID, on: database)

        guard let message = try await ConversationMessage.query(on: database)
            .filter(\.$id == messageID)
            .filter(\.$conversation.$id == conversationID)
            .first()
        else {
            throw Abort(.notFound, reason: "消息不存在。")
        }

        guard message.$sender.id == requesterUserID else {
            throw Abort(.forbidden, reason: "只能编辑自己发送的消息。")
        }

        let createdAt = message.createdAt ?? .distantPast
        guard Date().timeIntervalSince(createdAt) <= EditPolicy.window else {
            throw Abort(.badRequest, reason: "消息发送超过 15 分钟后不能编辑。")
        }

        let content = try message.decodedContent()
        var derivedState = try message.decodedDerivedState()
        guard !derivedState.isRecalled else {
            throw Abort(.badRequest, reason: "已撤回的消息不能编辑。")
        }

        switch content {
        case .richText(let originalBody):
            guard originalBody != body else {
                return message
            }
        case .reply(_, let originalBody):
            guard originalBody != body else {
                return message
            }
        case .image, .audio, .file:
            throw Abort(.badRequest, reason: "当前消息不支持编辑。")
        }

        derivedState = IMMessageDerivedState(
            recallState: derivedState.recallState,
            edits: derivedState.edits + [.init(editedAt: Date(), body: body)],
            reactions: derivedState.reactions
        )
        try message.replaceDerivedState(derivedState)
        try await message.update(on: database)
        return message
    }

    func toggleReaction(
        in conversationID: UUID,
        messageID: UUID,
        emoji rawEmoji: String,
        requesterUserID: UUID,
        on database: any Database
    ) async throws -> ConversationMessage {
        let emoji = rawEmoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !emoji.isEmpty else {
            throw Abort(.badRequest, reason: "表情不能为空。")
        }

        guard let message = try await ConversationMessage.query(on: database)
            .filter(\.$id == messageID)
            .filter(\.$conversation.$id == conversationID)
            .first()
        else {
            throw Abort(.notFound, reason: "消息不存在。")
        }

        var derivedState = try message.decodedDerivedState()
        guard !derivedState.isRecalled else {
            throw Abort(.badRequest, reason: "已撤回的消息不能添加表情。")
        }

        var reactions = derivedState.reactions
        if let index = reactions.firstIndex(where: { $0.emoji == emoji }) {
            var actorUserIDs = reactions[index].actorUserIDs
            if let existingIndex = actorUserIDs.firstIndex(of: requesterUserID) {
                actorUserIDs.remove(at: existingIndex)
            } else {
                actorUserIDs.append(requesterUserID)
                actorUserIDs.sort { $0.uuidString < $1.uuidString }
            }

            if actorUserIDs.isEmpty {
                reactions.remove(at: index)
            } else {
                reactions[index] = .init(emoji: emoji, actorUserIDs: actorUserIDs)
            }
        } else {
            reactions.append(.init(emoji: emoji, actorUserIDs: [requesterUserID]))
            reactions.sort { $0.emoji < $1.emoji }
        }

        derivedState = IMMessageDerivedState(
            recallState: derivedState.recallState,
            edits: derivedState.edits,
            reactions: reactions
        )
        try message.replaceDerivedState(derivedState)
        try await message.update(on: database)
        return message
    }

    private func validateMentionTargets(
        in body: IMRichTextContent,
        conversationID: UUID,
        on database: any Database
    ) async throws {
        let mentionUserIDs = body.entities.compactMap { entity -> UUID? in
            if case .mention(_, let userID) = entity {
                return userID
            }
            return nil
        }
        guard !mentionUserIDs.isEmpty else {
            return
        }

        let memberships = try await ConversationMember.query(on: database)
            .filter(\.$conversation.$id == conversationID)
            .filter(\.$user.$id ~~ mentionUserIDs)
            .all()
        guard Set(memberships.map(\.$user.id)) == Set(mentionUserIDs) else {
            throw Abort(.badRequest, reason: "提及的用户不在当前会话中。")
        }
    }

    func makePreview(from message: ConversationMessage) throws -> IMMessagePreviewResponse {
        let content = try message.decodedContent()
        let derivedState = try message.decodedDerivedState()
        return IMMessagePreviewResponse(
            id: try message.requireID(),
            senderUserID: message.$sender.id,
            serverSequence: try imPositiveUInt64Sequence(message.serverSequence, field: "server_sequence"),
            timelineSequence: try imPositiveUInt64Sequence(message.timelineSequence, field: "timeline_sequence"),
            content: content,
            derivedState: derivedState,
            createdAt: message.createdAt
        )
    }

    func messageResponse(
        from message: ConversationMessage,
        conversationID: UUID
    ) throws -> IMMessageResponse {
        let content = try message.decodedContent()
        let derivedState = try message.decodedDerivedState()
        return IMMessageResponse(
            id: try message.requireID(),
            conversationID: conversationID,
            senderUserID: message.$sender.id,
            clientMessageID: message.clientMessageID,
            serverSequence: try imPositiveUInt64Sequence(message.serverSequence, field: "server_sequence"),
            timelineSequence: try imPositiveUInt64Sequence(message.timelineSequence, field: "timeline_sequence"),
            content: content,
            derivedState: derivedState,
            createdAt: message.createdAt
        )
    }
}
