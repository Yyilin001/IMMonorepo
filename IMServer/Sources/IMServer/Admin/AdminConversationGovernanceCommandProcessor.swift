import Fluent
import Foundation
import SQLKit
import Vapor

struct AdminConversationGovernanceCommandProcessor {
    private static let processingLeaseDuration: TimeInterval = 300

    let app: Application

    func process(commandID: UUID) async throws -> AdminConversationGovernanceCommand {
        let processingToken = UUID().uuidString.lowercased()
        guard let command = try await claimCommand(
            commandID: commandID,
            processingToken: processingToken
        ) else {
            guard let current = try await AdminConversationGovernanceCommand.find(commandID, on: app.db) else {
                throw Abort(.notFound, reason: "后台群治理命令不存在。")
            }
            return current
        }
        return try await processClaimed(command, processingToken: processingToken)
    }

    func processPending(limit: Int) async throws -> [AdminConversationGovernanceCommand] {
        let processingToken = UUID().uuidString.lowercased()
        let commands = try await claimPendingCommands(
            limit: max(1, limit),
            processingToken: processingToken
        )
        var results: [AdminConversationGovernanceCommand] = []
        results.reserveCapacity(commands.count)
        for command in commands {
            results.append(try await processClaimed(command, processingToken: processingToken))
        }
        return results
    }

    private func processClaimed(
        _ command: AdminConversationGovernanceCommand,
        processingToken: String
    ) async throws -> AdminConversationGovernanceCommand {
        guard command.statusEnum == .applying,
              command.processingToken == processingToken
        else {
            return command
        }
        guard let action = command.actionEnum else {
            return try await markFailed(command, code: "unsupported_action", processingToken: processingToken)
        }

        let database: any Database
        let eventID: UUID
        do {
            let router = app.conversationShardRouter
            let route: ConversationRoute
            if router.routerName == "single-shard" {
                route = ConversationRoute(
                    cellID: app.imRealtimeCellID,
                    shardID: SingleShardConversationShardRouter.defaultShardID
                )
            } else {
                route = try await app.conversationDirectory.route(for: command.conversationID)
            }
            guard route.cellID == command.targetCellID,
                  route.shardID == command.targetShardID,
                  route.version == command.targetRouteVersion
            else {
                return try await markFailed(command, code: "route_changed", processingToken: processingToken)
            }
            guard route.cellID == app.imRealtimeCellID else {
                return try await markFailed(command, code: "remote_cell", processingToken: processingToken)
            }
            guard router.shardIDs.contains(route.shardID) else {
                return try await markFailed(command, code: "unknown_shard", processingToken: processingToken)
            }
            database = router.commandDatabase(forShardID: route.shardID)
            switch action {
            case .groupMuteAllSet:
                eventID = try await applyMuteAll(command, on: database)
            case .groupLifecycleSet:
                eventID = try await applyGroupLifecycle(command, on: database)
            case .groupMemberRemove:
                eventID = try await applyMemberRemoval(command, on: database)
            }
        } catch {
            _ = try? await markFailed(command, code: Self.errorCode(for: error), processingToken: processingToken)
            throw error
        }
        await ConversationOutboxNotification.notifyPendingEvents(on: database)
        if action == .groupMemberRemove {
            await IMConversationCommandSideEffects(app: app)
                .invalidateMemberCacheEverywhere(conversationID: command.conversationID)
        }
        return try await markApplied(
            commandID: try command.requireID(),
            eventID: eventID,
            processingToken: processingToken
        )
    }

