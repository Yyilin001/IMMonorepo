import Fluent
import Foundation
import Vapor

/// Performs a physical conversation-shard copy. It never changes
/// `conversation_directory`; routing remains on the source until the separate
/// fenced cutover command has re-verified the copied state.
struct ConversationShardMigrationCopyCoordinator {
    struct CanonicalVerification: Sendable {
        let sourceFingerprint: String
        let targetFingerprint: String
    }

    let app: Application

    func copy(conversationID: UUID, pageSize requestedPageSize: Int = 200) async throws -> ConversationShardMigration {
        let pageSize = min(max(requestedPageSize, 1), 1_000)
        await app.conversationShardMigrationMetrics.recordCopyAttempt()
        guard let migration = try await loadMigration(conversationID: conversationID) else {
            throw Abort(.notFound, reason: "No prepared conversation shard migration exists for \(conversationID.uuidString).")
        }
        guard [.prepared, .copying, .copied, .failed].contains(migration.statusEnum) else {
            throw Abort(.conflict, reason: "Migration \(conversationID.uuidString) is \(migration.status) and cannot enter copy.")
        }

        do {
            let source = try await validatedSourceDatabase(for: migration)
            migration.statusEnum = .copying
            migration.lastErrorCode = nil
            migration.copyStartedAt = migration.copyStartedAt ?? Date()
            migration.updatedAt = Date()
            try await migration.update(on: app.db)

            if migration.targetCellID == app.imRealtimeCellID {
                let target = try validatedLocalTargetDatabase(for: migration)
                try await copyConversation(migration, source: source, target: target)
                try await copyMembers(migration, source: source, target: target, pageSize: pageSize)
                try await copyMessages(migration, source: source, target: target, pageSize: pageSize)
                try await copyDomainEvents(migration, source: source, target: target, pageSize: pageSize)
                try await copyDomainEventSequences(migration, source: source, target: target)
                try await copyRecipientSnapshots(migration, source: source, target: target, pageSize: pageSize)
                try await copyTimelineNotices(migration, source: source, target: target, pageSize: pageSize)
                try await copyMediaReferences(migration, source: source, target: target, pageSize: pageSize)
            } else {
                let transfer = ConversationShardMigrationRemoteTransfer(app: app, migration: migration)
                try await copyConversation(migration, source: source, transfer: transfer)
                try await copyMembers(migration, source: source, transfer: transfer, pageSize: pageSize)
                try await copyMessages(migration, source: source, transfer: transfer, pageSize: pageSize)
                try await copyDomainEvents(migration, source: source, transfer: transfer, pageSize: pageSize)
                try await copyDomainEventSequences(migration, source: source, transfer: transfer)
                try await copyRecipientSnapshots(migration, source: source, transfer: transfer, pageSize: pageSize)
                try await copyTimelineNotices(migration, source: source, transfer: transfer, pageSize: pageSize)
                try await copyMediaReferences(migration, source: source, transfer: transfer, pageSize: pageSize)
            }

            migration.statusEnum = .copied
            migration.copiedAt = Date()
            migration.updatedAt = Date()
            try await migration.update(on: app.db)
            await app.conversationShardMigrationMetrics.recordCopySuccess()
            return migration
        } catch {
            await app.conversationShardMigrationMetrics.recordCopyFailure()
            migration.statusEnum = .failed
            migration.lastErrorCode = Self.errorCode(error)
            migration.updatedAt = Date()
            try? await migration.update(on: app.db)
            throw error
        }
    }

