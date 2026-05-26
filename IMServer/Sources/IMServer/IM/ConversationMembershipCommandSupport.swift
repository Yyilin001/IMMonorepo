import Fluent
import Vapor

struct ConversationMembershipCommandSupport {
    let db: any Database

    private var userLookup: ConversationUserLookupSupport { ConversationUserLookupSupport(db: db) }
    private var membershipService: ConversationMembershipService { ConversationMembershipService(db: db) }
    private var readSupport: ConversationReadSupport { ConversationReadSupport(db: db) }
    private var summaryReadSupport: ConversationSummaryReadSupport { ConversationSummaryReadSupport(db: db) }
    private var governanceService: ConversationGovernanceService { ConversationGovernanceService() }
    private var refreshPublisher: ConversationSummaryRefreshPublisher { ConversationSummaryRefreshPublisher(db: db) }

    func createConversation(
        conversationID: UUID,
        assignedShardID: String,
        kind: String?,
        title: String?,
        memberEmails: [String],
        creatorUserID: UUID
    ) async throws -> IMConversationResponse {
        let normalizedTitle = ConversationCommandNormalizationSupport.normalizedConversationTitle(title)
        let normalizedEmails = Array(
            Set(memberEmails.map(User.normalize).filter { !$0.isEmpty })
        ).sorted()

        guard !normalizedEmails.isEmpty else {
            throw Abort(.badRequest, reason: "至少需要提供一个其他会话成员。")
        }

        let creator = try await userLookup.requireUser(id: creatorUserID)
        let allRequestedEmails = Array(Set(normalizedEmails + [creator.email])).sorted()
        let users = try await User.query(on: db)
            .filter(\.$email ~~ allRequestedEmails)
            .all()

        let usersByEmail = Dictionary(uniqueKeysWithValues: users.map { ($0.email, $0) })
        let missingEmails = normalizedEmails.filter { usersByEmail[$0] == nil }
        guard missingEmails.isEmpty else {
            throw Abort(.badRequest, reason: "以下成员不存在：\(missingEmails.joined(separator: "、"))。")
        }

        let memberUserIDs = try allRequestedEmails.compactMap { email in
            try usersByEmail[email]?.requireID()
        }

        let conversationKind = try ConversationCommandNormalizationSupport.normalizedConversationKind(
            kind,
            normalizedTitle: normalizedTitle,
            memberUserIDs: memberUserIDs
        )
        if conversationKind == .group {
            try IMGroupMemberLimitGuard.validateGroupMemberCount(memberUserIDs.count)
        }
        let persistedTitle = conversationKind == .direct ? nil : normalizedTitle

        let response = try await db.transaction { database in
            if conversationKind == .direct,
               let existingConversationID = try await ConversationDirectReuseSupport(db: database)
                .existingDirectConversationID(for: memberUserIDs) {
                try await ConversationDirectReuseSupport(db: database)
                    .normalizeExistingDirectConversation(conversationID: existingConversationID)
                return try await ConversationSummaryReadSupport(db: database).conversationSummary(
                    conversationID: existingConversationID,
                    for: creatorUserID
                )
            }

            let conversation = Conversation(
                id: conversationID,
                title: persistedTitle,
                kind: conversationKind,
                updatedAt: Date()
            )
            try await conversation.create(on: database)
            try await DatabaseConversationDirectory(db: database).registerConversation(
                conversationID: conversationID,
                shardID: assignedShardID
            )

            for userID in memberUserIDs {
                try await ConversationMember(
                    conversationID: conversationID,
                    userID: userID,
                    role: conversationKind == .group && userID == creatorUserID ? .owner : .member
                ).create(on: database)
            }

            if conversationKind == .direct {
                try await DatabaseDirectConversationIndex(db: database).registerDirectConversation(
                    conversationID: conversationID,
                    memberUserIDs: memberUserIDs,
                    shardID: assignedShardID
                )
                if memberUserIDs.count == 2 {
                    try await DirectConversationPairDirectoryService(db: database).upsert(
                        lhs: memberUserIDs[0],
                        rhs: memberUserIDs[1],
                        conversationID: conversationID,
                        directMessagingState: .active
                    )
                }
            }

            return try await ConversationSummaryReadSupport(db: database).conversationSummary(
                conversationID: conversationID,
                for: creatorUserID
            )
        }

        try await refreshPublisher.publish(
            .membershipAdded,
            conversationID: response.id,
            recipientUserIDs: response.memberUserIDs
        )

        return response
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
            throw Abort(.badRequest, reason: "至少需要提供一个成员邮箱。")
        }