    private func applyMuteAll(
        _ command: AdminConversationGovernanceCommand,
        on database: any Database
    ) async throws -> UUID {
        let commandID = try command.requireID()
        let sideEffectKey = "admin-governance:\(commandID.uuidString.lowercased())"
        return try await database.transaction { transaction in
            try await ConversationWriteFenceService.requireWritesAllowed(
                conversationID: command.conversationID,
                on: transaction
            )
            if let existing = try await ConversationDomainEventSideEffect.find(sideEffectKey, on: transaction) {
                guard try await ConversationDomainEvent.find(existing.eventID, on: transaction) != nil else {
                    throw Abort(.internalServerError, reason: "后台群治理幂等记录缺少 Outbox 事件。")
                }
                return existing.eventID
            }

            guard let conversation = try await Conversation.find(command.conversationID, on: transaction) else {
                throw Abort(.notFound, reason: "会话不存在。")
            }
            try ConversationMembershipGuard.requireGroup(
                conversation,
                reason: "后台群治理命令只支持群聊。"
            )
            guard conversation.groupLifecycleStateEnum != .dissolved else {
                throw Abort(.conflict, reason: "群聊已解散，不能调整全员禁言。")
            }
            if conversation.muteAll != command.requestedMuteAll {
                conversation.muteAll = command.requestedMuteAll
                conversation.updatedAt = Date()
                try await conversation.update(on: transaction)
            }

            let recipientUserIDs = try await ConversationMember.query(on: transaction)
                .filter(\.$conversation.$id == command.conversationID)
                .all()
                .map(\.$user.id)
            guard !recipientUserIDs.isEmpty else {
                throw Abort(.internalServerError, reason: "后台群治理命令缺少会话成员。")
            }

            let eventID = UUID()
            try await ConversationDomainEventSideEffect(
                sideEffectKey: sideEffectKey,
                eventID: eventID
            ).create(on: transaction)
            let sequence = try await ConversationDomainEventSequenceAllocator(db: transaction).allocate(
                conversationID: command.conversationID,
                on: transaction
            )
            let event = try ConversationDomainEvent(
                id: eventID,
                conversationID: command.conversationID,
                eventType: .metadataUpdated,
                aggregateSequence: imIntSequence(sequence.rawValue, field: "aggregate_sequence"),
                sideEffectKey: sideEffectKey,
                actorUserID: command.actorUserID,
                payload: .metadataUpdated(recipientUserIDs: recipientUserIDs)
            )
            try await event.create(on: transaction)
            return eventID
        }
    }

    private func applyMemberRemoval(
        _ command: AdminConversationGovernanceCommand,
        on database: any Database
    ) async throws -> UUID {
        guard command.destructiveConfirmed,
              let targetMemberUserID = command.targetMemberUserID
        else {
            throw Abort(.badRequest, reason: "后台移除群成员命令缺少目标或确认。")
        }
        let commandID = try command.requireID()
        let sideEffectKey = "admin-governance:\(commandID.uuidString.lowercased())"
        return try await database.transaction { transaction in
            try await ConversationWriteFenceService.requireWritesAllowed(
                conversationID: command.conversationID,
                on: transaction
            )
            if let existing = try await ConversationDomainEventSideEffect.find(sideEffectKey, on: transaction) {
                guard try await ConversationDomainEvent.find(existing.eventID, on: transaction) != nil else {
                    throw Abort(.internalServerError, reason: "后台群治理幂等记录缺少 Outbox 事件。")
                }
                return existing.eventID
            }

            guard let conversation = try await Conversation.find(command.conversationID, on: transaction) else {
                throw Abort(.notFound, reason: "会话不存在。")
            }
            try ConversationMembershipGuard.requireGroup(
                conversation,
                reason: "后台群治理命令只支持群聊。"
            )
            guard conversation.groupLifecycleStateEnum != .dissolved else {
                throw Abort(.conflict, reason: "群聊已解散，成员关系已归档。")
            }
            let memberships = try await ConversationMember.query(on: transaction)
                .filter(\.$conversation.$id == command.conversationID)
                .all()
            guard let targetMembership = memberships.first(where: { $0.$user.id == targetMemberUserID }) else {
                throw Abort(.notFound, reason: "目标群成员不存在。")
            }
            guard targetMembership.memberRoleEnum != .owner else {
                throw Abort(.badRequest, reason: "后台治理不能直接移除群主。")
            }
            guard memberships.count - 1 >= 2 else {
                throw Abort(.badRequest, reason: "移除后群成员不能少于 2 人。")
            }

            let now = Date()
            try await targetMembership.delete(on: transaction)
            conversation.membershipRevision = now
            conversation.updatedAt = now
            try await conversation.update(on: transaction)

            let remainingUserIDs = memberships.map(\.$user.id).filter { $0 != targetMemberUserID }
            let publisher = ConversationSummaryRefreshPublisher(db: transaction)
            try await publisher.publishConversationRemoved(
                conversationID: command.conversationID,
                actorUserID: command.actorUserID,
                affectedUserID: targetMemberUserID,
                on: transaction
            )

            let eventID = UUID()
            try await ConversationDomainEventSideEffect(
                sideEffectKey: sideEffectKey,
                eventID: eventID
            ).create(on: transaction)
            let sequence = try await ConversationDomainEventSequenceAllocator(db: transaction).allocate(
                conversationID: command.conversationID,
                on: transaction
            )
            let event = try ConversationDomainEvent(
                id: eventID,
                conversationID: command.conversationID,
                eventType: .membershipRemoved,
                aggregateSequence: imIntSequence(sequence.rawValue, field: "aggregate_sequence"),
                sideEffectKey: sideEffectKey,
                actorUserID: command.actorUserID,
                payload: .memberRemoved(
                    memberUserIDs: [targetMemberUserID],
                    recipientUserIDs: remainingUserIDs
                )
            )
            try await event.create(on: transaction)
            return eventID
        }
    }

