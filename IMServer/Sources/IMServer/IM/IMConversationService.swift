import Fluent
import Vapor

struct IMConversationService {
    private struct ConversationReadState {
        let lastReadSequence: Int
        let unreadCount: Int
    }

    private enum CreationError: LocalizedError {
        case emptyParticipants
        case invalidKind
        case invalidDirectParticipants
        case membersNotFound([String])

        var errorDescription: String? {
            switch self {
            case .emptyParticipants:
                return "至少需要提供一个其他会话成员。"
            case .invalidKind:
                return "会话类型无效。"
            case .invalidDirectParticipants:
                return "私聊只能选择 1 个其他成员。"
            case .membersNotFound(let emails):
                return "以下成员不存在：\(emails.joined(separator: "、"))。"
            }
        }
    }

    private enum MembershipUpdateError: LocalizedError {
        case emptyParticipants
        case directConversationImmutable
        case noNewMembers
        case cannotLeaveDirectConversation
        case minimumGroupSizeViolation

        var errorDescription: String? {
            switch self {
            case .emptyParticipants:
                return "至少需要提供一个成员邮箱。"
            case .directConversationImmutable:
                return "私聊会话不支持新增成员。"
            case .noNewMembers:
                return "没有可新增的成员。"
            case .cannotLeaveDirectConversation:
                return "私聊会话不支持主动退出。"
            case .minimumGroupSizeViolation:
                return "退出后会话成员不能少于 2 人。"
            }
        }
    }

    private enum HistoryPage {
        static let defaultLimit = 50
        static let maxLimit = 100
    }

    private enum IncrementalPage {
        static let defaultLimit = 100
        static let maxLimit = 500
    }

    let db: any Database

    func createConversation(
        kind: String?,
        title: String?,
        memberEmails: [String],
        creatorUserID: UUID
    ) async throws -> IMConversationResponse {
        let normalizedTitle = normalizedConversationTitle(title)
        let normalizedEmails = Array(
            Set(memberEmails.map(User.normalize).filter { !$0.isEmpty })
        ).sorted()

        guard !normalizedEmails.isEmpty else {
            throw Abort(.badRequest, reason: CreationError.emptyParticipants.localizedDescription)
        }

        let creator = try await requireUser(id: creatorUserID)
        let allRequestedEmails = Array(Set(normalizedEmails + [creator.email])).sorted()
        let users = try await User.query(on: db)
            .filter(\.$email ~~ allRequestedEmails)
            .all()

        let usersByEmail = Dictionary(uniqueKeysWithValues: users.map { ($0.email, $0) })
        let missingEmails = normalizedEmails.filter { usersByEmail[$0] == nil }
        guard missingEmails.isEmpty else {
            throw Abort(.badRequest, reason: CreationError.membersNotFound(missingEmails).localizedDescription)
        }

        let memberUserIDs = try allRequestedEmails.compactMap { email in
            try usersByEmail[email]?.requireID()
        }

        let conversationKind = try normalizedConversationKind(
            kind,
            normalizedTitle: normalizedTitle,
            memberUserIDs: memberUserIDs
        )
        let persistedTitle = conversationKind == .direct ? nil : normalizedTitle

        return try await db.transaction { database in
            if conversationKind == .direct,
               let existingConversationID = try await existingDirectConversationID(
                for: memberUserIDs,
                on: database
               ) {
                try await normalizeExistingDirectConversation(
                    conversationID: existingConversationID,
                    on: database
                )
                return try await conversationResponse(
                    conversationID: existingConversationID,
                    for: creatorUserID,
                    on: database
                )
            }

            let conversation = Conversation(
                title: persistedTitle,
                kind: conversationKind,
                updatedAt: Date()
            )
            try await conversation.create(on: database)
            let conversationID = try conversation.requireID()

            for userID in memberUserIDs {
                try await ConversationMember(
                    conversationID: conversationID,
                    userID: userID
                ).create(on: database)
            }

            return try await conversationResponse(conversationID: conversationID, for: creatorUserID, on: database)
        }
    }