    func verify(conversationID: UUID, pageSize requestedPageSize: Int = 500) async throws -> ConversationShardMigration {
        let pageSize = min(max(requestedPageSize, 1), 1_000)
        await app.conversationShardMigrationMetrics.recordVerifyAttempt()
        guard let migration = try await loadMigration(conversationID: conversationID) else {
            throw Abort(.notFound, reason: "No prepared conversation shard migration exists for \(conversationID.uuidString).")
        }
        guard [.copied, .verifying, .readyToCutover].contains(migration.statusEnum) else {
            throw Abort(.conflict, reason: "Migration \(conversationID.uuidString) must be copied before verification.")
        }

        do {
            migration.statusEnum = .verifying
            migration.updatedAt = Date()
            try await migration.update(on: app.db)

            let verification = try await verifyCanonicalState(migration: migration, pageSize: pageSize)
            migration.sourceFingerprint = verification.sourceFingerprint
            migration.targetFingerprint = verification.targetFingerprint
            migration.statusEnum = .readyToCutover
            migration.verifiedAt = Date()
            migration.lastErrorCode = nil
            migration.updatedAt = Date()
            try await migration.update(on: app.db)
            await app.conversationShardMigrationMetrics.recordVerifySuccess()
            return migration
        } catch {
            await app.conversationShardMigrationMetrics.recordVerifyFailure()
            migration.statusEnum = .failed
            migration.lastErrorCode = Self.errorCode(error)
            migration.updatedAt = Date()
            try? await migration.update(on: app.db)
            throw error
        }
    }

    /// Re-runs the exact canonical verification without changing migration
    /// state. The cutover coordinator calls this only after source writes are
    /// fenced, so the comparison is a stable final barrier before the route
    /// CAS is committed.
    func verifyCanonicalState(
        migration: ConversationShardMigration,
        pageSize: Int
    ) async throws -> CanonicalVerification {
        let conversationID = try migration.requireID()
        let source = try await validatedSourceDatabase(for: migration)
        let sourceSnapshot = try await ConversationShardMigrationPreflight(app: app).snapshot(
            conversationID: conversationID,
            database: source
        )
            let expected = try await expectedSnapshot(for: migration)
        guard sourceSnapshot == expected else {
            throw Abort(.conflict, reason: "Source canonical row counts changed after migration prepare; restart from a fresh preflight.")
        }
        let sourceFingerprint = try await ConversationShardMigrationFingerprint.compute(
            conversationID: conversationID,
            database: source,
            pageSize: pageSize
        )
        let sourceSideEffectCount = try await sideEffectCount(conversationID: conversationID, database: source)

        let targetSnapshot: ConversationShardMigrationPreflight.CanonicalDataSnapshot
        let targetFingerprint: String
        let targetSideEffectCount: Int
        if migration.targetCellID == app.imRealtimeCellID {
            let target = try validatedLocalTargetDatabase(for: migration)
            targetSnapshot = try await ConversationShardMigrationPreflight(app: app).snapshot(
                conversationID: conversationID,
                database: target
            )
            targetFingerprint = try await ConversationShardMigrationFingerprint.compute(
                conversationID: conversationID,
                database: target,
                pageSize: pageSize
            )
            targetSideEffectCount = try await sideEffectCount(conversationID: conversationID, database: target)
        } else {
            let remote = try await ConversationShardMigrationRemoteTransfer(app: app, migration: migration)
                .verify(pageSize: pageSize)
            targetSnapshot = remote.snapshot
            targetFingerprint = remote.fingerprint
            targetSideEffectCount = remote.sideEffectCount
        }
        guard targetSnapshot == expected else {
            throw Abort(.conflict, reason: "Target canonical row counts do not match the prepared source snapshot.")
        }
        guard sourceFingerprint == targetFingerprint else {
            throw Abort(.conflict, reason: "Canonical fingerprint mismatch between source and target shard.")
        }
        guard sourceSideEffectCount == targetSideEffectCount
        else {
            throw Abort(.conflict, reason: "Migration auxiliary event rows are not fully present on the target shard; do not cut over.")
        }
        return CanonicalVerification(
            sourceFingerprint: sourceFingerprint,
            targetFingerprint: targetFingerprint
        )
    }

    private func validatedSourceDatabase(
        for migration: ConversationShardMigration
    ) async throws -> any Database {
        let conversationID = try migration.requireID()
        let route = try await app.conversationDirectory.route(for: conversationID)
        guard migration.sourceCellID == app.imRealtimeCellID,
              route.cellID == migration.sourceCellID,
              route.shardID == migration.sourceShardID,
              route.version == migration.sourceRouteVersion
        else {
            throw Abort(.conflict, reason: "The active route no longer matches the prepared migration source.")
        }
        return app.conversationShardRouter.commandDatabase(forShardID: migration.sourceShardID)
    }

