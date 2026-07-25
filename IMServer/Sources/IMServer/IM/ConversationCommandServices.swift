import Fluent
import Vapor

struct ConversationCommandService {
    private let app: Application?
    private let fixedDatabase: (any Database)?

    init(app: Application) {
        self.app = app
        self.fixedDatabase = nil
    }

    init(fixedDatabaseForLowLevelTest db: any Database) {
        self.app = nil
        self.fixedDatabase = db
    }

    func createConversation(
        kind: String?,
        title: String?,
        memberEmails: [String],
        creatorUserID: UUID
    ) async throws -> ConversationCreateCommandResult {
        if let app {
            try await rejectBlockedDirectConversationIfNeeded(
                kind: kind,
                title: title,
                memberEmails: memberEmails,
                creatorUserID: creatorUserID,
                on: app.db
            )
        }
        let directMemberUserIDs: [UUID]? = if let app {
            try await directConversationMemberUserIDs(
                app: app,
                kind: kind,
                title: title,
                memberEmails: memberEmails,
                creatorUserID: creatorUserID
            )
        } else {
            nil
        }
        if let app,
           let directMemberUserIDs,
           let existingConversationID = try await app.directConversationIndex
            .conversationID(forMemberUserIDs: directMemberUserIDs) {
            return try await existingDirectConversationResult(
                app: app,
                conversationID: existingConversationID,
                memberUserIDs: directMemberUserIDs
            )
        }

        let conversationID = UUID()
        let assignedShardID = app?.conversationShardRouter.shardID(forNewConversationID: conversationID)
            ?? SingleShardConversationShardRouter.defaultShardID
        var reservedDirectConversation = false
        if let app, let directMemberUserIDs {
            switch try await app.directConversationIndex.reserveDirectConversation(
                conversationID: conversationID,
                memberUserIDs: directMemberUserIDs,
                shardID: assignedShardID
            ) {
            case .reserved:
                reservedDirectConversation = true
            case let .existing(existingConversationID):
                return try await existingDirectConversationResult(
                    app: app,
                    conversationID: existingConversationID,
                    memberUserIDs: directMemberUserIDs
                )
            }
        }
        let result: ConversationCreateCommandResult
        do {
            if let app {
                try await app.conversationDirectory.reserveConversation(
                    conversationID: conversationID,
                    shardID: assignedShardID,
                    cellID: app.imRealtimeCellID
                )
            }
            let commandDB = try commandDatabase(forShardID: assignedShardID)
            result = try await commandSupport(for: commandDB).createConversation(
                conversationID: conversationID,
                assignedShardID: assignedShardID,
                kind: kind,
                title: title,
                memberEmails: memberEmails,
                creatorUserID: creatorUserID
            )
        } catch {
            if let app, reservedDirectConversation, let directMemberUserIDs {
                try? await app.directConversationIndex.releaseDirectConversationReservation(
                    conversationID: conversationID,
                    memberUserIDs: directMemberUserIDs
                )
            }
            throw error
        }
        if let app, result.receipt.didMutate {
            // The matching membership event activates a pending route during
            // outbox replay if this immediate activation is interrupted.
            do {
                try await app.conversationDirectory.activateConversation(
                    conversationID: result.receipt.conversationID
                )
            } catch {
                app.logger.warning(
                    "Conversation route activation deferred to outbox recovery",
                    metadata: [
                        "conversation_id": .string(result.receipt.conversationID.uuidString),
                        "shard_id": .string(assignedShardID),
                        "error": .string(String(describing: error))
                    ]
                )
            }
            if result.kind == .direct {
                let memberUserIDs = result.memberUserIDs
                try await app.directConversationIndex.registerDirectConversation(
                    conversationID: result.receipt.conversationID,
                    memberUserIDs: memberUserIDs,
                    shardID: assignedShardID
                )
                if memberUserIDs.count == 2 {
                    try await DirectConversationPairDirectoryService(db: app.db).upsert(
                        lhs: memberUserIDs[0],
                        rhs: memberUserIDs[1],
                        conversationID: result.receipt.conversationID,
                        directMessagingState: .active
                    )
                }
            }
        }
        return result
    }

