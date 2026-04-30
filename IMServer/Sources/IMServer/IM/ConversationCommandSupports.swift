import Fluent
import Vapor

struct ConversationCommandSupport {
    let db: any Database

    private var membershipMutateSupport: ConversationMembershipCommandSupport {
        ConversationMembershipCommandSupport(db: db)
    }

    private var governanceMutateSupport: ConversationGovernanceCommandSupport {
        ConversationGovernanceCommandSupport(db: db)
    }

    private var messageMutateSupport: ConversationMessageCommandSupport {
        ConversationMessageCommandSupport(db: db)
    }

    private var readStateMutateSupport: ConversationReadStateCommandSupport {
        ConversationReadStateCommandSupport(db: db)
    }

    func createConversation(
        conversationID: UUID,
        assignedShardID: String,
        kind: String?,
        title: String?,
        memberEmails: [String],
        creatorUserID: UUID
    ) async throws -> IMConversationResponse {
        try await membershipMutateSupport.createConversation(
            conversationID: conversationID,
            assignedShardID: assignedShardID,
            kind: kind,
            title: title,
            memberEmails: memberEmails,
            creatorUserID: creatorUserID
        )
    }

    func addMembers(
        in conversationID: UUID,
        memberEmails: [String],
        requesterUserID: UUID
    ) async throws -> IMConversationResponse {
        try await membershipMutateSupport.addMembers(
            in: conversationID,
            memberEmails: memberEmails,
            requesterUserID: requesterUserID
        )
    }

    func removeMember(
        in conversationID: UUID,
        memberUserID: UUID,
        requesterUserID: UUID
    ) async throws -> ConversationMemberRemovalResult {
        try await membershipMutateSupport.removeMember(
            in: conversationID,
            memberUserID: memberUserID,
            requesterUserID: requesterUserID
        )
    }

    func updateMemberRole(
        in conversationID: UUID,
        memberUserID: UUID,
        role: IMConversationMemberRole,
        requesterUserID: UUID
    ) async throws -> IMConversationResponse {
        try await membershipMutateSupport.updateMemberRole(
            in: conversationID,
            memberUserID: memberUserID,
            role: role,
            requesterUserID: requesterUserID
        )
    }

    func updateConversationTitle(
        in conversationID: UUID,
        title: String,
        requesterUserID: UUID
    ) async throws -> IMConversationResponse {
        try await governanceMutateSupport.updateConversationTitle(
            in: conversationID,
            title: title,
            requesterUserID: requesterUserID
        )
    }

    func updateConversationMetadata(
        in conversationID: UUID,
        title: String?,
        notice: String?,
        avatarPreset: IMConversationAvatarPreset?,
        requesterUserID: UUID
    ) async throws -> IMConversationResponse {
        try await governanceMutateSupport.updateConversationMetadata(
            in: conversationID,
            title: title,
            notice: notice,
            avatarPreset: avatarPreset,
            requesterUserID: requesterUserID
        )
    }

    func updateConversationPreferences(
        in conversationID: UUID,
        isPinned: Bool?,
        isMuted: Bool?,
        requesterUserID: UUID
    ) async throws -> IMConversationResponse {
        try await governanceMutateSupport.updateConversationPreferences(
            in: conversationID,
            isPinned: isPinned,
            isMuted: isMuted,
            requesterUserID: requesterUserID
        )
    }

    func markConversationRead(
        in conversationID: UUID,
        for userID: UUID,
        readSequence requestedReadSequence: Int
    ) async throws -> IMConversationReadResponse {
        try await readStateMutateSupport.markConversationRead(
            in: conversationID,
            for: userID,
            readSequence: requestedReadSequence
        )
    }

    func recallMessage(
        in conversationID: UUID,
        messageID: UUID,
        requesterUserID: UUID
    ) async throws -> IMMessageResponse {
        try await messageMutateSupport.recallMessage(
            in: conversationID,
            messageID: messageID,
            requesterUserID: requesterUserID
        )
    }

    func editMessage(
        in conversationID: UUID,
        messageID: UUID,
        text: String,
        requesterUserID: UUID
    ) async throws -> IMMessageResponse {
        try await messageMutateSupport.editMessage(
            in: conversationID,
            messageID: messageID,
            text: text,
            requesterUserID: requesterUserID
        )
    }

