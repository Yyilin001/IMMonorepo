import Foundation
import IMV2ServerContracts
import SQLKit

/// Names and ordering come from the existing policy/revocation contract, not
/// from hash order. Recursion establishes an execution dependency between each
/// acquisition; sorting a result set does not order volatile lock functions.
func v2AcquireOrderedDirectAuthorizationLocks(_ names: [String], shared: Bool,
    sql: any SQLDatabase
) async throws {
    guard !names.isEmpty, names.count <= 640 else { throw V2DirectAuthorizationIntentError.invalidRequest }
    let input = String(decoding: try JSONEncoder().encode(names), as: UTF8.self)
    let function = shared ? "pg_advisory_xact_lock_shared" : "pg_advisory_xact_lock"
    guard let row = try await sql.raw("""
        WITH RECURSIVE input AS MATERIALIZED (
          SELECT name, ordinal FROM jsonb_array_elements_text(\(bind: input)::jsonb)
            WITH ORDINALITY AS item(name, ordinal)
        ), locked(ordinal, acquired) AS (
          SELECT ordinal, \(unsafeRaw: function)(hashtextextended(name,0)) FROM input WHERE ordinal=1
          UNION ALL
          SELECT input.ordinal, \(unsafeRaw: function)(hashtextextended(input.name,0))
          FROM locked previous JOIN input ON input.ordinal=previous.ordinal+1
        )
        SELECT count(*)::bigint AS value FROM locked
        """).first(decoding: DirectAuthorizationLockCount.self), row.value == Int64(names.count) else {
        throw V2DirectAuthorizationIntentError.corruptPersistence
    }
}
private struct DirectAuthorizationLockCount: Decodable { let value: Int64 }