    private func rejectBlockedDirectConversationIfNeeded(
        kind: String?,
        title: String?,
        memberEmails: [String],
        creatorUserID: UUID,
        on db: any Database
    ) async throws {
        let normalizedEmails = Array(Set(memberEmails.map(User.normalize).filter { !$0.isEmpty }))
        guard normalizedEmails.count == 1 else {
            return
        }
        let creator = try await ConversationUserLookupSupport(db: db).requireUser(id: creatorUserID)
        let normalizedTitle = ConversationCommandNormalizationSupport.normalizedConversationTitle(title)
        let peer = try await User.query(on: db)
            .filter(\.$email == normalizedEmails[0])
            .first()
        guard let peer else {
            return
        }
        let memberUserIDs = [creatorUserID, try peer.requireID()].sorted { $0.uuidString < $1.uuidString }
        let conversationKind = try ConversationCommandNormalizationSupport.normalizedConversationKind(
            kind,
            normalizedTitle: normalizedTitle,
            memberUserIDs: memberUserIDs
        )
        guard conversationKind == .direct else {
            return
        }
        let lhs = try creator.requireID()
        let rhs = try peer.requireID()
        let lhsBlocked = try await UserBlock.find(UserBlock.recordID(ownerUserID: lhs, blockedUserID: rhs), on: db) != nil
        let rhsBlocked = try await UserBlock.find(UserBlock.recordID(ownerUserID: rhs, blockedUserID: lhs), on: db) != nil
        if lhsBlocked || rhsBlocked {
            throw Abort(.forbidden, reason: "当前无法创建私聊。")
        }
    }

    private func directConversationMemberUserIDs(
        app: Application,
        kind: String?,
        title: String?,
        memberEmails: [String],
        creatorUserID: UUID
    ) async throws -> [UUID]? {
        let normalizedTitle = ConversationCommandNormalizationSupport.normalizedConversationTitle(title)
        let normalizedEmails = Array(
            Set(memberEmails.map(User.normalize).filter { !$0.isEmpty })
        ).sorted()
        guard !normalizedEmails.isEmpty else {
            return nil
        }

        let creator = try await ConversationUserLookupSupport(db: app.db).requireUser(id: creatorUserID)
        let allRequestedEmails = Array(Set(normalizedEmails + [creator.email])).sorted()
        let users = try await User.query(on: app.db)
            .filter(\.$email ~~ allRequestedEmails)
            .all()
        let usersByEmail = Dictionary(uniqueKeysWithValues: users.map { ($0.email, $0) })
        let memberUserIDs = try allRequestedEmails.compactMap { email in
            try usersByEmail[email]?.requireID()
        }
        let conversationKind = try ConversationCommandNormalizationSupport.normalizedConversationKind(
            kind,
            normalizedTitle: normalizedTitle,
            memberUserIDs: memberUserIDs
        )
        guard conversationKind == .direct else {
            return nil
        }
        return memberUserIDs
    }

    private func directConversationResult(
        conversationID: UUID,
        memberUserIDs: [UUID]
    ) -> ConversationCreateCommandResult {
        return ConversationCreateCommandResult(
            receipt: ConversationCommandReceipt(
                conversationID: conversationID,
                eventID: nil,
                eventType: .membershipAdded,
                acceptedAt: Date(),
                membershipRevision: nil,
                didMutate: false
            ),
            kind: .direct,
            memberUserIDs: memberUserIDs
        )
    }

    private func existingDirectConversationResult(
        app: Application,
        conversationID: UUID,
        memberUserIDs: [UUID]
    ) async throws -> ConversationCreateCommandResult {
        do {
            _ = try await app.conversationDirectory.route(for: conversationID)
        } catch let error as Abort where error.status == .notFound {
            // Older single-shard deployments may have a direct-pair index but
            // no directory row. Keep that compatible only after confirming
            // the canonical conversation exists. A missing row otherwise
            // means another request is still holding the direct-pair reserve.
            let shardID = try await app.directConversationIndex.shardID(
                forMemberUserIDs: memberUserIDs
            )
            let database = app.conversationShardRouter.strongReadDatabase(forShardID: shardID)
            guard try await Conversation.find(conversationID, on: database) != nil else {
                throw Abort(
                    .serviceUnavailable,
                    reason: "Direct conversation creation is in progress. Retry the request."
                )
            }
        }

        return directConversationResult(
            conversationID: conversationID,
            memberUserIDs: memberUserIDs
        )
    }

