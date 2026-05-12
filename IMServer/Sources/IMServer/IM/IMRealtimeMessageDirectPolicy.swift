import Fluent
import SQLKit
import Vapor

struct DirectPolicyBatchContext {
    private struct Evaluation {
        let shouldApplyStrangerLimit: Bool
        let senderAlreadySentBeforeBatch: Bool
    }

    let conversationID: UUID
    let conversationKind: IMConversationKind
    let directMessagingState: IMDirectMessagingState
    let memberUserIDs: [UUID]

    private var evaluationsBySenderUserID: [UUID: Evaluation] = [:]
    private var createdMessageCountsBySenderUserID: [UUID: Int] = [:]

    init(
        conversationID: UUID,
        conversationKind: IMConversationKind,
        directMessagingState: IMDirectMessagingState,
        memberUserIDs: [UUID]
    ) {
        self.conversationID = conversationID
        self.conversationKind = conversationKind
        self.directMessagingState = directMessagingState
        self.memberUserIDs = memberUserIDs
    }

    mutating func enforceBeforeCreate(
        senderUserID: UUID,
        service: IMRealtimeMessageService,
        on database: any Database
    ) async throws {
        let evaluation = try await evaluationForSender(
            senderUserID,
            service: service,
            on: database
        )
        guard evaluation.shouldApplyStrangerLimit else {
            return
        }
        guard !evaluation.senderAlreadySentBeforeBatch,
              (createdMessageCountsBySenderUserID[senderUserID] ?? 0) == 0
        else {
            throw IMRealtimeMessageError.strangerDirectMessageLimitReached
        }
    }

    mutating func recordCreated(senderUserID: UUID) {
        createdMessageCountsBySenderUserID[senderUserID, default: 0] += 1
    }

    private mutating func evaluationForSender(
        _ senderUserID: UUID,
        service: IMRealtimeMessageService,
        on database: any Database
    ) async throws -> Evaluation {
        if let cached = evaluationsBySenderUserID[senderUserID] {
            return cached
        }

        let evaluation = try await makeEvaluationForSender(
            senderUserID,
            service: service,
            on: database
        )
        evaluationsBySenderUserID[senderUserID] = evaluation
        return evaluation
    }

    private func makeEvaluationForSender(
        _ senderUserID: UUID,
        service: IMRealtimeMessageService,
        on database: any Database
    ) async throws -> Evaluation {
        guard conversationKind == .direct else {
            return Evaluation(shouldApplyStrangerLimit: false, senderAlreadySentBeforeBatch: false)
        }

        guard directMessagingState == .active else {
            throw IMRealtimeMessageError.directConversationFrozen
        }

        guard memberUserIDs.count == 2,
              let peerUserID = memberUserIDs.first(where: { $0 != senderUserID })
        else {
            return Evaluation(shouldApplyStrangerLimit: false, senderAlreadySentBeforeBatch: false)
        }

        guard !(try await service.areContacts(senderUserID, peerUserID, on: database)) else {
            return Evaluation(shouldApplyStrangerLimit: false, senderAlreadySentBeforeBatch: false)
        }

        let directConversationIDs = try await service.directConversationIDsBetween(
            senderUserID,
            peerUserID,
            fallbackConversationID: conversationID,
            on: database
        )
        guard !directConversationIDs.isEmpty else {
            return Evaluation(shouldApplyStrangerLimit: false, senderAlreadySentBeforeBatch: false)
        }

        let senderIDsWithMessages = try await service.directMessageSenderIDs(
            conversationIDs: directConversationIDs,
            senderUserID: senderUserID,
            peerUserID: peerUserID,
            on: database
        )
        if senderIDsWithMessages.contains(peerUserID) {
            return Evaluation(shouldApplyStrangerLimit: false, senderAlreadySentBeforeBatch: false)
        }

        return Evaluation(
            shouldApplyStrangerLimit: true,
            senderAlreadySentBeforeBatch: senderIDsWithMessages.contains(senderUserID)
        )
    }
}

