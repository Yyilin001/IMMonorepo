import Fluent
import SQLKit
import Vapor

struct IMRealtimeMessagePersistenceResult: Sendable {
    let conversationID: UUID
    let acknowledgement: IMTCPAckPayload
    let message: IMTCPMessagePayload
    let recipientUserIDs: [UUID]
}

enum IMRealtimeMessageError: Error, LocalizedError, Equatable, Sendable {
    case invalidConversationID
    case conversationUnavailable
    case unsupportedMessageKind
    case emptyTextBody
    case strangerDirectMessageLimitReached

    var ackStatus: String {
        switch self {
        case .invalidConversationID:
            return "invalid_conversation_id"
        case .conversationUnavailable:
            return "conversation_unavailable"
        case .unsupportedMessageKind:
            return "unsupported_message_kind"
        case .emptyTextBody:
            return "empty_text_body"
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
        case .unsupportedMessageKind:
            return "当前只支持 text 消息。"
        case .emptyTextBody:
            return "文本消息不能为空。"
        case .strangerDirectMessageLimitReached:
            return "你们还不是好友，对方回复前只能发送一条消息。"
        }
    }
}

struct IMRealtimeMessageService {
    private struct ConversationMembershipContext {
        let conversationKind: IMConversationKind
        let memberUserIDs: [UUID]
    }

    let db: any Database

    func persistIncomingMessage(
        _ payload: IMTCPMessagePayload,
        senderUserID: UUID
    ) async throws -> IMRealtimeMessagePersistenceResult {
        guard payload.kind == "text" else {
            throw IMRealtimeMessageError.unsupportedMessageKind
        }

        let normalizedConversationID = payload.conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let conversationID = UUID(uuidString: normalizedConversationID) else {
            throw IMRealtimeMessageError.invalidConversationID
        }

        guard let text = payload.body["text"]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw IMRealtimeMessageError.emptyTextBody
        }

        let normalizedBody = ["text": text]
        let serverTimestamp = Date()

        return try await db.transaction { database in
            let membershipContext = try await requireConversationMembershipContext(
                conversationID: conversationID,
                senderUserID: senderUserID,
                on: database
            )
            let recipientUserIDs = membershipContext.memberUserIDs
            try await enforceStrangerOneToOneMessageLimitIfNeeded(
                conversationID: conversationID,
                conversationKind: membershipContext.conversationKind,
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
                clientMessageID: payload.clientMessageID,
                kind: payload.kind,
                body: normalizedBody
            )
            try await message.create(on: database)
            try await advanceReadSequence(
                conversationID: conversationID,
                userID: senderUserID,
                readSequence: serverSequence,
                on: database
            )

            let messageID = try message.requireID().uuidString

            return IMRealtimeMessagePersistenceResult(
                conversationID: conversationID,
                acknowledgement: IMTCPAckPayload(
                    messageID: messageID,
                    conversationID: conversationID.uuidString,
                    status: "accepted"
                ),
                message: IMTCPMessagePayload(
                    clientMessageID: payload.clientMessageID,
                    messageID: messageID,
                    conversationID: conversationID.uuidString,
                    senderUserID: senderUserID,
                    serverSequence: UInt64(serverSequence),
                    serverTimestamp: message.createdAt ?? serverTimestamp,
                    kind: payload.kind,
                    body: normalizedBody
                ),
                recipientUserIDs: recipientUserIDs
            )
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
            memberUserIDs: memberUserIDs
        )
    }

    private func enforceStrangerOneToOneMessageLimitIfNeeded(
        conversationID: UUID,
        conversationKind: IMConversationKind,
        senderUserID: UUID,
        memberUserIDs: [UUID],
        on database: any Database
    ) async throws {
        guard conversationKind == .direct else {
            return
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
                to: SQLQueryString("\(ident: "last_message_sequence") + 1")
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

        conversation.lastMessageSequence += 1
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
