import Fluent
import Vapor

struct ConversationCommandService {
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

    func createConversation(
        kind: String?,
        title: String?,
        memberEmails: [String],
        creatorUserID: UUID
    ) async throws -> IMConversationResponse {
        if let app,
           let existingDirectConversation = try await existingDirectConversation(
            app: app,
            kind: kind,
            title: title,
            memberEmails: memberEmails,
            creatorUserID: creatorUserID
           ) {
            return existingDirectConversation
        }

        let conversationID = UUID()
        let assignedShardID = app?.conversationShardRouter.shardID(forNewConversationID: conversationID)
            ?? SingleShardConversationShardRouter.defaultShardID
        let commandDB = commandDatabase(forShardID: assignedShardID)
        let response = try await ConversationCommandSupport(db: commandDB).createConversation(
            conversationID: conversationID,
            assignedShardID: assignedShardID,
            kind: kind,
            title: title,
            memberEmails: memberEmails,
            creatorUserID: creatorUserID
        )
        if let app {
            try await app.conversationDirectory.registerConversation(
                conversationID: response.id,
                shardID: assignedShardID
            )
            if response.kind == IMConversationKind.direct.rawValue {
                try await app.directConversationIndex.registerDirectConversation(
                    conversationID: response.id,
                    memberUserIDs: response.memberUserIDs,
                    shardID: assignedShardID
                )
            }
        }
        return response
    }

    private func existingDirectConversation(
        app: Application,
        kind: String?,
        title: String?,
        memberEmails: [String],
        creatorUserID: UUID
    ) async throws -> IMConversationResponse? {
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
        guard conversationKind == .direct,
              let existingConversationID = try await app.directConversationIndex.conversationID(forMemberUserIDs: memberUserIDs)
        else {
            return nil
        }

        let readDB = try await app.conversationShardRouter.strongReadDatabase(forConversationID: existingConversationID)
        return try await ConversationSummaryReadSupport(db: readDB).conversationSummary(
            conversationID: existingConversationID,
            for: creatorUserID
        )
    }

    func addMembers(
        in conversationID: UUID,
        memberEmails: [String],
        requesterUserID: UUID
    ) async throws -> IMConversationResponse {
        try await ConversationCommandSupport(db: commandDatabase(forConversationID: conversationID)).addMembers(
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
        try await ConversationCommandSupport(db: commandDatabase(forConversationID: conversationID)).removeMember(
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
        try await ConversationCommandSupport(db: commandDatabase(forConversationID: conversationID)).updateMemberRole(
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
        try await ConversationCommandSupport(db: commandDatabase(forConversationID: conversationID)).updateConversationTitle(
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
        try await ConversationCommandSupport(db: commandDatabase(forConversationID: conversationID)).updateConversationMetadata(
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
        try await ConversationCommandSupport(db: commandDatabase(forConversationID: conversationID)).updateConversationPreferences(
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
        try await ConversationCommandSupport(db: commandDatabase(forConversationID: conversationID)).markConversationRead(
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
        try await ConversationCommandSupport(db: commandDatabase(forConversationID: conversationID)).recallMessage(
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
        try await ConversationCommandSupport(db: commandDatabase(forConversationID: conversationID)).editMessage(
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
        try await ConversationCommandSupport(db: commandDatabase(forConversationID: conversationID)).toggleReaction(
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
        try await ConversationCommandSupport(db: commandDatabase(forConversationID: conversationID)).leaveConversation(
            in: conversationID,
            requesterUserID: requesterUserID
        )
    }

    private func commandDatabase(forShardID shardID: String) -> any Database {
        if let fixedDatabase {
            return fixedDatabase
        }
        guard let app else {
            fatalError("ConversationCommandService missing both app and database.")
        }
        return app.conversationShardRouter.commandDatabase(forShardID: shardID)
    }

    private func commandDatabase(forConversationID conversationID: UUID) async throws -> any Database {
        if let fixedDatabase {
            return fixedDatabase
        }
        guard let app else {
            fatalError("ConversationCommandService missing both app and database.")
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

    init(db: any Database) {
        self.app = nil
        self.fixedDatabase = db
    }

    func latestMessage(in conversationID: UUID) async throws -> IMMessageResponse? {
        try await ConversationTimelineReadSupport(db: database(forConversationID: conversationID))
            .latestMessage(in: conversationID)
    }

    func conversationSummary(
        conversationID: UUID,
        for userID: UUID
    ) async throws -> IMConversationResponse {
        try await ConversationSummaryReadSupport(db: database(forConversationID: conversationID))
            .conversationSummary(conversationID: conversationID, for: userID)
    }

    private func database(forConversationID conversationID: UUID) async throws -> any Database {
        if let fixedDatabase {
            return fixedDatabase
        }
        guard let app else {
            fatalError("ConversationStrongReadService missing both app and database.")
        }
        return try await app.conversationShardRouter.strongReadDatabase(forConversationID: conversationID)
    }
}

struct ConversationEventualReadService {
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

    func listConversations(
        for userID: UUID,
        cursor: String?,
        limit: Int?,
        kind: String? = nil
    ) async throws -> IMConversationPageResponse {
        try await ConversationSummaryReadSupport(db: listDatabase())
            .listConversations(for: userID, cursor: cursor, limit: limit, kind: kind)
    }

    func listConversationChanges(
        for userID: UUID,
        afterToken: String,
        cursor: String?,
        limit: Int?
    ) async throws -> IMConversationChangesResponse {
        try await ConversationSummaryReadSupport(db: listDatabase())
            .listConversationChanges(for: userID, afterToken: afterToken, cursor: cursor, limit: limit)
    }

    func listMembers(in conversationID: UUID, for userID: UUID) async throws -> [IMConversationMemberResponse] {
        try await ConversationMembershipService(db: database(forConversationID: conversationID))
            .listMemberResponses(in: conversationID, for: userID)
    }

    func listMessages(
        in conversationID: UUID,
        for userID: UUID,
        beforeSequence: Int?,
        limit: Int?
    ) async throws -> [IMMessageResponse] {
        try await ConversationTimelineReadSupport(db: database(forConversationID: conversationID))
            .listMessages(in: conversationID, for: userID, beforeSequence: beforeSequence, limit: limit)
    }

    func listMessagesSince(
        in conversationID: UUID,
        for userID: UUID,
        afterSequence: Int,
        limit: Int?
    ) async throws -> IMMessageSinceResponse {
        try await ConversationTimelineReadSupport(db: database(forConversationID: conversationID))
            .listMessagesSince(in: conversationID, for: userID, afterSequence: afterSequence, limit: limit)
    }

    func searchMessages(
        in conversationID: UUID,
        for userID: UUID,
        query: String,
        cursor: String?,
        limit: Int?
    ) async throws -> IMConversationMessageSearchPageResponse {
        try await ConversationSearchReadSupport(db: database(forConversationID: conversationID))
            .searchMessages(in: conversationID, for: userID, query: query, cursor: cursor, limit: limit)
    }

    private func listDatabase() -> any Database {
        if let fixedDatabase {
            return fixedDatabase
        }
        guard let app else {
            fatalError("ConversationEventualReadService missing both app and database.")
        }
        return app.conversationShardRouter.eventualReadDatabase()
    }

    private func database(forConversationID conversationID: UUID) async throws -> any Database {
        if let fixedDatabase {
            return fixedDatabase
        }
        guard let app else {
            fatalError("ConversationEventualReadService missing both app and database.")
        }
        return try await app.conversationShardRouter.eventualReadDatabase(forConversationID: conversationID)
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
