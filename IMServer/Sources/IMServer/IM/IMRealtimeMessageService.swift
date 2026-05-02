import Fluent
import SQLKit
import Vapor

struct IMInternalMessageSendRequest: Content, Sendable {
    let payload: IMTCPMessagePayload
    let senderUserID: UUID
}

struct IMRealtimeMessagePersistenceResult: Content, Sendable {
    let conversationID: UUID
    let acknowledgement: IMTCPAckPayload
    let message: IMTCPMessagePayload
    let recipientUserIDs: [UUID]
    let didCreateMessage: Bool
}

struct IMPreparedIncomingMessage: Sendable {
    let payload: IMTCPMessagePayload
    let senderUserID: UUID
    let conversationID: UUID
    let normalizedContent: IMMessageContent
    let normalizedClientMessageID: String?
    let serverTimestamp: Date
}

enum IMRealtimeMessageError: Error, LocalizedError, Equatable, Sendable {
    case invalidConversationID
    case conversationUnavailable
    case unsupportedMessageContent
    case emptyTextBody
    case invalidReplyReference
    case directConversationFrozen
    case strangerDirectMessageLimitReached
    case hotConversationRateLimited

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
        case .hotConversationRateLimited:
            return "hot_conversation_rate_limited"
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
        case .hotConversationRateLimited:
            return "当前会话消息过于频繁，请稍后再试。"
        }
    }
}

struct IMRealtimeMessageService {
    private struct ConversationMembershipContext {
        let conversationKind: IMConversationKind
        let directMessagingState: IMDirectMessagingState
        let memberUserIDs: [UUID]
    }

    private let app: Application?
    private let fixedDatabase: (any Database)?

    init(app: Application) {
        self.app = app
        self.fixedDatabase = nil
    }

    init(db: any Database) {
        self.app = nil
        self.fixedDatabase = db
    }

    func persistIncomingMessage(
        _ payload: IMTCPMessagePayload,
        senderUserID: UUID
    ) async throws -> IMRealtimeMessagePersistenceResult {
        let normalizedConversationID = payload.conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let conversationID = UUID(uuidString: normalizedConversationID) else {
            throw IMRealtimeMessageError.invalidConversationID
        }

        if let forwardedResult = try await forwardToOwnerIfNeeded(
            payload,
            senderUserID: senderUserID,
            conversationID: conversationID
        ) {
            return forwardedResult
        }

        if let app, app.messageWriteBatchConfiguration.isEnabled {
            let prepared = try await prepareIncomingMessage(
                payload,
                senderUserID: senderUserID,
                conversationID: conversationID
            )
            return try await app.messageWriteBatcher.enqueue(
                .init(message: prepared),
                conversationID: conversationID,
                app: app,
                configuration: app.messageWriteBatchConfiguration
            )
        }

        if let app {
            return try await app.conversationWriteCoordinator.run(conversationID: conversationID, app: app) {
                try await persistOwnedIncomingMessage(payload, senderUserID: senderUserID)
            }
        }

        return try await persistOwnedIncomingMessage(payload, senderUserID: senderUserID)
    }

    func persistOwnedIncomingMessage(
        _ payload: IMTCPMessagePayload,
        senderUserID: UUID
    ) async throws -> IMRealtimeMessagePersistenceResult {
        let normalizedConversationID = payload.conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let conversationID = UUID(uuidString: normalizedConversationID) else {
            throw IMRealtimeMessageError.invalidConversationID
        }
        let prepared = try await prepareIncomingMessage(
            payload,
            senderUserID: senderUserID,
            conversationID: conversationID
        )
        guard let result = try await persistOwnedIncomingMessagesBatch([prepared], conversationID: conversationID).first else {
            throw IMRealtimeMessageError.conversationUnavailable
        }
        return result
    }

