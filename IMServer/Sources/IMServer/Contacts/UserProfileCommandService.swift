import Fluent
import Vapor

struct UserProfileCommandService {
    let app: Application

    func updateProfile(user: User, displayName: String?, avatarPreset: UserAvatarPreset?) async throws -> UserResponse {
        let userID = try user.requireID()
        let profileRevision = try await app.db.transaction { database in
            guard let mutableUser = try await User.find(userID, on: database) else {
                throw Abort(.notFound, reason: "用户不存在。")
            }
            mutableUser.displayName = normalizedDisplayName(displayName)
            mutableUser.avatarPresetEnum = avatarPreset
            mutableUser.profileRevision += 1
            try await mutableUser.update(on: database)
            return mutableUser.profileRevision
        }

        var affectedConversationRecipientUserIDs: [UUID: [UUID]] = [:]
        for readModelDB in summaryReadModelDatabases(for: app) {
            let refreshed = try await IMConversationSummaryProjectionService(
                sourceDB: app.imWriteDB,
                readModelDB: readModelDB,
                userDirectoryDB: app.db
            ).refreshDirectPeerProfiles(for: userID)
            mergeRecipientUserIDs(refreshed, into: &affectedConversationRecipientUserIDs)
        }

        for (conversationID, recipientUserIDs) in affectedConversationRecipientUserIDs {
            let conversationDB = try await app.conversationShardRouter.commandDatabase(forConversationID: conversationID)
            try await ConversationOutboxService(db: conversationDB).enqueueOnce(
                sideEffectKey: "user-profile:\(userID.uuidString.lowercased()):\(conversationID.uuidString.lowercased()):\(profileRevision)",
                type: .directPeerUpdated,
                conversationID: conversationID,
                actorUserID: userID,
                payload: .directPeerUpdated(recipientUserIDs: recipientUserIDs)
            )
        }
        guard let refreshedUser = try await User.find(userID, on: app.db) else {
            throw Abort(.notFound, reason: "用户不存在。")
        }
        await app.authSessionValidationCache.invalidate(userID: userID)
        return try refreshedUser.asResponse()
    }

    private func normalizedDisplayName(_ displayName: String?) -> String? {
        let normalized = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized, !normalized.isEmpty else {
            return nil
        }
        return String(normalized.prefix(40))
    }

    private func summaryReadModelDatabases(for app: Application) -> [any Database] {
        app.summaryShardRouter.shardIDs.map { app.summaryShardRouter.database(forShardID: $0) }
    }

    private func mergeRecipientUserIDs(_ source: [UUID: [UUID]], into destination: inout [UUID: [UUID]]) {
        for (conversationID, userIDs) in source {
            destination[conversationID, default: []].append(contentsOf: userIDs)
            destination[conversationID] = Array(Set(destination[conversationID] ?? []))
                .sorted { $0.uuidString < $1.uuidString }
        }
    }
}