    /// Copy progress updates may touch any of the durable watermarks. Keep the
    /// control record projection explicit and hydrate the two PostgreSQL
    /// sequence fields through the narrow SQL projection below.
    private func loadMigration(conversationID: UUID) async throws -> ConversationShardMigration? {
        guard let migration = try await ConversationShardMigration.query(on: app.db)
            .filter(\.$id == conversationID)
            .field(\.$id)
            .field(\.$sourceCellID)
            .field(\.$sourceShardID)
            .field(\.$sourceRouteVersion)
            .field(\.$targetCellID)
            .field(\.$targetShardID)
            .field(\.$status)
            .field(\.$sourceMemberCount)
            .field(\.$sourceMessageCount)
            .field(\.$sourceDomainEventCount)
            .field(\.$sourceDomainEventSequenceCount)
            .field(\.$sourceTimelineNoticeCount)
            .field(\.$sourceMediaReferenceCount)
            .field(\.$sourceRecipientSnapshotCount)
            .field(\.$copyConversationWatermark)
            .field(\.$copyMemberWatermark)
            .field(\.$copyMessageWatermark)
            .field(\.$copyDomainEventWatermark)
            .field(\.$copyDomainEventSequenceWatermark)
            .field(\.$copyTimelineNoticeWatermark)
            .field(\.$copyMediaReferenceWatermark)
            .field(\.$copyRecipientSnapshotWatermark)
            .field(\.$sourceFingerprint)
            .field(\.$targetFingerprint)
            .field(\.$lastErrorCode)
            .field(\.$preparedAt)
            .field(\.$updatedAt)
            .field(\.$copyStartedAt)
            .field(\.$copiedAt)
            .field(\.$verifiedAt)
            .field(\.$cutoverAt)
            .field(\.$cutoverLeaseToken)
            .field(\.$cutoverLeaseExpiresAt)
            .field(\.$transferToken)
            .field(\.$transferTokenExpiresAt)
            .first()
        else {
            return nil
        }
        let sequenceProgress = try await ConversationShardMigrationSequenceProgressStore.load(
            conversationID: conversationID,
            on: app.db
        )
        migration.sourceDomainEventSequenceCount = sequenceProgress.sourceCount
        migration.copyDomainEventSequenceWatermark = sequenceProgress.copyWatermark
        return migration
    }

    private func validatedLocalTargetDatabase(
        for migration: ConversationShardMigration
    ) throws -> any Database {
        guard migration.targetCellID == app.imRealtimeCellID else {
            throw Abort(.conflict, reason: "Target Cell \(migration.targetCellID) must be verified through its remote migration ingress.")
        }
        guard app.conversationShardRouter.shardIDs.contains(migration.targetShardID) else {
            throw Abort(.badRequest, reason: "Unknown conversation target shard: \(migration.targetShardID)")
        }
        return app.conversationShardRouter.commandDatabase(forShardID: migration.targetShardID)
    }

    private func expectedSnapshot(
        for migration: ConversationShardMigration
    ) async throws -> ConversationShardMigrationPreflight.CanonicalDataSnapshot {
        let sequenceProgress = try await ConversationShardMigrationSequenceProgressStore.load(
            conversationID: migration.requireID(),
            on: app.db
        )
        return .init(
            conversationCount: 1,
            memberCount: migration.sourceMemberCount,
            messageCount: migration.sourceMessageCount,
            domainEventCount: migration.sourceDomainEventCount,
            domainEventSequenceCount: sequenceProgress.sourceCount,
            timelineNoticeCount: migration.sourceTimelineNoticeCount,
            mediaReferenceCount: migration.sourceMediaReferenceCount,
            recipientSnapshotCount: migration.sourceRecipientSnapshotCount
        )
    }

    private func sideEffectCount(
        conversationID: UUID,
        database: any Database
    ) async throws -> Int {
        let eventIDs = try await ConversationDomainEvent.query(on: database)
            .filter(\.$conversationID == conversationID)
            .all()
            .compactMap(\.id)
        guard !eventIDs.isEmpty else { return 0 }
        return try await ConversationDomainEventSideEffect.query(on: database)
            .filter(\.$eventID ~~ eventIDs)
            .count()
    }