    private func normalizedConversationKind(
        _ kind: String?,
        normalizedTitle: String?,
        memberUserIDs: [UUID]
    ) throws -> IMConversationKind {
        let normalizedKind = kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let requestedKind: IMConversationKind
        if let normalizedKind, !normalizedKind.isEmpty {
            guard let parsedKind = IMConversationKind(rawValue: normalizedKind) else {
                throw Abort(.badRequest, reason: CreationError.invalidKind.localizedDescription)
            }
            requestedKind = parsedKind
        } else {
            requestedKind = (normalizedTitle == nil && memberUserIDs.count == 2) ? .direct : .group
        }

        if requestedKind == .direct && memberUserIDs.count != 2 {
            throw Abort(.badRequest, reason: CreationError.invalidDirectParticipants.localizedDescription)
        }

        return requestedKind
    }

    private func existingDirectConversationID(
        for memberUserIDs: [UUID],
        on database: any Database
    ) async throws -> UUID? {
        let expectedMemberIDs = Set(memberUserIDs)
        guard expectedMemberIDs.count == 2 else {
            return nil
        }

        let sharedMemberships = try await ConversationMember.query(on: database)
            .filter(\.$user.$id ~~ Array(expectedMemberIDs))
            .all()
        let sharedConversationIDs = Dictionary(grouping: sharedMemberships, by: \.$conversation.id)
            .compactMap { conversationID, memberships -> UUID? in
                let actualMemberIDs = Set(memberships.map(\.$user.id))
                return actualMemberIDs == expectedMemberIDs ? conversationID : nil
            }

        guard !sharedConversationIDs.isEmpty else {
            return nil
        }

        let allMemberships = try await ConversationMember.query(on: database)
            .filter(\.$conversation.$id ~~ sharedConversationIDs)
            .all()
        let exactOneToOneConversationIDs = Dictionary(grouping: allMemberships, by: \.$conversation.id)
            .compactMap { conversationID, memberships -> UUID? in
                let actualMemberIDs = Set(memberships.map(\.$user.id))
                return actualMemberIDs == expectedMemberIDs ? conversationID : nil
            }

        guard !exactOneToOneConversationIDs.isEmpty else {
            return nil
        }

        let conversations = try await Conversation.query(on: database)
            .filter(\.$id ~~ exactOneToOneConversationIDs)
            .filter(\.$kind == IMConversationKind.direct.rawValue)
            .all()
        return try conversations.sorted { lhs, rhs in
            let lhsDate = lhs.createdAt ?? .distantPast
            let rhsDate = rhs.createdAt ?? .distantPast
            if lhsDate == rhsDate {
                let lhsID = (try? lhs.requireID().uuidString) ?? ""
                let rhsID = (try? rhs.requireID().uuidString) ?? ""
                return lhsID < rhsID
            }
            return lhsDate < rhsDate
        }.first?.requireID()
    }

    private func normalizeExistingDirectConversation(
        conversationID: UUID,
        on database: any Database
    ) async throws {
        guard let conversation = try await Conversation.find(conversationID, on: database) else {
            return
        }

        var shouldUpdate = false
        if conversation.title != nil {
            conversation.title = nil
            shouldUpdate = true
        }

        if shouldUpdate {
            conversation.updatedAt = Date()
            try await conversation.update(on: database)
        }
    }

    func addMembers(
        in conversationID: UUID,
        memberEmails: [String],
        requesterUserID: UUID
    ) async throws -> IMConversationResponse {
        let normalizedEmails = Array(
            Set(memberEmails.map(User.normalize).filter { !$0.isEmpty })
        ).sorted()
        guard !normalizedEmails.isEmpty else {
            throw Abort(.badRequest, reason: MembershipUpdateError.emptyParticipants.localizedDescription)
        }

        let conversation = try await requireConversationAndMembership(
            conversationID: conversationID,
            userID: requesterUserID
        )
        guard conversation.conversationKind == .group else {
            throw Abort(.badRequest, reason: MembershipUpdateError.directConversationImmutable.localizedDescription)
        }

        let users = try await User.query(on: db)
            .filter(\.$email ~~ normalizedEmails)
            .all()
        let usersByEmail = Dictionary(uniqueKeysWithValues: users.map { ($0.email, $0) })
        let missingEmails = normalizedEmails.filter { usersByEmail[$0] == nil }
        guard missingEmails.isEmpty else {
            throw Abort(.badRequest, reason: CreationError.membersNotFound(missingEmails).localizedDescription)
        }

        let existingMemberships = try await ConversationMember.query(on: db)
            .filter(\.$conversation.$id == conversationID)
            .all()
        let existingUserIDs = Set(existingMemberships.map(\.$user.id))
        let newUsers = try users.filter { user in
            let userID = try user.requireID()
            return !existingUserIDs.contains(userID)
        }
        guard !newUsers.isEmpty else {
            throw Abort(.badRequest, reason: MembershipUpdateError.noNewMembers.localizedDescription)
        }

        return try await db.transaction { database in
            for user in newUsers {
                try await ConversationMember(
                    conversationID: conversationID,
                    userID: try user.requireID()
                ).create(on: database)
            }
            return try await conversationResponse(
                conversationID: conversationID,
                for: requesterUserID,
                on: database
            )
        }
    }

