import Fluent
import Foundation
import SQLKit
import Vapor

struct ConversationDomainEventSequenceAllocator {
    let db: any Database

    func allocate(conversationID: UUID, on database: (any Database)? = nil) async throws -> IMPositiveSequence {
        guard let value = try await allocateRange(count: 1, conversationID: conversationID, on: database).first else {
            throw Abort(.internalServerError, reason: "领域事件 sequence 分配失败。")
        }
        return value
    }

    func allocateRange(
        count: Int,
        conversationID: UUID,
        on database: (any Database)? = nil
    ) async throws -> [IMPositiveSequence] {
        let values = try await DomainEventSequenceSQLAllocator(
            db: database ?? db,
            table: ConversationDomainEventSequence.schema,
            idColumn: "conversation_id",
            valueColumn: "last_sequence"
        ).allocateRange(count: count, id: conversationID)
        return try values.map { try IMPositiveSequence(databaseValue: $0, field: "aggregate_sequence") }
    }
}

struct OwnerContactEventSequenceAllocator {
    let db: any Database

    func allocate(ownerUserID: UUID, on database: (any Database)? = nil) async throws -> IMPositiveSequence {
        let value = try await DomainEventSequenceSQLAllocator(
            db: database ?? db,
            table: OwnerContactEventSequence.schema,
            idColumn: "owner_user_id",
            valueColumn: "last_sequence"
        ).allocate(id: ownerUserID)
        return try IMPositiveSequence(databaseValue: value, field: "owner_sequence")
    }
}

struct OwnerDomainEventDeliveryCursorAllocator {
    let db: any Database

    func allocate(ownerUserID: UUID, on database: (any Database)? = nil) async throws -> IMPositiveSequence {
        let value = try await DomainEventSequenceSQLAllocator(
            db: database ?? db,
            table: OwnerDomainEventDeliveryCursor.schema,
            idColumn: "owner_user_id",
            valueColumn: "last_cursor"
        ).allocate(id: ownerUserID)
        return try IMPositiveSequence(databaseValue: value, field: "owner_cursor")
    }
}

struct OwnerDomainEventAggregateSequenceAllocator {
    let db: any Database

    func allocate(
        ownerUserID: UUID,
        aggregateType: String,
        aggregateID: UUID,
        on database: (any Database)? = nil
    ) async throws -> IMPositiveSequence {
        let value = try await OwnerDomainEventAggregateSequenceSQLAllocator(db: database ?? db)
            .allocate(ownerUserID: ownerUserID, aggregateType: aggregateType, aggregateID: aggregateID)
        return try IMPositiveSequence(databaseValue: value, field: "owner_aggregate_sequence")
    }
}

private struct OwnerDomainEventAggregateSequenceSQLAllocator {
    struct Row: Decodable {
        let value: Int
    }

    let db: any Database

    func allocate(ownerUserID: UUID, aggregateType: String, aggregateID: UUID) async throws -> Int {
        let id = OwnerDomainEventAggregateSequence.sequenceID(
            ownerUserID: ownerUserID,
            aggregateType: aggregateType,
            aggregateID: aggregateID
        )
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "领域事件 sequence allocator 需要 SQL database。")
        }
        guard let row = try await sql.raw("""
            INSERT INTO \(unsafeRaw: OwnerDomainEventAggregateSequence.schema) (id, owner_user_id, aggregate_type, aggregate_id, last_sequence)
            VALUES (\(bind: id), \(bind: ownerUserID), \(bind: aggregateType), \(bind: aggregateID), 1)
            ON CONFLICT (id) DO UPDATE
            SET last_sequence = \(unsafeRaw: OwnerDomainEventAggregateSequence.schema).last_sequence + 1
            RETURNING last_sequence AS value
            """)
            .first(decoding: Row.self)
        else {
            throw Abort(.internalServerError, reason: "Owner aggregate sequence 分配失败。")
        }
        return row.value
    }
}

private struct DomainEventSequenceSQLAllocator {
    struct Row: Decodable {
        let value: Int
    }

    let db: any Database
    let table: String
    let idColumn: String
    let valueColumn: String

    func allocate(id: UUID) async throws -> Int {
        guard let value = try await allocateRange(count: 1, id: id).first else {
            throw Abort(.internalServerError, reason: "领域事件 sequence 分配失败。")
        }
        return value
    }

    func allocateRange(count: Int, id: UUID) async throws -> [Int] {
        guard count > 0 else {
            return []
        }
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "领域事件 sequence allocator 需要 SQL database。")
        }
        let end = try await allocateRangeWithUpsert(id: id, count: count, on: sql)
        guard end >= count else {
            throw Abort(.internalServerError, reason: "领域事件 sequence 批量分配返回了无效范围。")
        }
        return Array((end - count + 1)...end)
    }

    private func allocateRangeWithUpsert(id: UUID, count: Int, on sql: any SQLDatabase) async throws -> Int {
        guard let row = try await sql.raw("""
            INSERT INTO \(unsafeRaw: table) (\(unsafeRaw: idColumn), \(unsafeRaw: valueColumn))
            VALUES (\(bind: id), \(bind: count))
            ON CONFLICT (\(unsafeRaw: idColumn)) DO UPDATE
            SET \(unsafeRaw: valueColumn) = \(unsafeRaw: table).\(unsafeRaw: valueColumn)
                + excluded.\(unsafeRaw: valueColumn)
            RETURNING \(unsafeRaw: valueColumn) AS value
            """)
            .first(decoding: Row.self)
        else {
            throw Abort(.internalServerError, reason: "领域事件 sequence 分配失败。")
        }
        return row.value
    }

}