    func toggleReaction(
        in conversationID: UUID,
        messageID: UUID,
        emoji: String,
        requesterUserID: UUID
    ) async throws -> IMMessageResponse {
        try await messageMutateSupport.toggleReaction(
            in: conversationID,
            messageID: messageID,
            emoji: emoji,
            requesterUserID: requesterUserID
        )
    }

    func leaveConversation(
        in conversationID: UUID,
        requesterUserID: UUID
    ) async throws {
        try await membershipMutateSupport.leaveConversation(
            in: conversationID,
            requesterUserID: requesterUserID
        )
    }
}

struct ConversationReadStateCommandSupport {
    let db: any Database

    private var readAdvanceSupport: ConversationReadAdvanceSupport {
        ConversationReadAdvanceSupport(db: db)
    }

    private var refreshPublisher: ConversationSummaryRefreshPublisher {
        ConversationSummaryRefreshPublisher(db: db)
    }

    func markConversationRead(
        in conversationID: UUID,
        for userID: UUID,
        readSequence requestedReadSequence: Int
    ) async throws -> IMConversationReadResponse {
        guard requestedReadSequence >= 0 else {
            throw Abort(.badRequest, reason: "已读游标无效。")
        }

        try await readAdvanceSupport.advanceConversationRead(
            conversationID: conversationID,
            userID: userID,
            requestedReadSequence: requestedReadSequence
        )

        let readState = try await readAdvanceSupport.conversationReadState(
            conversationID: conversationID,
            userID: userID
        )
        try await refreshPublisher.publish(
            .readAdvanced,
            conversationID: conversationID,
            recipientUserIDs: [userID]
        )
        return IMConversationReadResponse(
            conversationID: conversationID,
            lastReadSequence: readState.lastReadSequence,
            unreadCount: readState.unreadCount
        )
    }
}

struct ConversationMembershipCommandSupport {
    let db: any Database

    private var userLookup: ConversationUserLookupSupport { ConversationUserLookupSupport(db: db) }
    private var membershipService: ConversationMembershipService { ConversationMembershipService(db: db) }
    private var readSupport: ConversationReadSupport { ConversationReadSupport(db: db) }
    private var summaryReadSupport: ConversationSummaryReadSupport { ConversationSummaryReadSupport(db: db) }
    private var readAdvanceSupport: ConversationReadAdvanceSupport { ConversationReadAdvanceSupport(db: db) }
    private var governanceService: ConversationGovernanceService { ConversationGovernanceService() }
    private var systemMessageAppender: ConversationSystemMessageAppender { ConversationSystemMessageAppender(db: db) }
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

            if conversationKind == .group {
                let sequence = try await ConversationSystemMessageAppender(db: database).append(
                    in: conversationID,
                    senderUserID: creatorUserID,
                    event: IMSystemEvent(
                        type: .groupCreated,
                        actorUserID: creatorUserID,
                        actorEmail: creator.email
                    )
                )
                try await ConversationReadAdvanceSupport(db: database).advanceReadSequenceIfMember(
                    conversationID: conversationID,
                    userID: creatorUserID,
                    readSequence: sequence
                )
            }