    func leaveConversation(
        in conversationID: UUID,
        requesterUserID: UUID
    ) async throws {
        let conversation = try await requireConversationAndMembership(
            conversationID: conversationID,
            userID: requesterUserID
        )
        guard conversation.conversationKind == .group else {
            throw Abort(.badRequest, reason: MembershipUpdateError.cannotLeaveDirectConversation.localizedDescription)
        }

        let memberships = try await ConversationMember.query(on: db)
            .filter(\.$conversation.$id == conversationID)
            .all()
        guard memberships.count - 1 >= 2 else {
            throw Abort(.badRequest, reason: MembershipUpdateError.minimumGroupSizeViolation.localizedDescription)
        }

        guard let membership = memberships.first(where: { $0.$user.id == requesterUserID }) else {
            throw Abort(.notFound, reason: "会话不存在。")
        }

        try await db.transaction { database in
            try await membership.delete(on: database)
        }
    }

    func listConversations(for userID: UUID) async throws -> [IMConversationResponse] {
        let memberships = try await ConversationMember.query(on: db)
            .filter(\.$user.$id == userID)
            .all()
        let conversationIDs = memberships.map(\.$conversation.id)

        guard !conversationIDs.isEmpty else {
            return []
        }

        let conversations = try await Conversation.query(on: db)
            .filter(\.$id ~~ conversationIDs)
            .all()
        let allMembers = try await ConversationMember.query(on: db)
            .filter(\.$conversation.$id ~~ conversationIDs)
            .all()
        let allMessages = try await ConversationMessage.query(on: db)
            .filter(\.$conversation.$id ~~ conversationIDs)
            .sort(\.$serverSequence, .descending)
            .all()

        let memberUserIDsByConversation = Dictionary(grouping: allMembers, by: \.$conversation.id)
            .mapValues { members in
                members.map(\.$user.id).sorted { $0.uuidString < $1.uuidString }
            }
        let lastReadSequenceByConversation = Dictionary(
            uniqueKeysWithValues: memberships.map { ($0.$conversation.id, $0.lastReadSequence) }
        )

        var lastMessageByConversation: [UUID: IMMessagePreviewResponse] = [:]
        for message in allMessages {
            let conversationID = message.$conversation.id
            guard lastMessageByConversation[conversationID] == nil else {
                continue
            }
            lastMessageByConversation[conversationID] = try makePreview(from: message)
        }

        let responses = try conversations.map { conversation in
            let conversationID = try conversation.requireID()
            let lastMessage = lastMessageByConversation[conversationID]
            let updatedAt = lastMessage?.createdAt ?? conversation.updatedAt
            let latestSequence = max(conversation.lastMessageSequence, lastMessage?.serverSequence ?? 0)
            let unreadCount = max(0, latestSequence - (lastReadSequenceByConversation[conversationID] ?? 0))

            return IMConversationResponse(
                id: conversationID,
                title: conversation.title,
                kind: conversation.kind,
                memberCount: memberUserIDsByConversation[conversationID]?.count ?? 0,
                memberUserIDs: memberUserIDsByConversation[conversationID] ?? [],
                lastMessage: lastMessage,
                lastReadSequence: lastReadSequenceByConversation[conversationID] ?? 0,
                unreadCount: unreadCount,
                createdAt: conversation.createdAt,
                updatedAt: updatedAt
            )
        }

        return responses.sorted { left, right in
            if left.updatedAt == right.updatedAt {
                return left.id.uuidString < right.id.uuidString
            }
            return left.updatedAt > right.updatedAt
        }
    }

    func listMembers(in conversationID: UUID, for userID: UUID) async throws -> [UserResponse] {
        try await requireMembership(conversationID: conversationID, userID: userID)

        let memberships = try await ConversationMember.query(on: db)
            .filter(\.$conversation.$id == conversationID)
            .with(\.$user)
            .all()

        return try memberships
            .map(\.$user.value)
            .map { user -> UserResponse in
                guard let user else {
                    throw Abort(.internalServerError, reason: "会话成员数据不完整。")
                }
                return try user.asResponse()
            }
            .sorted { $0.email < $1.email }
    }

