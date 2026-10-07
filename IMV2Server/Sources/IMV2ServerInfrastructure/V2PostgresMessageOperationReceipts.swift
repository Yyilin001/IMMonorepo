import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit

/// Identity validation stays in the business store. Lock ordering and key spelling
/// match the existing mutation/reaction writers: operation first, activation second.
func v2LockMessageOperation(actor: UUID, operation: UUID, token: V2RoomActivationToken,
                            sql: any SQLDatabase) async throws {
    try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: actor.uuidString + ":" + operation.uuidString),0))").run()
    try await v2RequireRoomActivation(token: token, sql: sql)
}

func v2ReadMessageOperationReceipt<Receipt: Decodable, Result>(
    _ type: Receipt.Type, query: SQLQueryString, sql: any SQLDatabase,
    validates: (Receipt) -> Bool, receipt: (Receipt) -> Result, conflict: Result
) async throws -> Result? {
    guard let row = try await sql.raw(query).first(decoding: V2OperationReceiptRow.self) else { return nil }
    let value = try v2DecodePersistenceJSON(type, from: row.receipt)
    return validates(value) ? receipt(value) : conflict
}

/// Query and close use the same transaction and operation lock as submission.
/// A replay returns before consulting the new request's timestamp or close action.
func v2RecoverMessageOperation<Result: Sendable>(
    database: any Database, action: V2OperationRecoveryRequest.Action, unresolved: Result,
    lock: @escaping @Sendable (any Database) async throws -> any SQLDatabase,
    existing: @escaping @Sendable (any SQLDatabase) async throws -> Result?,
    close: @escaping @Sendable (any SQLDatabase) async throws -> Result
) async throws -> Result {
    try await v2WithRoomScopedTransaction(database: database) { transaction in
        let sql = try await lock(transaction)
        if let prior = try await existing(sql) { return prior }
        guard action == .closeIfAbsent else { return unresolved }
        return try await close(sql)
    }
}

private struct V2OperationReceiptRow: Decodable { let receipt: String }