    func persistOwnedIncomingMessagesBatch(
        _ preparedMessages: [IMPreparedIncomingMessage],
        conversationID: UUID
    ) async throws -> [IMRealtimeMessagePersistenceResult] {
        guard !preparedMessages.isEmpty else {
            return []
        }
        let routedDatabase = try await database(forConversationID: conversationID)
        let preallocatedServerSequences = try await preallocateServerSequencesIfNeeded(
            count: preparedMessages.count,
            conversationID: conversationID,
            updatedAt: preparedMessages.last?.serverTimestamp ?? Date(),
            on: routedDatabase
        )

        return try await routedDatabase.transaction { database in
            let membershipContext = try await requireConversationMembershipContext(
                conversationID: conversationID,
                senderUserID: preparedMessages[0].senderUserID,
                on: database
            )
            let recipientUserIDs = membershipContext.memberUserIDs
            var results: [IMRealtimeMessagePersistenceResult] = []
            results.reserveCapacity(preparedMessages.count)

            for (index, prepared) in preparedMessages.enumerated() {
                guard prepared.conversationID == conversationID,
                      recipientUserIDs.contains(prepared.senderUserID)
                else {
                    throw IMRealtimeMessageError.conversationUnavailable
                }

                let canonicalContent = try await canonicalizeReplyReferenceIfNeeded(
                    prepared.normalizedContent,
                    conversationID: conversationID,
                    on: database
                )
                if let existingMessage = try await existingMessage(
                    conversationID: conversationID,
                    senderUserID: prepared.senderUserID,
                    clientMessageID: prepared.normalizedClientMessageID,
                    on: database
                ) {
                    results.append(
                        try makePersistenceResult(
                            conversationID: conversationID,
                            message: existingMessage,
                            recipientUserIDs: recipientUserIDs,
                            didCreateMessage: false
                        )
                    )
                    continue
                }

                try await enforceStrangerOneToOneMessageLimitIfNeeded(
                    conversationID: conversationID,
                    conversationKind: membershipContext.conversationKind,
                    directMessagingState: membershipContext.directMessagingState,
                    senderUserID: prepared.senderUserID,
                    memberUserIDs: recipientUserIDs,
                    on: database
                )
                let serverSequence: Int
                if let preallocatedServerSequences {
                    serverSequence = preallocatedServerSequences[index]
                } else {
                    serverSequence = try await allocateNextServerSequence(
                        conversationID: conversationID,
                        updatedAt: prepared.serverTimestamp,
                        on: database
                    )
                }
                let message = try ConversationMessage(
                    conversationID: conversationID,
                    senderUserID: prepared.senderUserID,
                    serverSequence: serverSequence,
                    clientMessageID: prepared.normalizedClientMessageID,
                    content: canonicalContent
                )
                try await message.create(on: database)
                try await advanceReadSequence(
                    conversationID: conversationID,
                    userID: prepared.senderUserID,
                    readSequence: serverSequence,
                    on: database
                )
                try await ConversationOutboxService(db: database).enqueue(
                    type: .messageCreated,
                    conversationID: conversationID,
                    payload: ConversationDomainEventPayload(
                        recipientUserIDs: recipientUserIDs,
                        messageID: try message.requireID()
                    )
                )

                results.append(
                    try makePersistenceResult(
                        conversationID: conversationID,
                        message: message,
                        recipientUserIDs: recipientUserIDs,
                        didCreateMessage: true,
                        fallbackTimestamp: prepared.serverTimestamp
                    )
                )
            }
            return results
        }
    }

    private func prepareIncomingMessage(
        _ payload: IMTCPMessagePayload,
        senderUserID: UUID,
        conversationID: UUID
    ) async throws -> IMPreparedIncomingMessage {
        try await reserveHotConversationCapacityIfNeeded(conversationID: conversationID)
        let normalizedContent = try normalizedContent(from: payload.content)
        let trimmedClientMessageID = payload.clientMessageID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return IMPreparedIncomingMessage(
            payload: payload,
            senderUserID: senderUserID,
            conversationID: conversationID,
            normalizedContent: normalizedContent,
            normalizedClientMessageID: trimmedClientMessageID?.isEmpty == false ? trimmedClientMessageID : nil,
            serverTimestamp: Date()
        )
    }

    private func preallocateServerSequencesIfNeeded(
        count: Int,
        conversationID: UUID,
        updatedAt: Date,
        on database: any Database
    ) async throws -> [Int]? {
        guard let app, app.sequenceAllocationConfiguration.mode == .block else {
            return nil
        }

        var sequences: [Int] = []
        sequences.reserveCapacity(count)
        for _ in 0..<count {
            sequences.append(
                try await app.sequenceBlockAllocator.nextSequence(
                    conversationID: conversationID,
                    blockSize: app.sequenceAllocationConfiguration.blockSize,
                    updatedAt: updatedAt,
                    on: database,
                    app: app
                )
            )
        }
        return sequences
    }