    func listMessages(
        in conversationID: UUID,
        for userID: UUID,
        beforeSequence: Int? = nil,
        limit requestedLimit: Int? = nil
    ) async throws -> [IMMessageResponse] {
        try await requireMembership(conversationID: conversationID, userID: userID)
        let limit = try normalizedHistoryLimit(requestedLimit)

        let builder = ConversationMessage.query(on: db)
            .filter(\.$conversation.$id == conversationID)
        if let beforeSequence {
            guard beforeSequence > 0 else {
                throw Abort(.badRequest, reason: "分页游标无效。")
            }
            builder.filter(\.$serverSequence < beforeSequence)
        }

        let messages = try await builder
            .sort(\.$serverSequence, .descending)
            .limit(limit)
            .all()
            .reversed()

        return try messages.map { try messageResponse(from: $0, conversationID: conversationID) }
    }

    func listMessagesSince(
        in conversationID: UUID,
        for userID: UUID,
        afterSequence: Int,
        limit requestedLimit: Int? = nil
    ) async throws -> IMMessageSinceResponse {
        try await requireMembership(conversationID: conversationID, userID: userID)

        guard afterSequence >= 0 else {
            throw Abort(.badRequest, reason: "增量游标无效。")
        }

        let limit = try normalizedIncrementalLimit(requestedLimit)
        var rows = try await ConversationMessage.query(on: db)
            .filter(\.$conversation.$id == conversationID)
            .filter(\.$serverSequence > afterSequence)
            .sort(\.$serverSequence, .ascending)
            .limit(limit + 1)
            .all()
        let hasMore = rows.count > limit
        if hasMore {
            rows.removeLast()
        }

        let messages = try rows.map { try messageResponse(from: $0, conversationID: conversationID) }
        return IMMessageSinceResponse(
            messages: messages,
            hasMore: hasMore,
            nextAfterSequence: messages.last?.serverSequence
        )
    }

    func markConversationRead(
        in conversationID: UUID,
        for userID: UUID,
        readSequence requestedReadSequence: Int
    ) async throws -> IMConversationReadResponse {
        guard requestedReadSequence >= 0 else {
            throw Abort(.badRequest, reason: "已读游标无效。")
        }

        try await advanceConversationRead(
            conversationID: conversationID,
            userID: userID,
            requestedReadSequence: requestedReadSequence,
            on: db
        )

        let readState = try await conversationReadState(
            conversationID: conversationID,
            userID: userID,
            on: db
        )
        return IMConversationReadResponse(
            conversationID: conversationID,
            lastReadSequence: readState.lastReadSequence,
            unreadCount: readState.unreadCount
        )
    }

    func conversationSummary(
        conversationID: UUID,
        for userID: UUID
    ) async throws -> IMConversationResponse {
        try await conversationResponse(
            conversationID: conversationID,
            for: userID,
            on: db
        )
    }

    private func requireMembership(conversationID: UUID, userID: UUID) async throws {
        _ = try await requireConversationAndMembership(conversationID: conversationID, userID: userID)
    }

    private func requireConversationAndMembership(
        conversationID: UUID,
        userID: UUID
    ) async throws -> Conversation {
        guard let conversation = try await Conversation.find(conversationID, on: db) else {
            throw Abort(.notFound, reason: "会话不存在。")
        }

        let membership = try await ConversationMember.query(on: db)
            .filter(\.$conversation.$id == conversationID)
            .filter(\.$user.$id == userID)
            .first()

        guard membership != nil else {
            throw Abort(.notFound, reason: "会话不存在。")
        }

        return conversation
    }

    private func advanceConversationRead(
        conversationID: UUID,
        userID: UUID,
        requestedReadSequence: Int,
        on database: any Database
    ) async throws {
        guard let membership = try await ConversationMember.query(on: database)
            .filter(\.$conversation.$id == conversationID)
            .filter(\.$user.$id == userID)
            .first()
        else {
            throw Abort(.notFound, reason: "会话不存在。")
        }

        let targetSequence = try await latestConversationSequence(
            conversationID: conversationID,
            on: database
        )
        let effectiveReadSequence = min(requestedReadSequence, targetSequence)
        guard membership.lastReadSequence < effectiveReadSequence else {
            return
        }

        membership.lastReadSequence = effectiveReadSequence
        try await membership.update(on: database)
    }

