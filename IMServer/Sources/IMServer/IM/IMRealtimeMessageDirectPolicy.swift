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
        let userDirectoryDatabase = userDirectoryDatabase(fallingBackTo: database)
        if let sql = userDirectoryDatabase as? any SQLDatabase {
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

        return try await UserContact.query(on: userDirectoryDatabase)
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
        on database: any Database
    ) async throws -> [UUID] {
        if let app,
           let cached = await app.directConversationPairCache.conversationIDs(lhs: lhs, rhs: rhs) {
            return cached
        }

        // This is a global pair directory. The conversation rows themselves
        // remain sharded and are resolved separately when messages are read.
        let directConversationIDs = try await DirectConversationPairDirectoryService(
            db: userDirectoryDatabase(fallingBackTo: database)
        )
            .conversationIDsBetween(lhs, rhs)
        if let app {
            await app.directConversationPairCache.store(directConversationIDs, lhs: lhs, rhs: rhs)
        }
        return directConversationIDs
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