        let conversation = try await requireConversationAndMembership(
            conversationID: conversationID,
            userID: requesterUserID
        )
        try ConversationMembershipGuard.requireGroup(
            conversation,
            reason: "私聊会话不支持新增成员。"
        )
        let requesterMembership = try await requireMembershipRecord(
            conversationID: conversationID,
            userID: requesterUserID
        )
        try ConversationMembershipGuard.requireOwnerOrAdmin(
            requesterMembership.memberRoleEnum,
            reason: "只有群主或管理员可以添加成员。"
        )
        let users = try await User.query(on: db)
            .filter(\.$email ~~ normalizedEmails)
            .all()
        let usersByEmail = Dictionary(uniqueKeysWithValues: users.map { ($0.email, $0) })
        let missingEmails = normalizedEmails.filter { usersByEmail[$0] == nil }
        guard missingEmails.isEmpty else {
            throw Abort(.badRequest, reason: "以下成员不存在：\(missingEmails.joined(separator: "、"))。")
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
            throw Abort(.badRequest, reason: "没有可新增的成员。")
        }
        try IMGroupMemberLimitGuard.validateGroupMemberCount(existingMemberships.count + newUsers.count)

        let response = try await db.transaction { database in
            let revision = Date()
            let sequence = try await ConversationSequenceAllocator(db: database)
                .allocateNextServerSequence(conversationID: conversationID, updatedAt: revision)
            if let persistedConversation = try await Conversation.find(conversationID, on: database) {
                persistedConversation.membershipRevision = revision
                try await persistedConversation.update(on: database)
            }
            for user in newUsers {
                try await ConversationMember(
                    conversationID: conversationID,
                    userID: try user.requireID(),
                    visibleFromSequence: sequence
                ).create(on: database)
            }

            return try await ConversationSummaryReadSupport(db: database).conversationSummary(
                conversationID: conversationID,
                for: requesterUserID
            )
        }

        try await refreshPublisher.publish(
            .membershipAdded,
            conversationID: conversationID,
            recipientUserIDs: response.memberUserIDs
        )