    func addMembers(
        in conversationID: UUID,
        memberEmails: [String],
        requesterUserID: UUID
    ) async throws -> ConversationCommandReceipt {
        try await commandSupport(for: commandDatabase(forConversationID: conversationID)).addMembers(
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
        try await commandSupport(for: commandDatabase(forConversationID: conversationID)).removeMember(
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
    ) async throws -> ConversationCommandReceipt {
        try await commandSupport(for: commandDatabase(forConversationID: conversationID)).updateMemberRole(
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
    ) async throws -> ConversationCommandReceipt {
        try await commandSupport(for: commandDatabase(forConversationID: conversationID)).updateConversationTitle(
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
        muteAll: Bool?,
        requesterUserID: UUID
    ) async throws -> ConversationCommandReceipt {
        try await commandSupport(for: commandDatabase(forConversationID: conversationID)).updateConversationMetadata(
            in: conversationID,
            title: title,
            notice: notice,
            avatarPreset: avatarPreset,
            muteAll: muteAll,
            requesterUserID: requesterUserID
        )
    }

    func updateMemberNickname(
        in conversationID: UUID,
        requesterUserID: UUID,
        memberNickname: String?
    ) async throws -> ConversationCommandReceipt {
        try await commandSupport(for: commandDatabase(forConversationID: conversationID)).updateMemberNickname(
            in: conversationID,
            requesterUserID: requesterUserID,
            memberNickname: memberNickname
        )
    }

    func updateConversationPreferences(
        in conversationID: UUID,
        isPinned: Bool?,
        isMuted: Bool?,
        requesterUserID: UUID
    ) async throws -> ConversationCommandReceipt {
        try await commandSupport(for: commandDatabase(forConversationID: conversationID)).updateConversationPreferences(
            in: conversationID,
            isPinned: isPinned,
            isMuted: isMuted,
            requesterUserID: requesterUserID
        )
    }

    func markConversationRead(
        in conversationID: UUID,
        for userID: UUID,
        readSequence: Int
    ) async throws -> IMConversationReadResponse {
        try await commandSupport(for: commandDatabase(forConversationID: conversationID)).markConversationRead(
            in: conversationID,
            for: userID,
            readSequence: readSequence
        )
    }

    func recallMessage(
        in conversationID: UUID,
        messageID: UUID,
        requesterUserID: UUID
    ) async throws -> IMMessageResponse {
        try await commandSupport(for: commandDatabase(forConversationID: conversationID)).recallMessage(
            in: conversationID,
            messageID: messageID,
            requesterUserID: requesterUserID
        )
    }

    func editMessage(
        in conversationID: UUID,
        messageID: UUID,
        body: IMRichTextContent,
        requesterUserID: UUID
    ) async throws -> IMMessageResponse {
        try await commandSupport(for: commandDatabase(forConversationID: conversationID)).editMessage(
            in: conversationID,
            messageID: messageID,
            body: body,
            requesterUserID: requesterUserID
        )
    }

    func toggleReaction(
        in conversationID: UUID,
        messageID: UUID,
        emoji: String,
        requesterUserID: UUID
    ) async throws -> IMMessageResponse {
        try await commandSupport(for: commandDatabase(forConversationID: conversationID)).toggleReaction(
            in: conversationID,
            messageID: messageID,
            emoji: emoji,
            requesterUserID: requesterUserID
        )
    }

    func leaveConversation(
        in conversationID: UUID,
        requesterUserID: UUID
    ) async throws -> ConversationCommandReceipt {
        try await commandSupport(for: commandDatabase(forConversationID: conversationID)).leaveConversation(
            in: conversationID,
            requesterUserID: requesterUserID
        )
    }

    private func commandDatabase(forShardID shardID: String) throws -> any Database {
        if let fixedDatabase {
            return fixedDatabase
        }
        guard let app else {
            throw Abort(.internalServerError, reason: "ConversationCommandService missing both app and database.")
        }
        return app.conversationShardRouter.commandDatabase(forShardID: shardID)
    }

    private func commandSupport(for db: any Database) -> ConversationCommandSupport {
        ConversationCommandSupport(
            db: db,
            userDirectoryDB: app?.db,
            // Application mode registers all primary-directory records after the
            // conversation-shard transaction commits.
            usesLocalConversationDirectoryTables: app == nil
        )
    }

    private func commandDatabase(forConversationID conversationID: UUID) async throws -> any Database {
        if let fixedDatabase {
            return fixedDatabase
        }
        guard let app else {
            throw Abort(.internalServerError, reason: "ConversationCommandService missing both app and database.")
        }
        return try await app.conversationShardRouter.commandDatabase(forConversationID: conversationID)
    }
}

struct ConversationStrongReadService {
    private let app: Application?
    private let fixedDatabase: (any Database)?

    init(app: Application) {
        self.app = app
        self.fixedDatabase = nil
    }

    init(fixedDatabaseForLowLevelTest db: any Database) {
        self.app = nil
        self.fixedDatabase = db
    }

    func latestMessage(in conversationID: UUID) async throws -> IMMessageResponse? {
        try await timelineReadSupport(for: conversationID)
            .latestMessage(in: conversationID)
    }

    func listTimelineSince(
        in conversationID: UUID,
        for userID: UUID,
        afterSequence: Int,
        targetSequence: Int? = nil,
        limit: Int?,
        useSharedCache: Bool = true
    ) async throws -> IMTimelinePageResponse {
        try await timelineReadSupport(for: conversationID)
            .listTimelineSince(
                in: conversationID,
                for: userID,
                afterSequence: afterSequence,
                targetSequence: targetSequence,
                limit: limit,
                useSharedCache: useSharedCache
            )
    }

    func conversationSummary(
        conversationID: UUID,
        for userID: UUID
    ) async throws -> IMConversationResponse {
        try await ConversationSummaryReadSupport(
            db: database(forConversationID: conversationID),
            userDirectoryDB: app?.db
        )
            .conversationSummary(conversationID: conversationID, for: userID)
    }

    private func database(forConversationID conversationID: UUID) async throws -> any Database {
        if let fixedDatabase {
            return fixedDatabase
        }
        guard let app else {
            throw Abort(.internalServerError, reason: "ConversationStrongReadService missing both app and database.")
        }
        return try await app.conversationShardRouter.strongReadDatabase(forConversationID: conversationID)
    }

    private func timelineReadSupport(for conversationID: UUID) async throws -> ConversationTimelineReadSupport {
        let db = try await database(forConversationID: conversationID)
        guard let app else {
            return ConversationTimelineReadSupport(db: db)
        }
        return ConversationTimelineReadSupport(
            db: db,
            featureDB: app.db,
            metrics: app.timelineReadMetrics,
            configuration: app.timelineReadConfiguration,
            sinceHotCache: app.timelineSinceHotCache,
            sinceRecentCache: app.timelineSinceRecentCache,
            sinceVisibilitySafetyCache: app.timelineSinceVisibilitySafetyCache,
            sinceResponseCoalescer: app.timelineSinceResponseCoalescer
        )
    }
}

struct ConversationEventualReadService {
    private let app: Application?
    private let fixedDatabase: (any Database)?

    init(app: Application) {
        self.app = app
        self.fixedDatabase = nil
    }

    init(fixedDatabaseForLowLevelTest db: any Database) {
        self.app = nil
        self.fixedDatabase = db
    }

    func listConversations(
        for userID: UUID,
        cursor: String?,
        limit: Int?,
        kind: String? = nil
    ) async throws -> IMConversationPageResponse {
        try await ConversationSummaryReadSupport(db: try listDatabase())
            .listConversations(for: userID, cursor: cursor, limit: limit, kind: kind)
    }

    func conversationSummary(
        conversationID: UUID,
        for userID: UUID
    ) async throws -> IMConversationResponse {
        try await ConversationSummaryReadSupport(db: try listDatabase())
            .conversationSummary(conversationID: conversationID, for: userID)
    }

    func listConversationChanges(
        for userID: UUID,
        afterToken: String,
        cursor: String?,
        limit: Int?
    ) async throws -> IMConversationChangesResponse {
        try await ConversationSummaryReadSupport(db: try listDatabase())
            .listConversationChanges(for: userID, afterToken: afterToken, cursor: cursor, limit: limit)
    }

    func listMembers(in conversationID: UUID, for userID: UUID) async throws -> [IMConversationMemberResponse] {
        try await ConversationMembershipService(
            db: database(forConversationID: conversationID),
            userDirectoryDB: app?.db
        )
            .listMemberResponses(in: conversationID, for: userID)
    }

    func listMemberPage(
        in conversationID: UUID,
        for userID: UUID,
        cursor: String?,
        limit: Int?,
        query: String?
    ) async throws -> IMConversationMemberPageResponse {
        try await ConversationMembershipService(
            db: database(forConversationID: conversationID),
            userDirectoryDB: app?.db
        )
            .listMemberPageResponses(
                in: conversationID,
                for: userID,
                cursor: cursor,
                limit: limit,
                query: query
            )
    }

    func listTimeline(
        in conversationID: UUID,
        for userID: UUID,
        beforeSequence: Int?,
        limit: Int?
    ) async throws -> IMTimelinePageResponse {
        try await timelineReadSupport(for: conversationID)
            .listTimeline(in: conversationID, for: userID, beforeSequence: beforeSequence, limit: limit)
    }

    func listTimelineSince(
        in conversationID: UUID,
        for userID: UUID,
        afterSequence: Int,
        targetSequence: Int? = nil,
        limit: Int?,
        useSharedCache: Bool = true
    ) async throws -> IMTimelinePageResponse {
        try await timelineReadSupport(for: conversationID)
            .listTimelineSince(
                in: conversationID,
                for: userID,
                afterSequence: afterSequence,
                targetSequence: targetSequence,
                limit: limit,
                useSharedCache: useSharedCache
            )
    }

    func searchMessages(
        in conversationID: UUID,
        for userID: UUID,
        query: String,
        cursor: String?,
        limit: Int?
    ) async throws -> IMConversationMessageSearchPageResponse {
        try await ConversationSearchReadSupport(
            db: database(forConversationID: conversationID),
            featureDB: app?.db
        )
            .searchMessages(in: conversationID, for: userID, query: query, cursor: cursor, limit: limit)
    }

    private func listDatabase() throws -> any Database {
        if let fixedDatabase {
            return fixedDatabase
        }
        guard let app else {
            throw Abort(.internalServerError, reason: "ConversationEventualReadService missing both app and database.")
        }
        return app.conversationShardRouter.eventualReadDatabase()
    }

    private func database(forConversationID conversationID: UUID) async throws -> any Database {
        if let fixedDatabase {
            return fixedDatabase
        }
        guard let app else {
            throw Abort(.internalServerError, reason: "ConversationEventualReadService missing both app and database.")
        }
        return try await app.conversationShardRouter.eventualReadDatabase(forConversationID: conversationID)
    }

    private func timelineReadSupport(for conversationID: UUID) async throws -> ConversationTimelineReadSupport {
        let db = try await database(forConversationID: conversationID)
        guard let app else {
            return ConversationTimelineReadSupport(db: db)
        }
        return ConversationTimelineReadSupport(
            db: db,
            featureDB: app.db,
            metrics: app.timelineReadMetrics,
            configuration: app.timelineReadConfiguration,
            sinceHotCache: app.timelineSinceHotCache,
            sinceRecentCache: app.timelineSinceRecentCache,
            sinceVisibilitySafetyCache: app.timelineSinceVisibilitySafetyCache,
            sinceResponseCoalescer: app.timelineSinceResponseCoalescer
        )
    }
}

extension IMConversationService {
    static func command(app: Application) -> ConversationCommandService {
        ConversationCommandService(app: app)
    }

    static func strongRead(app: Application) -> ConversationStrongReadService {
        ConversationStrongReadService(app: app)
    }

    static func eventualRead(app: Application) -> ConversationEventualReadService {
        ConversationEventualReadService(app: app)
    }
}