    private func applyGroupLifecycle(
        _ command: AdminConversationGovernanceCommand,
        on database: any Database
    ) async throws -> UUID {
        let requestedState = command.requestedGroupLifecycleStateEnum
        guard (requestedState != .frozen && requestedState != .dissolved) || command.destructiveConfirmed else {
            throw Abort(
                .badRequest,
                reason: requestedState == .dissolved ? "解散群命令缺少显式确认。" : "冻结群命令缺少显式确认。"
            )
        }
        let commandID = try command.requireID()
        let sideEffectKey = "admin-governance:\(commandID.uuidString.lowercased())"
        return try await database.transaction { transaction in
            try await ConversationWriteFenceService.requireWritesAllowed(
                conversationID: command.conversationID,
                on: transaction
            )
            if let existing = try await ConversationDomainEventSideEffect.find(sideEffectKey, on: transaction) {
                guard try await ConversationDomainEvent.find(existing.eventID, on: transaction) != nil else {
                    throw Abort(.internalServerError, reason: "后台群治理幂等记录缺少 Outbox 事件。")
                }
                return existing.eventID
            }
            guard let conversation = try await Conversation.find(command.conversationID, on: transaction) else {
                throw Abort(.notFound, reason: "会话不存在。")
            }
            try ConversationMembershipGuard.requireGroup(
                conversation,
                reason: "后台群治理命令只支持群聊。"
            )
            guard conversation.groupLifecycleStateEnum != .dissolved || requestedState == .dissolved else {
                throw Abort(.conflict, reason: "群聊已解散，不能恢复为活跃或冻结状态。")
            }
            if conversation.groupLifecycleStateEnum != requestedState {
                conversation.groupLifecycleStateEnum = requestedState
                conversation.updatedAt = Date()
                try await conversation.update(on: transaction)
            }
            let recipientUserIDs = try await ConversationMember.query(on: transaction)
                .filter(\.$conversation.$id == command.conversationID)
                .all()
                .map(\.$user.id)
            guard !recipientUserIDs.isEmpty else {
                throw Abort(.internalServerError, reason: "后台群治理命令缺少会话成员。")
            }
            let eventID = UUID()
            try await ConversationDomainEventSideEffect(
                sideEffectKey: sideEffectKey,
                eventID: eventID
            ).create(on: transaction)
            let sequence = try await ConversationDomainEventSequenceAllocator(db: transaction).allocate(
                conversationID: command.conversationID,
                on: transaction
            )
            try await ConversationDomainEvent(
                id: eventID,
                conversationID: command.conversationID,
                eventType: .metadataUpdated,
                aggregateSequence: imIntSequence(sequence.rawValue, field: "aggregate_sequence"),
                sideEffectKey: sideEffectKey,
                actorUserID: command.actorUserID,
                payload: .metadataUpdated(recipientUserIDs: recipientUserIDs)
            ).create(on: transaction)
            return eventID
        }
    }

    private func markApplied(
        commandID: UUID,
        eventID: UUID,
        processingToken: String
    ) async throws -> AdminConversationGovernanceCommand {
        try await app.db.transaction { database in
            guard let command = try await AdminConversationGovernanceCommand.find(commandID, on: database) else {
                throw Abort(.notFound, reason: "后台群治理命令不存在。")
            }
            guard command.statusEnum != .applied else {
                return command
            }
            guard command.statusEnum == .applying,
                  command.processingToken == processingToken
            else {
                return command
            }
            command.statusEnum = .applied
            command.appliedAt = Date()
            command.updatedAt = command.appliedAt ?? Date()
            command.lastErrorCode = nil
            command.processingToken = nil
            command.processingStartedAt = nil
            try await command.update(on: database)
            try await recordAudit(
                action: "conversation.governance.command.applied",
                command: command,
                metadata: Self.governanceAuditMetadata(command, values: [
                    "eventID": eventID.uuidString,
                    "targetShardID": command.targetShardID,
                    "targetCellID": command.targetCellID,
                    "targetRouteVersion": "\(command.targetRouteVersion)"
                ]),
                on: database
            )
            return command
        }
    }

