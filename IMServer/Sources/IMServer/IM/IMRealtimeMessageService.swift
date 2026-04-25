import Fluent
import SQLKit
import Vapor

struct IMRealtimeMessagePersistenceResult: Sendable {
    let conversationID: UUID
    let acknowledgement: IMTCPAckPayload
    let message: IMTCPMessagePayload
    let recipientUserIDs: [UUID]
    let didCreateMessage: Bool
}

enum IMRealtimeMessageError: Error, LocalizedError, Equatable, Sendable {
    case invalidConversationID
    case conversationUnavailable
    case unsupportedMessageContent
    case emptyTextBody
    case invalidReplyReference
    case directConversationFrozen
    case strangerDirectMessageLimitReached

    var ackStatus: String {
        switch self {
        case .invalidConversationID:
            return "invalid_conversation_id"
        case .conversationUnavailable:
            return "conversation_unavailable"
        case .unsupportedMessageContent:
            return "unsupported_message_content"
        case .emptyTextBody:
            return "empty_text_body"
        case .invalidReplyReference:
            return "invalid_reply_reference"
        case .directConversationFrozen:
            return "direct_conversation_frozen"
        case .strangerDirectMessageLimitReached:
            return "stranger_direct_message_limit_reached"
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidConversationID:
            return "会话 ID 无效。"
        case .conversationUnavailable:
            return "会话不存在或当前用户不在该会话中。"
        case .unsupportedMessageContent:
            return "当前消息类型不支持发送。"
        case .emptyTextBody:
            return "文本消息不能为空。"
        case .invalidReplyReference:
            return "回复引用无效。"
        case .directConversationFrozen:
            return "你们已不是好友，当前会话不能继续发送消息。"
        case .strangerDirectMessageLimitReached:
            return "你们还不是好友，对方回复前只能发送一条消息。"
        }
    }
}

struct IMRealtimeMessageService {
    private struct ConversationMembershipContext {
        let conversationKind: IMConversationKind
        let directMessagingState: IMDirectMessagingState
        let memberUserIDs: [UUID]
    }

    let db: any Database

    func persistIncomingMessage(
        _ payload: IMTCPMessagePayload,
        senderUserID: UUID
    ) async throws -> IMRealtimeMessagePersistenceResult {
        let normalizedConversationID = payload.conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let conversationID = UUID(uuidString: normalizedConversationID) else {
            throw IMRealtimeMessageError.invalidConversationID
        }

        let normalizedContent = try normalizedContent(from: payload.content)
        let trimmedClientMessageID = payload.clientMessageID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedClientMessageID = trimmedClientMessageID?.isEmpty == false ? trimmedClientMessageID : nil
        let serverTimestamp = Date()

        let result = try await db.transaction { database in
            let membershipContext = try await requireConversationMembershipContext(
                conversationID: conversationID,
                senderUserID: senderUserID,
                on: database
            )
            let recipientUserIDs = membershipContext.memberUserIDs
            let canonicalContent = try await canonicalizeReplyReferenceIfNeeded(
                normalizedContent,
                conversationID: conversationID,
                on: database
            )
            if let existingMessage = try await existingMessage(
                conversationID: conversationID,
                senderUserID: senderUserID,
                clientMessageID: normalizedClientMessageID,
                on: database
            ) {
                return try makePersistenceResult(
                    conversationID: conversationID,
                    message: existingMessage,
                    recipientUserIDs: recipientUserIDs,
                    didCreateMessage: false
                )
            }

            try await enforceStrangerOneToOneMessageLimitIfNeeded(
                conversationID: conversationID,
                conversationKind: membershipContext.conversationKind,
                directMessagingState: membershipContext.directMessagingState,
                senderUserID: senderUserID,
                memberUserIDs: recipientUserIDs,
                on: database
            )
            let serverSequence = try await allocateNextServerSequence(
                conversationID: conversationID,
                updatedAt: serverTimestamp,
                on: database
            )
            let message = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: senderUserID,
                serverSequence: serverSequence,
                clientMessageID: normalizedClientMessageID,
                content: canonicalContent
            )
            try await message.create(on: database)
            try await advanceReadSequence(
                conversationID: conversationID,
                userID: senderUserID,
                readSequence: serverSequence,
                on: database
            )

            return try makePersistenceResult(
                conversationID: conversationID,
                message: message,
                recipientUserIDs: recipientUserIDs,
                didCreateMessage: true,
                fallbackTimestamp: serverTimestamp
            )
        }