    private func requireUser(id userID: UUID) async throws -> User {
        guard let user = try await User.find(userID, on: db) else {
            throw Abort(.notFound, reason: "用户不存在。")
        }
        return user
    }

    private func conversationResponse(
        conversationID: UUID,
        for userID: UUID,
        on database: any Database
    ) async throws -> IMConversationResponse {
        guard let conversation = try await Conversation.find(conversationID, on: database) else {
            throw Abort(.notFound, reason: "会话不存在。")
        }

        let memberships = try await ConversationMember.query(on: database)
            .filter(\.$conversation.$id == conversationID)
            .all()
        let memberUserIDs = memberships.map(\.$user.id).sorted { $0.uuidString < $1.uuidString }
        guard memberUserIDs.contains(userID) else {
            throw Abort(.notFound, reason: "会话不存在。")
        }

        let lastMessage = try await ConversationMessage.query(on: database)
            .filter(\.$conversation.$id == conversationID)
            .sort(\.$serverSequence, .descending)
            .first()
            .map(makePreview)
        let readState = try await conversationReadState(
            conversationID: conversationID,
            userID: userID,
            on: database
        )

        return IMConversationResponse(
            id: conversationID,
            title: conversation.title,
            kind: conversation.kind,
            memberCount: memberUserIDs.count,
            memberUserIDs: memberUserIDs,
            lastMessage: lastMessage,
            lastReadSequence: readState.lastReadSequence,
            unreadCount: readState.unreadCount,
            createdAt: conversation.createdAt,
            updatedAt: lastMessage?.createdAt ?? conversation.updatedAt
        )
    }

    private func conversationReadState(
        conversationID: UUID,
        userID: UUID,
        on database: any Database
    ) async throws -> ConversationReadState {
        guard let membership = try await ConversationMember.query(on: database)
            .filter(\.$conversation.$id == conversationID)
            .filter(\.$user.$id == userID)
            .first()
        else {
            throw Abort(.notFound, reason: "会话不存在。")
        }

        let latestSequence = try await latestConversationSequence(
            conversationID: conversationID,
            on: database
        )
        return ConversationReadState(
            lastReadSequence: membership.lastReadSequence,
            unreadCount: max(0, latestSequence - membership.lastReadSequence)
        )
    }

    private func latestConversationSequence(
        conversationID: UUID,
        on database: any Database
    ) async throws -> Int {
        let conversation = try await Conversation.find(conversationID, on: database)
        let latestMessageSequence = try await ConversationMessage.query(on: database)
            .filter(\.$conversation.$id == conversationID)
            .sort(\.$serverSequence, .descending)
            .first()?
            .serverSequence ?? 0

        return max(conversation?.lastMessageSequence ?? 0, latestMessageSequence)
    }

    private func makePreview(from message: ConversationMessage) throws -> IMMessagePreviewResponse {
        IMMessagePreviewResponse(
            id: try message.requireID(),
            senderUserID: message.$sender.id,
            serverSequence: message.serverSequence,
            kind: message.kind,
            body: try message.decodedBody(),
            createdAt: message.createdAt
        )
    }

    private func messageResponse(
        from message: ConversationMessage,
        conversationID: UUID
    ) throws -> IMMessageResponse {
        IMMessageResponse(
            id: try message.requireID(),
            conversationID: conversationID,
            senderUserID: message.$sender.id,
            clientMessageID: message.clientMessageID,
            serverSequence: message.serverSequence,
            kind: message.kind,
            body: try message.decodedBody(),
            createdAt: message.createdAt
        )
    }

    private func normalizedHistoryLimit(_ requestedLimit: Int?) throws -> Int {
        guard let requestedLimit else {
            return HistoryPage.defaultLimit
        }

        guard requestedLimit > 0 else {
            throw Abort(.badRequest, reason: "分页条数无效。")
        }

        return min(requestedLimit, HistoryPage.maxLimit)
    }

    private func normalizedIncrementalLimit(_ requestedLimit: Int?) throws -> Int {
        guard let requestedLimit else {
            return IncrementalPage.defaultLimit
        }

        guard requestedLimit > 0 else {
            throw Abort(.badRequest, reason: "分页条数无效。")
        }

        return min(requestedLimit, IncrementalPage.maxLimit)
    }

    private func normalizedConversationTitle(_ title: String?) -> String? {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedTitle.isEmpty ? nil : trimmedTitle
    }
}