    private func markFailed(
        _ command: AdminConversationGovernanceCommand,
        code: String,
        processingToken: String
    ) async throws -> AdminConversationGovernanceCommand {
        let commandID = try command.requireID()
        return try await app.db.transaction { database in
            guard let persisted = try await AdminConversationGovernanceCommand.find(commandID, on: database) else {
                throw Abort(.notFound, reason: "后台群治理命令不存在。")
            }
            guard persisted.statusEnum != .applied else {
                return persisted
            }
            guard persisted.statusEnum == .applying,
                  persisted.processingToken == processingToken
            else {
                return persisted
            }

            persisted.statusEnum = .failed
            persisted.lastErrorCode = code
            persisted.updatedAt = Date()
            persisted.processingToken = nil
            persisted.processingStartedAt = nil
            try await persisted.update(on: database)
            try await recordAudit(
                action: "conversation.governance.command.failed",
                command: persisted,
                metadata: Self.governanceAuditMetadata(persisted, values: [
                    "errorCode": code,
                    "targetShardID": persisted.targetShardID,
                    "targetCellID": persisted.targetCellID,
                    "targetRouteVersion": "\(persisted.targetRouteVersion)"
                ]),
                on: database
            )
            return persisted
        }
    }

    private func claimPendingCommands(
        limit: Int,
        processingToken: String
    ) async throws -> [AdminConversationGovernanceCommand] {
        let now = Date()
        let cutoff = now.addingTimeInterval(-Self.processingLeaseDuration)
        if let sql = app.db as? any SQLDatabase, sql.dialect.name == "postgresql" {
            struct ClaimedRow: Decodable { let id: UUID }
            let rows = try await sql.raw("""
                WITH \(ident: "claimed") AS (
                    SELECT \(ident: "id")
                    FROM \(ident: AdminConversationGovernanceCommand.schema)
                    WHERE \(ident: "status") = \(bind: AdminConversationGovernanceCommandStatus.pending.rawValue)
                       OR (
                           \(ident: "status") = \(bind: AdminConversationGovernanceCommandStatus.applying.rawValue)
                           AND (\(ident: "processing_started_at") IS NULL OR \(ident: "processing_started_at") <= \(bind: cutoff))
                       )
                    ORDER BY \(ident: "updated_at") ASC, \(ident: "id") ASC
                    LIMIT \(bind: limit)
                    FOR UPDATE SKIP LOCKED
                )
                UPDATE \(ident: AdminConversationGovernanceCommand.schema)
                SET \(ident: "status") = \(bind: AdminConversationGovernanceCommandStatus.applying.rawValue),
                    \(ident: "attempt_count") = \(ident: "attempt_count") + 1,
                    \(ident: "last_error_code") = NULL,
                    \(ident: "processing_token") = \(bind: processingToken),
                    \(ident: "processing_started_at") = \(bind: now),
                    \(ident: "updated_at") = \(bind: now)
                WHERE \(ident: "id") IN (SELECT \(ident: "id") FROM \(ident: "claimed"))
                RETURNING \(ident: "id")
                """).all(decoding: ClaimedRow.self)
            return try await claimedCommands(ids: rows.map(\.id))
        }

        return try await app.db.transaction { database in
            let candidates = try await AdminConversationGovernanceCommand.query(on: database)
                .group(.or) { group in
                    group.filter(\.$status == AdminConversationGovernanceCommandStatus.pending.rawValue)
                    group.filter(\.$status == AdminConversationGovernanceCommandStatus.applying.rawValue)
                }
                .sort(\.$updatedAt, .ascending)
                .all()
            var claimed: [AdminConversationGovernanceCommand] = []
            for command in candidates where Self.isClaimable(command, cutoff: cutoff, allowFailed: false) {
                Self.claim(command, processingToken: processingToken, now: now)
                try await command.update(on: database)
                claimed.append(command)
                if claimed.count == limit {
                    break
                }
            }
            return claimed
        }
    }

