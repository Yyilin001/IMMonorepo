import Fluent
import NIOCore
import Vapor

/// Target-side import endpoint for the durable cross-Cell migration protocol.
/// It is deliberately idempotent by primary key: a source can retry a page
/// after a network failure without duplicating canonical records.
struct InternalConversationMigrationTransferController: RouteCollection {
    private let maxBodySize = ByteCount(value: 8 * 1024 * 1024)

    func boot(routes: any RoutesBuilder) throws {
        routes.grouped("internal", "im", "migrations").on(
            .POST,
            "transfer-page",
            body: .collect(maxSize: maxBodySize),
            use: transferPage
        )
    }

    func transferPage(req: Request) async throws -> IMCellConversationMigrationTransferResponse {
        let batch = try req.content.decode(IMCellConversationMigrationTransferBatch.self)
        _ = try await InternalConversationMigrationIngressAuthorization.validate(
            req: req,
            conversationID: batch.conversationID,
            originCellID: batch.originCellID,
            targetCellID: batch.targetCellID,
            targetShardID: batch.targetShardID,
            sourceRouteVersion: batch.sourceRouteVersion,
            transferToken: batch.transferToken,
            allowedStatuses: [.copying]
        )
        guard batch.records.count <= 1_000 else {
            throw Abort(.payloadTooLarge, reason: "Migration transfer pages are limited to 1000 records.")
        }
        guard IMCellConversationMigrationTransferBatch.checksum(for: batch.records) == batch.checksum else {
            throw Abort(.badRequest, reason: "Migration transfer page checksum mismatch.")
        }
        guard req.application.conversationShardRouter.shardIDs.contains(batch.targetShardID) else {
            throw Abort(.badRequest, reason: "Unknown target conversation shard: \(batch.targetShardID)")
        }
        let database = req.application.conversationShardRouter.commandDatabase(forShardID: batch.targetShardID)
        return try await database.transaction { transaction in
            try await importRecords(batch: batch, on: transaction)
        }
    }

    private func importRecords(
        batch: IMCellConversationMigrationTransferBatch,
        on database: any Database
    ) async throws -> IMCellConversationMigrationTransferResponse {
        var imported = 0
        var alreadyPresent = 0
        let decoder = JSONDecoder()

        switch batch.kind {
        case .conversation:
            for data in batch.records {
                let record = try decoder.decode(Conversation.self, from: data)
                guard record.id == batch.conversationID else { throw invalidOwnership() }
                if try await Conversation.find(batch.conversationID, on: database) != nil { alreadyPresent += 1; continue }
                let createdAt = record.createdAt
                try await record.create(on: database)
                record.createdAt = createdAt
                try await record.update(on: database)
                imported += 1
            }
        case .members:
            for data in batch.records {
                let record = try decoder.decode(ConversationMember.self, from: data)
                guard record.$conversation.id == batch.conversationID, let id = record.id else { throw invalidOwnership() }
                if try await ConversationMember.find(id, on: database) != nil { alreadyPresent += 1; continue }
                let joinedAt = record.joinedAt
                try await record.create(on: database); record.joinedAt = joinedAt; try await record.update(on: database); imported += 1
            }
        case .messages:
            for data in batch.records {
                let record = try decoder.decode(ConversationMessage.self, from: data)
                guard record.$conversation.id == batch.conversationID, let id = record.id else { throw invalidOwnership() }
                if try await ConversationMessage.find(id, on: database) != nil { alreadyPresent += 1; continue }
                let createdAt = record.createdAt
                try await record.create(on: database); record.createdAt = createdAt; try await record.update(on: database); imported += 1
            }
        case .domainEvents:
            for data in batch.records {
                let record = try decoder.decode(ConversationDomainEvent.self, from: data)
                guard record.conversationID == batch.conversationID, let id = record.id else { throw invalidOwnership() }
                if try await ConversationDomainEvent.find(id, on: database) != nil { alreadyPresent += 1; continue }
                try await record.create(on: database); imported += 1
            }
        case .domainEventSequence:
            for data in batch.records {
                let record = try decoder.decode(ConversationDomainEventSequence.self, from: data)
                guard record.id == batch.conversationID else { throw invalidOwnership() }
                if try await ConversationDomainEventSequence.find(batch.conversationID, on: database) != nil { alreadyPresent += 1; continue }
                try await record.create(on: database); imported += 1
            }
        case .recipientSnapshots:
            for data in batch.records {
                let record = try decoder.decode(ConversationDomainEventRecipientSnapshot.self, from: data)
                guard record.conversationID == batch.conversationID, let id = record.id else { throw invalidOwnership() }
                if try await ConversationDomainEventRecipientSnapshot.find(id, on: database) != nil { alreadyPresent += 1; continue }
                try await record.create(on: database); imported += 1
            }
        case .timelineNotices:
            for data in batch.records {
                let record = try decoder.decode(ConversationTimelineNotice.self, from: data)
                guard record.conversationID == batch.conversationID, let id = record.id else { throw invalidOwnership() }
                if try await ConversationTimelineNotice.find(id, on: database) != nil { alreadyPresent += 1; continue }
                try await record.create(on: database); imported += 1
            }
        case .mediaReferences:
            for data in batch.records {
                let record = try decoder.decode(ConversationMediaAssetReference.self, from: data)
                guard record.conversationID == batch.conversationID, let id = record.id else { throw invalidOwnership() }
                if try await ConversationMediaAssetReference.find(id, on: database) != nil { alreadyPresent += 1; continue }
                try await record.create(on: database); imported += 1
            }
        case .sideEffects:
            for data in batch.records {
                let record = try decoder.decode(ConversationDomainEventSideEffect.self, from: data)
                guard let key = record.id,
                      let event = try await ConversationDomainEvent.find(record.eventID, on: database),
                      event.conversationID == batch.conversationID
                else { throw invalidOwnership() }
                if try await ConversationDomainEventSideEffect.find(key, on: database) != nil { alreadyPresent += 1; continue }
                try await record.create(on: database); imported += 1
            }
        }
        return IMCellConversationMigrationTransferResponse(importedCount: imported, alreadyPresentCount: alreadyPresent)
    }

    private func invalidOwnership() -> Abort {
        Abort(.badRequest, reason: "Migration transfer record does not belong to the requested conversation.")
    }
}