    private func copyConversation(
        _ migration: ConversationShardMigration,
        source: any Database,
        target: any Database
    ) async throws {
        guard migration.copyConversationWatermark == 0 else { return }
        let conversationID = try migration.requireID()
        guard let sourceRecord = try await Conversation.find(conversationID, on: source) else {
            throw Abort(.conflict, reason: "Prepared source conversation no longer exists.")
        }
        try await target.transaction { database in
            if try await Conversation.find(conversationID, on: database) == nil {
                let copied = sourceRecord.migrationCopy()
                try await copied.create(on: database)
                // Fluent's `on: .create` timestamp middleware overwrites this
                // column on insert, so restore the source timestamp in the
                // same destination transaction before advancing the watermark.
                copied.createdAt = sourceRecord.createdAt
                try await copied.update(on: database)
            }
        }
        migration.copyConversationWatermark = 1
        try await persistProgress(migration)
    }

    private func copyMembers(
        _ migration: ConversationShardMigration,
        source: any Database,
        target: any Database,
        pageSize: Int
    ) async throws {
        let conversationID = try migration.requireID()
        while migration.copyMemberWatermark < migration.sourceMemberCount {
            let records = try await ConversationMember.query(on: source)
                .filter(\.$conversation.$id == conversationID)
                .sort(\.$id, .ascending)
                .range(migration.copyMemberWatermark..<(migration.copyMemberWatermark + pageSize))
                .all()
            try await copy(records, on: target) { record, database in
                let id = try record.requireID()
                if try await ConversationMember.find(id, on: database) == nil {
                    let copied = record.migrationCopy()
                    try await copied.create(on: database)
                    copied.joinedAt = record.joinedAt
                    try await copied.update(on: database)
                }
            }
            try await advance(&migration.copyMemberWatermark, by: records.count, migration: migration, label: "members")
        }
    }

    private func copyMessages(
        _ migration: ConversationShardMigration,
        source: any Database,
        target: any Database,
        pageSize: Int
    ) async throws {
        let conversationID = try migration.requireID()
        while migration.copyMessageWatermark < migration.sourceMessageCount {
            let records = try await ConversationMessage.query(on: source)
                .filter(\.$conversation.$id == conversationID)
                .sort(\.$timelineSequence, .ascending)
                .sort(\.$id, .ascending)
                .range(migration.copyMessageWatermark..<(migration.copyMessageWatermark + pageSize))
                .all()
            try await copy(records, on: target) { record, database in
                let id = try record.requireID()
                if try await ConversationMessage.find(id, on: database) == nil {
                    let copied = record.migrationCopy()
                    try await copied.create(on: database)
                    copied.createdAt = record.createdAt
                    try await copied.update(on: database)
                }
            }
            try await advance(&migration.copyMessageWatermark, by: records.count, migration: migration, label: "messages")
        }
    }

    private func copyDomainEvents(
        _ migration: ConversationShardMigration,
        source: any Database,
        target: any Database,
        pageSize: Int
    ) async throws {
        let conversationID = try migration.requireID()
        while migration.copyDomainEventWatermark < migration.sourceDomainEventCount {
            let records = try await ConversationDomainEvent.query(on: source)
                .filter(\.$conversationID == conversationID)
                .sort(\.$aggregateSequence, .ascending)
                .sort(\.$id, .ascending)
                .range(migration.copyDomainEventWatermark..<(migration.copyDomainEventWatermark + pageSize))
                .all()
            let eventIDs = records.compactMap(\.id)
            let sideEffects = eventIDs.isEmpty ? [] : try await ConversationDomainEventSideEffect.query(on: source)
                .filter(\.$eventID ~~ eventIDs)
                .all()
            try await copy(records, on: target) { record, database in
                let id = try record.requireID()
                if try await ConversationDomainEvent.find(id, on: database) == nil {
                    try await record.migrationCopy().create(on: database)
                }
            }
            try await target.transaction { database in
                for sideEffect in sideEffects {
                    let key = try sideEffect.requireID()
                    if try await ConversationDomainEventSideEffect.find(key, on: database) == nil {
                        try await ConversationDomainEventSideEffect(
                            sideEffectKey: key,
                            eventID: sideEffect.eventID,
                            createdAt: sideEffect.createdAt
                        ).create(on: database)
                    }
                }
            }
            try await advance(&migration.copyDomainEventWatermark, by: records.count, migration: migration, label: "domain events")
        }
    }