            if conversationKind == .direct {
                try await DatabaseDirectConversationIndex(db: database).registerDirectConversation(
                    conversationID: conversationID,
                    memberUserIDs: memberUserIDs,
                    shardID: assignedShardID
                )
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
        let requester = try await userLookup.requireUser(id: requesterUserID)

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

        let response = try await db.transaction { database in
            let sequence = try await ConversationSequenceAllocator(db: database)
                .allocateNextServerSequence(conversationID: conversationID, updatedAt: Date())
            for user in newUsers {
                try await ConversationMember(
                    conversationID: conversationID,
                    userID: try user.requireID(),
                    visibleFromSequence: sequence
                ).create(on: database)
            }

            _ = try await ConversationSystemMessageAppender(db: database).append(
                in: conversationID,
                senderUserID: requesterUserID,
                event: IMSystemEvent(
                    type: .membersAdded,
                    actorUserID: requesterUserID,
                    actorEmail: requester.email,
                    memberEmails: newUsers.map(\.email).sorted()
                ),
                serverSequence: sequence
            )
            try await ConversationReadAdvanceSupport(db: database).advanceReadSequenceIfMember(
                conversationID: conversationID,
                userID: requesterUserID,
                readSequence: sequence
            )

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

        let requester = try await userLookup.requireUser(id: requesterUserID)
        let targetUser = try await userLookup.requireUser(id: memberUserID)
        let removedConversation = try await readSupport.conversationSummary(
            conversationID: conversationID,
            for: memberUserID
        )

        let requesterConversation = try await db.transaction { database in
            try await targetMembership.delete(on: database)

            let sequence = try await ConversationSystemMessageAppender(db: database).append(
                in: conversationID,
                senderUserID: requesterUserID,
                event: IMSystemEvent(
                    type: .memberRemoved,
                    actorUserID: requesterUserID,
                    actorEmail: requester.email,
                    targetUserID: memberUserID,
                    targetEmail: targetUser.email
                )
            )
            try await ConversationReadAdvanceSupport(db: database).advanceReadSequenceIfMember(
                conversationID: conversationID,
                userID: requesterUserID,
                readSequence: sequence
            )

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
        let requester = try await userLookup.requireUser(id: requesterUserID)
        let targetUser = try await userLookup.requireUser(id: memberUserID)
        let previousRole = targetMembership.memberRoleEnum

        guard previousRole != role else {
            return try await readSupport.conversationSummary(
                conversationID: conversationID,
                for: requesterUserID
            )
        }

        let response = try await db.transaction { database in
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

            let sequence = try await ConversationSystemMessageAppender(db: database).append(
                in: conversationID,
                senderUserID: requesterUserID,
                event: IMSystemEvent(
                    type: role == .owner ? .ownershipTransferred : .roleUpdated,
                    actorUserID: requesterUserID,
                    actorEmail: requester.email,
                    targetUserID: memberUserID,
                    targetEmail: targetUser.email,
                    previousRole: previousRole,
                    newRole: role
                )
            )
            try await ConversationReadAdvanceSupport(db: database).advanceReadSequenceIfMember(
                conversationID: conversationID,
                userID: requesterUserID,
                readSequence: sequence
            )

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
        let requester = try await userLookup.requireUser(id: requesterUserID)
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
            try await membership.delete(on: database)
            _ = try await ConversationSystemMessageAppender(db: database).append(
                in: conversationID,
                senderUserID: requesterUserID,
                event: IMSystemEvent(
                    type: .memberLeft,
                    actorUserID: requesterUserID,
                    actorEmail: requester.email
                )
            )
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

struct ConversationGovernanceCommandSupport {
    let db: any Database

    private var userLookup: ConversationUserLookupSupport { ConversationUserLookupSupport(db: db) }
    private var membershipService: ConversationMembershipService { ConversationMembershipService(db: db) }
    private var governanceService: ConversationGovernanceService { ConversationGovernanceService() }
    private var summaryProjectionService: IMConversationSummaryProjectionService { IMConversationSummaryProjectionService(db: db) }
    private var readSupport: ConversationReadSupport { ConversationReadSupport(db: db) }
    private var summaryReadSupport: ConversationSummaryReadSupport { ConversationSummaryReadSupport(db: db) }
    private var readAdvanceSupport: ConversationReadAdvanceSupport { ConversationReadAdvanceSupport(db: db) }
    private var systemMessageAppender: ConversationSystemMessageAppender { ConversationSystemMessageAppender(db: db) }
    private var refreshPublisher: ConversationSummaryRefreshPublisher { ConversationSummaryRefreshPublisher(db: db) }

    func updateConversationTitle(
        in conversationID: UUID,
        title: String,
        requesterUserID: UUID
    ) async throws -> IMConversationResponse {
        let conversation = try await requireConversationAndMembership(
            conversationID: conversationID,
            userID: requesterUserID
        )
        try ConversationMembershipGuard.requireGroup(
            conversation,
            reason: "私聊会话不支持修改标题。"
        )
        let requesterMembership = try await requireMembershipRecord(
            conversationID: conversationID,
            userID: requesterUserID
        )
        try ConversationMembershipGuard.requireOwnerOrAdmin(
            requesterMembership.memberRoleEnum,
            reason: "只有群主或管理员可以修改群名称。"
        )

        guard let normalizedTitle = ConversationCommandNormalizationSupport.normalizedConversationTitle(title) else {
            throw Abort(.badRequest, reason: "群聊名称不能为空。")
        }
        let requester = try await userLookup.requireUser(id: requesterUserID)

        if conversation.title == normalizedTitle {
            return try await readSupport.conversationSummary(
                conversationID: conversationID,
                for: requesterUserID
            )
        }

        let response = try await db.transaction { database in
            guard let persistedConversation = try await Conversation.find(conversationID, on: database) else {
                throw Abort(.notFound, reason: "会话不存在。")
            }

            persistedConversation.title = normalizedTitle
            try await persistedConversation.update(on: database)

            let sequence = try await ConversationSystemMessageAppender(db: database).append(
                in: conversationID,
                senderUserID: requesterUserID,
                event: IMSystemEvent(
                    type: .metadataUpdated,
                    actorUserID: requesterUserID,
                    actorEmail: requester.email,
                    updatedFields: [.title],
                    title: normalizedTitle
                )
            )
            try await ConversationReadAdvanceSupport(db: database).advanceReadSequenceIfMember(
                conversationID: conversationID,
                userID: requesterUserID,
                readSequence: sequence
            )

            return try await ConversationSummaryReadSupport(db: database).conversationSummary(
                conversationID: conversationID,
                for: requesterUserID
            )
        }

        try await refreshPublisher.publish(
            .metadataUpdated,
            conversationID: conversationID,
            recipientUserIDs: response.memberUserIDs
        )
        return response
    }

    func updateConversationMetadata(
        in conversationID: UUID,
        title: String?,
        notice: String?,
        avatarPreset: IMConversationAvatarPreset?,
        requesterUserID: UUID
    ) async throws -> IMConversationResponse {
        let conversation = try await requireConversationAndMembership(
            conversationID: conversationID,
            userID: requesterUserID
        )
        try ConversationMembershipGuard.requireGroup(
            conversation,
            reason: "私聊会话不支持修改群资料。"
        )
        let requesterMembership = try await requireMembershipRecord(
            conversationID: conversationID,
            userID: requesterUserID
        )
        try ConversationMembershipGuard.requireOwnerOrAdmin(
            requesterMembership.memberRoleEnum,
            reason: "只有群主或管理员可以修改群资料。"
        )

        let changeSet = try governanceService.makeMetadataChangeSet(
            title: title,
            notice: notice,
            avatarPreset: avatarPreset
        )

        let requester = try await userLookup.requireUser(id: requesterUserID)
        let response = try await db.transaction { database in
            guard let persistedConversation = try await Conversation.find(conversationID, on: database) else {
                throw Abort(.notFound, reason: "会话不存在。")
            }

            let updatedFields = governanceService.apply(changeSet, to: persistedConversation)
            if updatedFields.isEmpty {
                return try await ConversationSummaryReadSupport(db: database).conversationSummary(
                    conversationID: conversationID,
                    for: requesterUserID
                )
            }

            try await persistedConversation.update(on: database)
            let sequence = try await ConversationSystemMessageAppender(db: database).append(
                in: conversationID,
                senderUserID: requesterUserID,
                event: IMSystemEvent(
                    type: .metadataUpdated,
                    actorUserID: requesterUserID,
                    actorEmail: requester.email,
                    updatedFields: updatedFields,
                    title: persistedConversation.title,
                    notice: persistedConversation.notice,
                    avatarPreset: persistedConversation.avatarPresetEnum
                )
            )
            try await ConversationReadAdvanceSupport(db: database).advanceReadSequenceIfMember(
                conversationID: conversationID,
                userID: requesterUserID,
                readSequence: sequence
            )

            return try await ConversationSummaryReadSupport(db: database).conversationSummary(
                conversationID: conversationID,
                for: requesterUserID
            )
        }

        try await refreshPublisher.publish(
            .metadataUpdated,
            conversationID: conversationID,
            recipientUserIDs: response.memberUserIDs
        )
        return response
    }

    func updateConversationPreferences(
        in conversationID: UUID,
        isPinned: Bool?,
        isMuted: Bool?,
        requesterUserID: UUID
    ) async throws -> IMConversationResponse {
        _ = try await requireConversationAndMembership(conversationID: conversationID, userID: requesterUserID)
        let recordID = ConversationUserSummary.recordID(ownerUserID: requesterUserID, conversationID: conversationID)

        let summary: ConversationUserSummary
        if let existingSummary = try await ConversationUserSummary.find(recordID, on: db) {
            summary = existingSummary
        } else {
            try await summaryProjectionService.refreshConversationSummaries(
                conversationID: conversationID,
                recipientUserIDs: [requesterUserID]
            )
            guard let refreshedSummary = try await ConversationUserSummary.find(recordID, on: db) else {
                throw Abort(.notFound, reason: "会话不存在。")
            }
            summary = refreshedSummary
        }

        if let isPinned {
            summary.isPinned = isPinned
            summary.pinnedAt = isPinned ? Date() : nil
        }
        if let isMuted {
            summary.isMuted = isMuted
        }
        summary.updatedAt = Date()
        try await summary.update(on: db)

        return try await readSupport.conversationSummary(
            conversationID: conversationID,
            for: requesterUserID
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

struct ConversationMessageCommandSupport {
    let db: any Database

    private var membershipService: ConversationMembershipService { ConversationMembershipService(db: db) }
    private var messageService: ConversationMessageService { ConversationMessageService(db: db) }
    private var messageEventPublisher: ConversationMessageEventPublisher { ConversationMessageEventPublisher(db: db) }

    func recallMessage(
        in conversationID: UUID,
        messageID: UUID,
        requesterUserID: UUID
    ) async throws -> IMMessageResponse {
        _ = try await requireConversationAndMembership(conversationID: conversationID, userID: requesterUserID)

        let recalledMessage = try await db.transaction { database in
            try await ConversationMessageService(db: database).recallMessage(
                in: conversationID,
                messageID: messageID,
                requesterUserID: requesterUserID,
                on: database
            )
        }

        try await messageEventPublisher.publish(
            .messageRecalled,
            conversationID: conversationID,
            requesterUserID: requesterUserID,
            messageID: try recalledMessage.requireID()
        )
        return try messageService.messageResponse(from: recalledMessage, conversationID: conversationID)
    }

    func editMessage(
        in conversationID: UUID,
        messageID: UUID,
        text: String,
        requesterUserID: UUID
    ) async throws -> IMMessageResponse {
        _ = try await requireConversationAndMembership(conversationID: conversationID, userID: requesterUserID)

        let editedMessage = try await db.transaction { database in
            try await ConversationMessageService(db: database).editMessage(
                in: conversationID,
                messageID: messageID,
                text: text,
                requesterUserID: requesterUserID,
                on: database
            )
        }

        try await messageEventPublisher.publish(
            .messageUpdated,
            conversationID: conversationID,
            requesterUserID: requesterUserID,
            messageID: try editedMessage.requireID()
        )
        return try messageService.messageResponse(from: editedMessage, conversationID: conversationID)
    }

    func toggleReaction(
        in conversationID: UUID,
        messageID: UUID,
        emoji: String,
        requesterUserID: UUID
    ) async throws -> IMMessageResponse {
        _ = try await requireConversationAndMembership(conversationID: conversationID, userID: requesterUserID)

        let updatedMessage = try await db.transaction { database in
            try await ConversationMessageService(db: database).toggleReaction(
                in: conversationID,
                messageID: messageID,
                emoji: emoji,
                requesterUserID: requesterUserID,
                on: database
            )
        }

        try await messageEventPublisher.publish(
            .messageUpdated,
            conversationID: conversationID,
            requesterUserID: requesterUserID,
            messageID: try updatedMessage.requireID()
        )

        return try messageService.messageResponse(from: updatedMessage, conversationID: conversationID)
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