        if result.didCreateMessage {
            try await IMConversationSummaryProjectionService(db: db).refreshConversationSummaries(
                conversationID: conversationID,
                recipientUserIDs: result.recipientUserIDs
            )
        }

        return result
    }

    private func existingMessage(
        conversationID: UUID,
        senderUserID: UUID,
        clientMessageID: String?,
        on database: any Database
    ) async throws -> ConversationMessage? {
        guard let clientMessageID else {
            return nil
        }

        return try await ConversationMessage.query(on: database)
            .filter(\.$conversation.$id == conversationID)
            .filter(\.$sender.$id == senderUserID)
            .filter(\.$clientMessageID == clientMessageID)
            .first()
    }

    private func makePersistenceResult(
        conversationID: UUID,
        message: ConversationMessage,
        recipientUserIDs: [UUID],
        didCreateMessage: Bool,
        fallbackTimestamp: Date = Date()
    ) throws -> IMRealtimeMessagePersistenceResult {
        let messageID = try message.requireID().uuidString
        let content = try message.decodedContent()

        return IMRealtimeMessagePersistenceResult(
            conversationID: conversationID,
            acknowledgement: IMTCPAckPayload(
                messageID: messageID,
                conversationID: conversationID.uuidString,
                status: "accepted"
            ),
            message: IMTCPMessagePayload(
                clientMessageID: message.clientMessageID,
                messageID: messageID,
                conversationID: conversationID.uuidString,
                senderUserID: message.$sender.id,
                serverSequence: UInt64(message.serverSequence),
                serverTimestamp: message.createdAt ?? fallbackTimestamp,
                content: content
            ),
            recipientUserIDs: recipientUserIDs,
            didCreateMessage: didCreateMessage
        )
    }

    private func normalizedContent(from content: IMMessageContent) throws -> IMMessageContent {
        switch content {
        case .text(let rawText):
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw IMRealtimeMessageError.emptyTextBody
            }
            return .text(text)
        case .reply(let reference, let rawText):
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            let referenceMessageID = reference.messageID.trimmingCharacters(in: .whitespacesAndNewlines)
            let referencePreview = reference.previewText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw IMRealtimeMessageError.emptyTextBody
            }
            guard !referenceMessageID.isEmpty, !referencePreview.isEmpty else {
                throw IMRealtimeMessageError.invalidReplyReference
            }
            return .reply(
                reference: IMReplyReference(
                    messageID: referenceMessageID,
                    senderUserID: reference.senderUserID,
                    previewText: referencePreview
                ),
                text: text
            )
        case .image(let asset), .audio(let asset), .file(let asset):
            return try normalizedMediaContent(content.type, asset: asset)
        case .recalled, .system:
            throw IMRealtimeMessageError.unsupportedMessageContent
        }
    }

    private func normalizedMediaContent(
        _ type: IMMessageContentType,
        asset: IMMediaAsset
    ) throws -> IMMessageContent {
        let normalizedAssetID = asset.assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMimeType = asset.mimeType.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFilename = asset.filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAssetID.isEmpty,
              !normalizedMimeType.isEmpty,
              !normalizedFilename.isEmpty,
              asset.byteSize >= 0
        else {
            throw IMRealtimeMessageError.unsupportedMessageContent
        }

        let normalizedAsset = IMMediaAsset(
            assetID: normalizedAssetID,
            kind: asset.kind,
            mimeType: normalizedMimeType,
            byteSize: asset.byteSize,
            filename: normalizedFilename,
            width: asset.width,
            height: asset.height,
            durationMillis: asset.durationMillis,
            previewAssetID: asset.previewAssetID?.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        switch type {
        case .image:
            return .image(normalizedAsset)
        case .audio:
            return .audio(normalizedAsset)
        case .file:
            return .file(normalizedAsset)
        case .text, .reply, .recalled, .system:
            throw IMRealtimeMessageError.unsupportedMessageContent
        }
    }

    private func canonicalizeReplyReferenceIfNeeded(
        _ content: IMMessageContent,
        conversationID: UUID,
        on database: any Database
    ) async throws -> IMMessageContent {
        guard case .reply(let reference, _) = content,
              let replyMessageID = UUID(uuidString: reference.messageID)
        else {
            if case .reply = content {
                throw IMRealtimeMessageError.invalidReplyReference
            }
            return content
        }

        guard let referencedMessage = try await ConversationMessage.query(on: database)
            .filter(\.$id == replyMessageID)
            .filter(\.$conversation.$id == conversationID)
            .first()
        else {
            throw IMRealtimeMessageError.invalidReplyReference
        }

        let canonicalPreview = try canonicalReplyReferencePreview(
            for: referencedMessage.decodedContent()
        )
        guard case .reply(_, let text) = content else {
            return content
        }

        return .reply(
            reference: IMReplyReference(
                messageID: replyMessageID.uuidString,
                senderUserID: referencedMessage.$sender.id,
                previewText: canonicalPreview
            ),
            text: text
        )
    }

    private func canonicalReplyReferencePreview(for content: IMMessageContent) throws -> String {
        switch content {
        case .recalled:
            return "原消息已撤回"
        case .text, .reply, .system, .image, .audio, .file:
            let preview = content.previewText.trimmingCharacters(in: .whitespacesAndNewlines)
            return preview.isEmpty ? "原消息暂不可用" : preview
        }
    }

    private func requireConversationMembershipContext(
        conversationID: UUID,
        senderUserID: UUID,
        on database: any Database
    ) async throws -> ConversationMembershipContext {
        guard let conversation = try await Conversation.find(conversationID, on: database) else {
            throw IMRealtimeMessageError.conversationUnavailable
        }

        let memberships = try await ConversationMember.query(on: database)
            .filter(\.$conversation.$id == conversationID)
            .all()

        let memberUserIDs = memberships.map(\.$user.id).sorted { $0.uuidString < $1.uuidString }
        guard memberUserIDs.contains(senderUserID) else {
            throw IMRealtimeMessageError.conversationUnavailable
        }

        return ConversationMembershipContext(
            conversationKind: conversation.conversationKind,
            directMessagingState: conversation.directMessagingStateEnum,
            memberUserIDs: memberUserIDs
        )
    }

    private func enforceStrangerOneToOneMessageLimitIfNeeded(
        conversationID: UUID,
        conversationKind: IMConversationKind,
        directMessagingState: IMDirectMessagingState,
        senderUserID: UUID,
        memberUserIDs: [UUID],
        on database: any Database
    ) async throws {
        guard conversationKind == .direct else {
            return
        }

        guard directMessagingState == .active else {
            throw IMRealtimeMessageError.directConversationFrozen
        }

        guard memberUserIDs.count == 2,
              let peerUserID = memberUserIDs.first(where: { $0 != senderUserID })
        else {
            return
        }

        guard !(try await areContacts(senderUserID, peerUserID, on: database)) else {
            return
        }

        let directConversationIDs = try await directConversationIDsBetween(
            senderUserID,
            peerUserID,
            fallbackConversationID: conversationID,
            on: database
        )
        guard !directConversationIDs.isEmpty else {
            return
        }

        let peerHasReplied = try await ConversationMessage.query(on: database)
            .filter(\.$conversation.$id ~~ directConversationIDs)
            .filter(\.$sender.$id == peerUserID)
            .first() != nil
        guard !peerHasReplied else {
            return
        }

        let senderAlreadySent = try await ConversationMessage.query(on: database)
            .filter(\.$conversation.$id ~~ directConversationIDs)
            .filter(\.$sender.$id == senderUserID)
            .first() != nil
        guard !senderAlreadySent else {
            throw IMRealtimeMessageError.strangerDirectMessageLimitReached
        }
    }

    private func areContacts(_ lhs: UUID, _ rhs: UUID, on database: any Database) async throws -> Bool {
        let lhsHasContact = try await UserContact.query(on: database)
            .filter(\.$owner.$id == lhs)
            .filter(\.$contact.$id == rhs)
            .first() != nil
        if lhsHasContact {
            return true
        }

        return try await UserContact.query(on: database)
            .filter(\.$owner.$id == rhs)
            .filter(\.$contact.$id == lhs)
            .first() != nil
    }

    private func directConversationIDsBetween(
        _ lhs: UUID,
        _ rhs: UUID,
        fallbackConversationID: UUID,
        on database: any Database
    ) async throws -> [UUID] {
        let lhsConversationIDs = try await ConversationMember.query(on: database)
            .filter(\.$user.$id == lhs)
            .all()
            .map(\.$conversation.id)
        guard !lhsConversationIDs.isEmpty else {
            return [fallbackConversationID]
        }

        let rhsConversationIDs = try await ConversationMember.query(on: database)
            .filter(\.$user.$id == rhs)
            .filter(\.$conversation.$id ~~ lhsConversationIDs)
            .all()
            .map(\.$conversation.id)
        guard !rhsConversationIDs.isEmpty else {
            return [fallbackConversationID]
        }

        let sharedMemberships = try await ConversationMember.query(on: database)
            .filter(\.$conversation.$id ~~ rhsConversationIDs)
            .all()
        let expectedMemberIDs: Set<UUID> = [lhs, rhs]
        let exactOneToOneConversationIDs = Dictionary(grouping: sharedMemberships, by: \.$conversation.id)
            .compactMap { conversationID, memberships -> UUID? in
                let actualMemberIDs = Set(memberships.map(\.$user.id))
                return actualMemberIDs == expectedMemberIDs ? conversationID : nil
            }

        let directConversations = try await Conversation.query(on: database)
            .filter(\.$id ~~ exactOneToOneConversationIDs)
            .filter(\.$kind == IMConversationKind.direct.rawValue)
            .all()
        let directConversationIDs = try directConversations.map { try $0.requireID() }

        guard directConversationIDs.contains(fallbackConversationID) else {
            return directConversationIDs + [fallbackConversationID]
        }

        return directConversationIDs
    }

    private func allocateNextServerSequence(
        conversationID: UUID,
        updatedAt: Date,
        on database: any Database
    ) async throws -> Int {
        if let sql = database as? any SQLDatabase,
           let nextSequence = try await sql.update(Conversation.schema)
            .set(
                "last_message_sequence",
                to: SQLQueryString(
                    "MAX(\(ident: "last_message_sequence"), COALESCE((SELECT MAX(\(ident: "server_sequence")) FROM \(ident: ConversationMessage.schema) WHERE \(ident: "conversation_id") = \(bind: conversationID)), 0)) + 1"
                )
            )
            .set("updated_at", to: updatedAt)
            .where("id", .equal, conversationID)
            .returning("last_message_sequence")
            .first(decodingColumn: "last_message_sequence", as: Int.self)
        {
            return nextSequence
        }

        guard let conversation = try await Conversation.find(conversationID, on: database) else {
            throw IMRealtimeMessageError.conversationUnavailable
        }

        let latestPersistedMessageSequence = try await ConversationMessage.query(on: database)
            .filter(\.$conversation.$id == conversationID)
            .sort(\.$serverSequence, .descending)
            .first()?
            .serverSequence ?? 0
        conversation.lastMessageSequence = max(
            conversation.lastMessageSequence,
            latestPersistedMessageSequence
        ) + 1
        conversation.updatedAt = updatedAt
        try await conversation.update(on: database)
        return conversation.lastMessageSequence
    }

    private func advanceReadSequence(
        conversationID: UUID,
        userID: UUID,
        readSequence: Int,
        on database: any Database
    ) async throws {
        guard let membership = try await ConversationMember.query(on: database)
            .filter(\.$conversation.$id == conversationID)
            .filter(\.$user.$id == userID)
            .first()
        else {
            throw IMRealtimeMessageError.conversationUnavailable
        }

        guard membership.lastReadSequence < readSequence else {
            return
        }

        membership.lastReadSequence = readSequence
        try await membership.update(on: database)
    }
}