extension IMRealtimeMessageService {
    func requireConversationMembershipContext(
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

    func enforceStrangerOneToOneMessageLimitIfNeeded(
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

        let senderIDsWithMessages = try await directMessageSenderIDs(
            conversationIDs: directConversationIDs,
            senderUserID: senderUserID,
            peerUserID: peerUserID,
            on: database
        )
        if senderIDsWithMessages.contains(peerUserID) {
            return
        }
        let senderAlreadySent = senderIDsWithMessages.contains(senderUserID)
        guard !senderAlreadySent else {
            throw IMRealtimeMessageError.strangerDirectMessageLimitReached
        }
    }

    func areContacts(_ lhs: UUID, _ rhs: UUID, on database: any Database) async throws -> Bool {
        if let sql = database as? any SQLDatabase {
            struct ContactRow: Decodable {
                let exists: Int
            }
            let row = try await sql.raw("""
                SELECT 1 AS \(ident: "exists")
                FROM \(ident: UserContact.schema)
                WHERE (
                    \(ident: "owner_user_id") = \(bind: lhs)
                    AND \(ident: "contact_user_id") = \(bind: rhs)
                ) OR (
                    \(ident: "owner_user_id") = \(bind: rhs)
                    AND \(ident: "contact_user_id") = \(bind: lhs)
                )
                LIMIT 1
                """).first(decoding: ContactRow.self)
            return row != nil
        }

        return try await UserContact.query(on: database)
            .group(.or) { group in
                group.group(.and) { relation in
                    relation.filter(\.$owner.$id == lhs)
                    relation.filter(\.$contact.$id == rhs)
                }
                group.group(.and) { relation in
                    relation.filter(\.$owner.$id == rhs)
                    relation.filter(\.$contact.$id == lhs)
                }
            }
            .first() != nil
    }

    func directConversationIDsBetween(
        _ lhs: UUID,
        _ rhs: UUID,
        fallbackConversationID: UUID,
        on database: any Database
    ) async throws -> [UUID] {
        if let app,
           let cached = await app.directConversationPairCache.conversationIDs(lhs: lhs, rhs: rhs) {
            guard cached.contains(fallbackConversationID) else {
                return cached + [fallbackConversationID]
            }
            return cached
        }

        if let directoryConversationIDs = try await directConversationIDsFromDirectory(
            lhs,
            rhs,
            fallbackConversationID: fallbackConversationID,
            on: database
        ) {
            if let app {
                await app.directConversationPairCache.store(directoryConversationIDs, lhs: lhs, rhs: rhs)
            }
            return directoryConversationIDs
        }

        if let sqlConversationIDs = try await directConversationIDsFromSQL(
            lhs,
            rhs,
            fallbackConversationID: fallbackConversationID,
            on: database
        ) {
            if let app {
                await app.directConversationPairCache.store(sqlConversationIDs, lhs: lhs, rhs: rhs)
            }
            return sqlConversationIDs
        }

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
        for conversation in directConversations {
            let conversationID = try conversation.requireID()
            try? await DirectConversationPairDirectoryService(db: database).upsert(
                lhs: lhs,
                rhs: rhs,
                conversationID: conversationID,
                directMessagingState: conversation.directMessagingStateEnum
            )
        }

        guard directConversationIDs.contains(fallbackConversationID) else {
            let result = directConversationIDs + [fallbackConversationID]
            if let app {
                await app.directConversationPairCache.store(result, lhs: lhs, rhs: rhs)
            }
            return result
        }

        if let app {
            await app.directConversationPairCache.store(directConversationIDs, lhs: lhs, rhs: rhs)
        }
        return directConversationIDs
    }

    private func directConversationIDsFromSQL(
        _ lhs: UUID,
        _ rhs: UUID,
        fallbackConversationID: UUID,
        on database: any Database
    ) async throws -> [UUID]? {
        guard let sql = database as? any SQLDatabase else {
            return nil
        }

        struct DirectConversationRow: Decodable {
            let id: UUID
            let directMessagingState: String?

            enum CodingKeys: String, CodingKey {
                case id
                case directMessagingState = "direct_messaging_state"
            }
        }

        let rows = try await sql.raw("""
            SELECT
                \(ident: "c").\(ident: "id") AS \(ident: "id"),
                \(ident: "c").\(ident: "direct_messaging_state") AS \(ident: "direct_messaging_state")
            FROM \(ident: Conversation.schema) AS \(ident: "c")
            INNER JOIN \(ident: ConversationMember.schema) AS \(ident: "m_pair")
                ON \(ident: "m_pair").\(ident: "conversation_id") = \(ident: "c").\(ident: "id")
            WHERE \(ident: "c").\(ident: "kind") = \(bind: IMConversationKind.direct.rawValue)
              AND \(ident: "m_pair").\(ident: "user_id") IN (\(bind: lhs), \(bind: rhs))
            GROUP BY \(ident: "c").\(ident: "id"), \(ident: "c").\(ident: "direct_messaging_state")
            HAVING COUNT(DISTINCT \(ident: "m_pair").\(ident: "user_id")) = 2
               AND (
                    SELECT COUNT(*)
                    FROM \(ident: ConversationMember.schema) AS \(ident: "m_all")
                    WHERE \(ident: "m_all").\(ident: "conversation_id") = \(ident: "c").\(ident: "id")
               ) = 2
            """).all(decoding: DirectConversationRow.self)

        for row in rows {
            try? await DirectConversationPairDirectoryService(db: database).upsert(
                lhs: lhs,
                rhs: rhs,
                conversationID: row.id,
                directMessagingState: row.directMessagingState.flatMap(IMDirectMessagingState.init(rawValue:)) ?? .active
            )
        }

        let conversationIDs = rows.map(\.id)
        guard conversationIDs.contains(fallbackConversationID) else {
            return conversationIDs + [fallbackConversationID]
        }
        return conversationIDs
    }

    private func directConversationIDsFromDirectory(
        _ lhs: UUID,
        _ rhs: UUID,
        fallbackConversationID: UUID,
        on database: any Database
    ) async throws -> [UUID]? {
        let directoryConversationIDs = try await DirectConversationPairDirectoryService(db: database)
            .conversationIDsBetween(lhs, rhs)
        guard !directoryConversationIDs.isEmpty else {
            return nil
        }

        guard directoryConversationIDs.contains(fallbackConversationID) else {
            return directoryConversationIDs + [fallbackConversationID]
        }
        return directoryConversationIDs
    }

    func directMessageSenderIDs(
        conversationIDs: [UUID],
        senderUserID: UUID,
        peerUserID: UUID,
        on database: any Database
    ) async throws -> Set<UUID> {
        guard !conversationIDs.isEmpty else {
            return []
        }

        if let sql = database as? any SQLDatabase {
            struct SenderRow: Decodable {
                let sender_user_id: UUID
            }

            let conversationValues = conversationIDs.map { conversationID in
                "(\(bind: conversationID))" as SQLQueryString
            }.joined(separator: ", ")
            let senderValues: SQLQueryString = "(\(bind: senderUserID)), (\(bind: peerUserID))"

            let rows = try await sql.raw("""
                WITH \(ident: "conversation_ids")(\(ident: "id")) AS (
                    VALUES \(conversationValues)
                ),
                \(ident: "sender_ids")(\(ident: "id")) AS (
                    VALUES \(senderValues)
                )
                SELECT DISTINCT \(ident: ConversationMessage.schema).\(ident: "sender_user_id")
                FROM \(ident: ConversationMessage.schema)
                INNER JOIN \(ident: "conversation_ids")
                    ON \(ident: ConversationMessage.schema).\(ident: "conversation_id") = \(ident: "conversation_ids").\(ident: "id")
                INNER JOIN \(ident: "sender_ids")
                    ON \(ident: ConversationMessage.schema).\(ident: "sender_user_id") = \(ident: "sender_ids").\(ident: "id")
                LIMIT 2
                """).all(decoding: SenderRow.self)
            return Set(rows.map(\.sender_user_id))
        }

        let messages = try await ConversationMessage.query(on: database)
            .filter(\.$conversation.$id ~~ conversationIDs)
            .filter(\.$sender.$id ~~ [senderUserID, peerUserID])
            .all()
        return Set(messages.map(\.$sender.id))
    }
}