    private func forwardToOwnerIfNeeded(
        _ payload: IMTCPMessagePayload,
        senderUserID: UUID,
        conversationID: UUID
    ) async throws -> IMRealtimeMessagePersistenceResult? {
        guard let app else { return nil }
        let configuration = app.commandOwnerRoutingConfiguration
        guard let owner = configuration.owner(for: conversationID),
              !(app.imRuntimeRole.servesCommandAPI && owner.id == configuration.nodeID)
        else {
            return nil
        }

        do {
            let target = URI(string: "\(owner.baseURL)/internal/im/messages/send")
            let response = try await app.client.post(target, headers: internalHeaders(sharedSecret: configuration.sharedSecret)) { req in
                try req.content.encode(
                    IMInternalMessageSendRequest(
                        payload: payload,
                        senderUserID: senderUserID
                    )
                )
            }
            guard response.status == .ok else {
                await app.messageWriteMetrics.recordOwnerForwardFailed()
                throw Abort(.serviceUnavailable, reason: "Conversation owner \(owner.id) rejected message write with \(response.status.code).")
            }
            await app.messageWriteMetrics.recordOwnerForwarded()
            return try response.content.decode(IMRealtimeMessagePersistenceResult.self)
        } catch {
            await app.messageWriteMetrics.recordOwnerForwardFailed()
            throw error
        }
    }

    private func internalHeaders(sharedSecret: String?) -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers.contentType = .json
        if let sharedSecret, !sharedSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            headers.replaceOrAdd(name: "X-IM-Internal-Secret", value: sharedSecret)
        }
        return headers
    }

    private func database(forConversationID conversationID: UUID) async throws -> any Database {
        if let fixedDatabase {
            return fixedDatabase
        }
        guard let app else {
            fatalError("IMRealtimeMessageService missing both app and database.")
        }
        return try await app.conversationShardRouter.commandDatabase(forConversationID: conversationID)
    }

    private func reserveHotConversationCapacityIfNeeded(conversationID: UUID) async throws {
        guard let app else {
            return
        }
        let configuration = app.hotConversationConfiguration
        guard configuration.isEnabled else {
            return
        }

        do {
            try await app.hotConversationLimiter.reserve(
                conversationID: conversationID,
                limit: configuration.messagesPerSecondLimit
            )
        } catch HotConversationLimiterError.rateLimited {
            await app.hotConversationMetrics.recordTrackedWindows(
                await app.hotConversationLimiter.trackedWindowCount()
            )
            await app.hotConversationMetrics.recordRejectedMessage()
            throw IMRealtimeMessageError.hotConversationRateLimited
        }
        await app.hotConversationMetrics.recordTrackedWindows(
            await app.hotConversationLimiter.trackedWindowCount()
        )
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
                content: content,
                derivedState: content.aggregate.derivedState
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
        if let app, app.conversationMemberCacheConfiguration.isEnabled,
           let cached = await app.conversationMemberCache.value(for: conversationID) {
            await app.messageWriteMetrics.recordMemberCacheHit()
            guard cached.memberUserIDs.contains(senderUserID) else {
                throw IMRealtimeMessageError.conversationUnavailable
            }
            return ConversationMembershipContext(
                conversationKind: cached.conversationKind,
                directMessagingState: cached.directMessagingState,
                memberUserIDs: cached.memberUserIDs
            )
        }
        if let app {
            await app.messageWriteMetrics.recordMemberCacheMiss()
        }

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

        if let app, app.conversationMemberCacheConfiguration.isEnabled {
            await app.conversationMemberCache.store(
                IMCachedConversationMembership(
                    conversationKind: conversation.conversationKind,
                    directMessagingState: conversation.directMessagingStateEnum,
                    memberUserIDs: memberUserIDs
                ),
                for: conversationID,
                ttlSeconds: app.conversationMemberCacheConfiguration.ttlSeconds
            )
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
        let startedAt = Date()
        defer {
            if let app {
                Task {
                    await app.databaseMetrics.record(
                        operation: "conversation_sequence_allocate",
                        durationMillis: max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
                    )
                }
            }
        }
        if let sql = database as? any SQLDatabase,
           sql.dialect.name == "postgresql",
           let nextSequence = try await sql.update(Conversation.schema)
            .set(
                "last_message_sequence",
                to: SQLQueryString(
                    "GREATEST(\(ident: "last_message_sequence"), COALESCE((SELECT MAX(\(ident: "server_sequence")) FROM \(ident: ConversationMessage.schema) WHERE \(ident: "conversation_id") = \(bind: conversationID)), 0)) + 1"
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