    private func copyRecipientSnapshots(
        _ migration: ConversationShardMigration,
        source: any Database,
        target: any Database,
        pageSize: Int
    ) async throws {
        let conversationID = try migration.requireID()
        while migration.copyRecipientSnapshotWatermark < migration.sourceRecipientSnapshotCount {
            let records = try await ConversationDomainEventRecipientSnapshot.query(on: source)
                .filter(\.$conversationID == conversationID)
                .sort(\.$id, .ascending)
                .range(migration.copyRecipientSnapshotWatermark..<(migration.copyRecipientSnapshotWatermark + pageSize))
                .all()
            var copyItems: [ConversationDomainEventRecipientSnapshot] = []
            copyItems.reserveCapacity(records.count)
            for record in records {
                copyItems.append(try await record.migrationCopy(on: source))
            }
            let copiedSnapshots = copyItems
            try await target.transaction { database in
                for record in copiedSnapshots {
                    let eventID = try record.requireID()
                    if try await ConversationDomainEventRecipientSnapshot.find(eventID, on: database) == nil {
                        try await record.create(on: database)
                    }
                }
            }
            try await advance(
                &migration.copyRecipientSnapshotWatermark,
                by: records.count,
                migration: migration,
                label: "recipient snapshots"
            )
        }
    }

    private func copyDomainEventSequences(
        _ migration: ConversationShardMigration,
        source: any Database,
        target: any Database
    ) async throws {
        let conversationID = try migration.requireID()
        let progress = try await ConversationShardMigrationSequenceProgressStore.load(
            conversationID: conversationID,
            on: app.db
        )
        guard progress.copyWatermark < progress.sourceCount else { return }
        guard let record = try await ConversationDomainEventSequence.find(conversationID, on: source) else {
            throw Abort(.conflict, reason: "Prepared source event sequence no longer exists.")
        }
        try await target.transaction { database in
            if try await ConversationDomainEventSequence.find(conversationID, on: database) == nil {
                try await record.migrationCopy().create(on: database)
            }
        }
        try await ConversationShardMigrationSequenceProgressStore.persistCopyWatermark(
            conversationID: conversationID,
            watermark: 1,
            on: app.db
        )
        migration.copyDomainEventSequenceWatermark = 1
    }

    private func copyTimelineNotices(
        _ migration: ConversationShardMigration,
        source: any Database,
        target: any Database,
        pageSize: Int
    ) async throws {
        let conversationID = try migration.requireID()
        while migration.copyTimelineNoticeWatermark < migration.sourceTimelineNoticeCount {
            let records = try await ConversationTimelineNotice.query(on: source)
                .filter(\.$conversationID == conversationID)
                .sort(\.$timelineSequence, .ascending)
                .sort(\.$id, .ascending)
                .range(migration.copyTimelineNoticeWatermark..<(migration.copyTimelineNoticeWatermark + pageSize))
                .all()
            try await copy(records, on: target) { record, database in
                let id = try record.requireID()
                if try await ConversationTimelineNotice.find(id, on: database) == nil {
                    try await record.migrationCopy().create(on: database)
                }
            }
            try await advance(&migration.copyTimelineNoticeWatermark, by: records.count, migration: migration, label: "timeline notices")
        }
    }

    private func copyMediaReferences(
        _ migration: ConversationShardMigration,
        source: any Database,
        target: any Database,
        pageSize: Int
    ) async throws {
        let conversationID = try migration.requireID()
        while migration.copyMediaReferenceWatermark < migration.sourceMediaReferenceCount {
            let records = try await ConversationMediaAssetReference.query(on: source)
                .filter(\.$conversationID == conversationID)
                .sort(\.$serverSequence, .ascending)
                .sort(\.$id, .ascending)
                .range(migration.copyMediaReferenceWatermark..<(migration.copyMediaReferenceWatermark + pageSize))
                .all()
            try await copy(records, on: target) { record, database in
                let id = try record.requireID()
                if try await ConversationMediaAssetReference.find(id, on: database) == nil {
                    try await record.migrationCopy().create(on: database)
                }
            }
            try await advance(&migration.copyMediaReferenceWatermark, by: records.count, migration: migration, label: "media references")
        }
    }