    private func claimCommand(
        commandID: UUID,
        processingToken: String
    ) async throws -> AdminConversationGovernanceCommand? {
        let now = Date()
        let cutoff = now.addingTimeInterval(-Self.processingLeaseDuration)
        if let sql = app.db as? any SQLDatabase, sql.dialect.name == "postgresql" {
            struct ClaimedRow: Decodable { let id: UUID }
            let rows = try await sql.raw("""
                WITH \(ident: "claimed") AS (
                    SELECT \(ident: "id")
                    FROM \(ident: AdminConversationGovernanceCommand.schema)
                    WHERE \(ident: "id") = \(bind: commandID)
                      AND (
                          \(ident: "status") = \(bind: AdminConversationGovernanceCommandStatus.pending.rawValue)
                          OR \(ident: "status") = \(bind: AdminConversationGovernanceCommandStatus.failed.rawValue)
                          OR (
                              \(ident: "status") = \(bind: AdminConversationGovernanceCommandStatus.applying.rawValue)
                              AND (\(ident: "processing_started_at") IS NULL OR \(ident: "processing_started_at") <= \(bind: cutoff))
                          )
                      )
                    FOR UPDATE SKIP LOCKED
                )
                UPDATE \(ident: AdminConversationGovernanceCommand.schema)
                SET \(ident: "status") = \(bind: AdminConversationGovernanceCommandStatus.applying.rawValue),
                    \(ident: "attempt_count") = \(ident: "attempt_count") + 1,
                    \(ident: "last_error_code") = NULL,
                    \(ident: "processing_token") = \(bind: processingToken),
                    \(ident: "processing_started_at") = \(bind: now),
                    \(ident: "updated_at") = \(bind: now)
                WHERE \(ident: "id") IN (SELECT \(ident: "id") FROM \(ident: "claimed"))
                RETURNING \(ident: "id")
                """).all(decoding: ClaimedRow.self)
            return try await claimedCommands(ids: rows.map(\.id)).first
        }

        return try await app.db.transaction { database in
            guard let command = try await AdminConversationGovernanceCommand.find(commandID, on: database),
                  Self.isClaimable(command, cutoff: cutoff, allowFailed: true)
            else {
                return nil
            }
            Self.claim(command, processingToken: processingToken, now: now)
            try await command.update(on: database)
            return command
        }
    }

    private func claimedCommands(ids: [UUID]) async throws -> [AdminConversationGovernanceCommand] {
        guard !ids.isEmpty else {
            return []
        }
        let commands = try await AdminConversationGovernanceCommand.query(on: app.db)
            .filter(\.$id ~~ ids)
            .all()
        return commands.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return (lhs.id?.uuidString ?? "") < (rhs.id?.uuidString ?? "")
            }
            return lhs.updatedAt < rhs.updatedAt
        }
    }

    private static func isClaimable(
        _ command: AdminConversationGovernanceCommand,
        cutoff: Date,
        allowFailed: Bool
    ) -> Bool {
        switch command.statusEnum {
        case .pending:
            return true
        case .failed:
            return allowFailed
        case .applying:
            return command.processingStartedAt.map { $0 <= cutoff } ?? true
        case .applied:
            return false
        }
    }

    private static func claim(
        _ command: AdminConversationGovernanceCommand,
        processingToken: String,
        now: Date
    ) {
        command.statusEnum = .applying
        command.attemptCount += 1
        command.lastErrorCode = nil
        command.processingToken = processingToken
        command.processingStartedAt = now
        command.updatedAt = now
    }

    private static func governanceAuditMetadata(
        _ command: AdminConversationGovernanceCommand,
        values: [String: String]
    ) -> [String: String] {
        var metadata = values
        metadata["governanceAction"] = command.action
        switch command.actionEnum {
        case .groupMuteAllSet:
            metadata["muteAll"] = command.requestedMuteAll ? "true" : "false"
        case .groupLifecycleSet:
            metadata["groupLifecycleState"] = command.requestedGroupLifecycleState
            metadata["confirmed"] = command.destructiveConfirmed ? "true" : "false"
        case .groupMemberRemove:
            metadata["targetMemberUserID"] = command.targetMemberUserID?.uuidString ?? ""
            metadata["confirmed"] = command.destructiveConfirmed ? "true" : "false"
        case nil:
            break
        }
        return metadata
    }

    private func recordAudit(
        action: String,
        command: AdminConversationGovernanceCommand,
        metadata: [String: String],
        on database: any Database
    ) async throws {
        let merged = metadata.merging([
            "adminRole": command.actorRole,
            "authenticationMethod": command.authenticationMethod
        ], uniquingKeysWith: { current, _ in current })
        let data = try JSONEncoder().encode(merged)
        try await AdminAuditEvent(
            actor: command.actor,
            action: action,
            targetType: "conversation",
            targetID: command.conversationID.uuidString,
            metadataJSON: String(decoding: data, as: UTF8.self)
        ).create(on: database)
    }

    private static func errorCode(for error: any Error) -> String {
        if let abort = error as? any AbortError {
            return "http_\(abort.status.code)"
        }
        return "apply_failed"
    }
}