        return response
    }

    func removeMember(
        in conversationID: UUID,
        memberUserID: UUID,
        requesterUserID: UUID
    ) async throws -> ConversationMemberRemovalResult {
        let conversation = try await requireConversationAndMembership(
            conversationID: conversationID,
            userID: requesterUserID
        )
        try ConversationMembershipGuard.requireGroup(
            conversation,
            reason: "私聊会话不支持新增成员。"
        )
        try ConversationMembershipGuard.requireNotSelf(
            targetUserID: memberUserID,
            requesterUserID: requesterUserID,
            reason: "不能通过移除成员操作移除自己，请使用退出会话。"
        )

        let requesterMembership = try await requireMembershipRecord(
            conversationID: conversationID,
            userID: requesterUserID
        )
        let targetMembership = try await requireMembershipRecord(
            conversationID: conversationID,
            userID: memberUserID
        )
        try governanceService.validateMemberRemovalPrivilege(
            requesterRole: requesterMembership.memberRoleEnum,
            targetRole: targetMembership.memberRoleEnum
        )

        let memberships = try await ConversationMember.query(on: db)
            .filter(\.$conversation.$id == conversationID)
            .all()
        guard memberships.count - 1 >= 2 else {
            throw Abort(.badRequest, reason: "退出后会话成员不能少于 2 人。")
        }

        let removedConversation = try await readSupport.conversationSummary(
            conversationID: conversationID,
            for: memberUserID
        )

        let requesterConversation = try await db.transaction { database in
            let revision = Date()
            try await targetMembership.delete(on: database)

            if let persistedConversation = try await Conversation.find(conversationID, on: database) {
                persistedConversation.membershipRevision = revision
                try await persistedConversation.update(on: database)
            }

            return try await ConversationSummaryReadSupport(db: database).conversationSummary(
                conversationID: conversationID,
                for: requesterUserID
            )
        }

        let remainingUserIDs = requesterConversation.memberUserIDs
        try await refreshPublisher.publishConversationRemoved(
            conversationID: conversationID,
            affectedUserID: memberUserID
        )
        try await refreshPublisher.publish(
            .membershipRemoved,
            conversationID: conversationID,
            recipientUserIDs: remainingUserIDs
        )

        return ConversationMemberRemovalResult(
            requesterConversation: requesterConversation,
            removedConversation: removedConversation,
            remainingUserIDs: remainingUserIDs
        )
    }

    func updateMemberRole(
        in conversationID: UUID,
        memberUserID: UUID,
        role: IMConversationMemberRole,
        requesterUserID: UUID
    ) async throws -> IMConversationResponse {
        let conversation = try await requireConversationAndMembership(
            conversationID: conversationID,
            userID: requesterUserID
        )
        try ConversationMembershipGuard.requireGroup(
            conversation,
            reason: "私聊会话不支持成员角色管理。"
        )
        try ConversationMembershipGuard.requireNotSelf(
            targetUserID: memberUserID,
            requesterUserID: requesterUserID,
            reason: "不能直接修改自己的群角色。"
        )

        let requesterMembership = try await requireMembershipRecord(
            conversationID: conversationID,
            userID: requesterUserID
        )
        try ConversationMembershipGuard.requireOwner(
            requesterMembership.memberRoleEnum,
            reason: "只有群主可以调整成员角色。"
        )

        let targetMembership = try await requireMembershipRecord(
            conversationID: conversationID,
            userID: memberUserID
        )
        let previousRole = targetMembership.memberRoleEnum

        guard previousRole != role else {
            return try await readSupport.conversationSummary(
                conversationID: conversationID,
                for: requesterUserID
            )
        }

        let response = try await db.transaction { database in
            let revision = Date()
            switch role {
            case .owner:
                requesterMembership.memberRoleEnum = .admin
                targetMembership.memberRoleEnum = .owner
                try await requesterMembership.update(on: database)
                try await targetMembership.update(on: database)
            case .admin, .member:
                targetMembership.memberRoleEnum = role
                try await targetMembership.update(on: database)
            }

            if let persistedConversation = try await Conversation.find(conversationID, on: database) {
                persistedConversation.membershipRevision = revision
                try await persistedConversation.update(on: database)
            }

            return try await ConversationSummaryReadSupport(db: database).conversationSummary(
                conversationID: conversationID,
                for: requesterUserID
            )
        }

        try await refreshPublisher.publish(
            .membershipRoleUpdated,
            conversationID: conversationID,
            recipientUserIDs: response.memberUserIDs
        )
        return response
    }

    func leaveConversation(
        in conversationID: UUID,
        requesterUserID: UUID
    ) async throws {
        let conversation = try await requireConversationAndMembership(
            conversationID: conversationID,
            userID: requesterUserID
        )
        try ConversationMembershipGuard.requireGroup(
            conversation,
            reason: "私聊会话不支持主动退出。"
        )
        let requesterMembership = try await requireMembershipRecord(
            conversationID: conversationID,
            userID: requesterUserID
        )
        try ConversationMembershipGuard.requireNonOwner(
            requesterMembership.memberRoleEnum,
            reason: "群主退出前请先转让群主。"
        )

        let memberships = try await ConversationMember.query(on: db)
            .filter(\.$conversation.$id == conversationID)
            .all()
        guard memberships.count - 1 >= 2 else {
            throw Abort(.badRequest, reason: "退出后会话成员不能少于 2 人。")
        }

        guard let membership = memberships.first(where: { $0.$user.id == requesterUserID }) else {
            throw Abort(.notFound, reason: "会话不存在。")
        }

        let remainingUserIDs = memberships.map(\.$user.id).filter { $0 != requesterUserID }
        try await db.transaction { database in
            let revision = Date()
            try await membership.delete(on: database)
            if let persistedConversation = try await Conversation.find(conversationID, on: database) {
                persistedConversation.membershipRevision = revision
                try await persistedConversation.update(on: database)
            }
        }

        try await refreshPublisher.publishConversationRemoved(
            conversationID: conversationID,
            affectedUserID: requesterUserID
        )
        try await refreshPublisher.publish(
            .membershipRemoved,
            conversationID: conversationID,
            recipientUserIDs: remainingUserIDs
        )
    }

    private func requireMembershipRecord(
        conversationID: UUID,
        userID: UUID,
        on database: (any Database)? = nil
    ) async throws -> ConversationMember {
        try await membershipService.requireMembershipRecord(
            conversationID: conversationID,
            userID: userID,
            on: database
        )
    }

    private func requireConversationAndMembership(
        conversationID: UUID,
        userID: UUID
    ) async throws -> Conversation {
        try await membershipService.requireConversationAndMembership(
            conversationID: conversationID,
            userID: userID
        )
    }
}