    private func copyConversation(
        _ migration: ConversationShardMigration,
        source: any Database,
        transfer: ConversationShardMigrationRemoteTransfer
    ) async throws {
        guard migration.copyConversationWatermark == 0 else { return }
        let conversationID = try migration.requireID()
        guard let record = try await Conversation.find(conversationID, on: source) else {
            throw Abort(.conflict, reason: "Prepared source conversation no longer exists.")
        }
        try await transfer.upload(kind: .conversation, records: [record])
        migration.copyConversationWatermark = 1
        try await persistProgress(migration)
    }

    private func copyMembers(
        _ migration: ConversationShardMigration,
        source: any Database,
        transfer: ConversationShardMigrationRemoteTransfer,
        pageSize: Int
    ) async throws {
        let conversationID = try migration.requireID()
        while migration.copyMemberWatermark < migration.sourceMemberCount {
            let records = try await ConversationMember.query(on: source)
                .filter(\.$conversation.$id == conversationID)
                .sort(\.$id, .ascending)
                .range(migration.copyMemberWatermark..<(migration.copyMemberWatermark + pageSize))
                .all()
            try await transfer.upload(kind: .members, records: records)
            try await advance(&migration.copyMemberWatermark, by: records.count, migration: migration, label: "members")
        }
    }

    private func copyMessages(
        _ migration: ConversationShardMigration,
        source: any Database,
        transfer: ConversationShardMigrationRemoteTransfer,
        pageSize: Int
    ) async throws {
        let conversationID = try migration.requireID()
        while migration.copyMessageWatermark < migration.sourceMessageCount {
            let records = try await ConversationMessage.query(on: source)
                .filter(\.$conversation.$id == conversationID)
                .sort(\.$timelineSequence, .ascending)
                .sort(\.$id, .ascending)
                .range(migration.copyMessageWatermark..<(migration.copyMessageWatermark + pageSize))
                .all()
            try await transfer.upload(kind: .messages, records: records)
            try await advance(&migration.copyMessageWatermark, by: records.count, migration: migration, label: "messages")
        }
    }

    private func copyDomainEvents(
        _ migration: ConversationShardMigration,
        source: any Database,
        transfer: ConversationShardMigrationRemoteTransfer,
        pageSize: Int
    ) async throws {
        let conversationID = try migration.requireID()
        while migration.copyDomainEventWatermark < migration.sourceDomainEventCount {
            let records = try await ConversationDomainEvent.query(on: source)
                .filter(\.$conversationID == conversationID)
                .sort(\.$aggregateSequence, .ascending)
                .sort(\.$id, .ascending)
                .range(migration.copyDomainEventWatermark..<(migration.copyDomainEventWatermark + pageSize))
                .all()
            let eventIDs = records.compactMap(\.id)
            let sideEffects = eventIDs.isEmpty ? [] : try await ConversationDomainEventSideEffect.query(on: source)
                .filter(\.$eventID ~~ eventIDs)
                .all()
            try await transfer.upload(kind: .domainEvents, records: records)
            try await transfer.upload(kind: .sideEffects, records: sideEffects)
            try await advance(&migration.copyDomainEventWatermark, by: records.count, migration: migration, label: "domain events")
        }
    }

    private func copyDomainEventSequences(
        _ migration: ConversationShardMigration,
        source: any Database,
        transfer: ConversationShardMigrationRemoteTransfer
    ) async throws {
        let conversationID = try migration.requireID()
        let progress = try await ConversationShardMigrationSequenceProgressStore.load(
            conversationID: conversationID,
            on: app.db
        )
        guard progress.copyWatermark < progress.sourceCount else { return }
        guard let record = try await ConversationDomainEventSequence.find(conversationID, on: source) else {
            throw Abort(.conflict, reason: "Prepared source event sequence no longer exists.")
        }
        try await transfer.upload(kind: .domainEventSequence, records: [record])
        try await ConversationShardMigrationSequenceProgressStore.persistCopyWatermark(
            conversationID: conversationID,
            watermark: 1,
            on: app.db
        )
        migration.copyDomainEventSequenceWatermark = 1
    }

    private func copyRecipientSnapshots(
        _ migration: ConversationShardMigration,
        source: any Database,
        transfer: ConversationShardMigrationRemoteTransfer,
        pageSize: Int
    ) async throws {
        let conversationID = try migration.requireID()
        while migration.copyRecipientSnapshotWatermark < migration.sourceRecipientSnapshotCount {
            let records = try await ConversationDomainEventRecipientSnapshot.query(on: source)
                .filter(\.$conversationID == conversationID)
                .sort(\.$id, .ascending)
                .range(migration.copyRecipientSnapshotWatermark..<(migration.copyRecipientSnapshotWatermark + pageSize))
                .all()
            var portableSnapshots: [ConversationDomainEventRecipientSnapshot] = []
            portableSnapshots.reserveCapacity(records.count)
            for record in records {
                portableSnapshots.append(try await record.migrationCopy(on: source))
            }
            try await transfer.upload(kind: .recipientSnapshots, records: portableSnapshots)
            try await advance(
                &migration.copyRecipientSnapshotWatermark,
                by: records.count,
                migration: migration,
                label: "recipient snapshots"
            )
        }
    }

    private func copyTimelineNotices(
        _ migration: ConversationShardMigration,
        source: any Database,
        transfer: ConversationShardMigrationRemoteTransfer,
        pageSize: Int
    ) async throws {
        let conversationID = try migration.requireID()
        while migration.copyTimelineNoticeWatermark < migration.sourceTimelineNoticeCount {
            let records = try await ConversationTimelineNotice.query(on: source)
                .filter(\.$conversationID == conversationID)
                .sort(\.$timelineSequence, .ascending)
                .sort(\.$id, .ascending)
                .range(migration.copyTimelineNoticeWatermark..<(migration.copyTimelineNoticeWatermark + pageSize))
                .all()
            try await transfer.upload(kind: .timelineNotices, records: records)
            try await advance(&migration.copyTimelineNoticeWatermark, by: records.count, migration: migration, label: "timeline notices")
        }
    }

    private func copyMediaReferences(
        _ migration: ConversationShardMigration,
        source: any Database,
        transfer: ConversationShardMigrationRemoteTransfer,
        pageSize: Int
    ) async throws {
        let conversationID = try migration.requireID()
        while migration.copyMediaReferenceWatermark < migration.sourceMediaReferenceCount {
            let records = try await ConversationMediaAssetReference.query(on: source)
                .filter(\.$conversationID == conversationID)
                .sort(\.$serverSequence, .ascending)
                .sort(\.$id, .ascending)
                .range(migration.copyMediaReferenceWatermark..<(migration.copyMediaReferenceWatermark + pageSize))
                .all()
            try await transfer.upload(kind: .mediaReferences, records: records)
            try await advance(&migration.copyMediaReferenceWatermark, by: records.count, migration: migration, label: "media references")
        }
    }

    private func copy<Record: Sendable>(
        _ records: [Record],
        on target: any Database,
        operation: @escaping @Sendable (Record, any Database) async throws -> Void
    ) async throws {
        guard !records.isEmpty else { return }
        try await target.transaction { database in
            for record in records {
                try await operation(record, database)
            }
        }
    }

    private func advance(
        _ watermark: inout Int,
        by count: Int,
        migration: ConversationShardMigration,
        label: String
    ) async throws {
        guard count > 0 else {
            throw Abort(.conflict, reason: "Prepared source \(label) changed before copy completed.")
        }
        watermark += count
        try await persistProgress(migration)
    }

    private func persistProgress(_ migration: ConversationShardMigration) async throws {
        migration.updatedAt = Date()
        try await migration.update(on: app.db)
    }

    private static func errorCode(_ error: any Error) -> String {
        if let abort = error as? Abort {
            return "http_\(abort.status.code)"
        }
        return "copy_failed"
    }
}
