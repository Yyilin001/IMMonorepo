import Foundation
import FluentKit
@testable import IMV2ServerApplication
@testable import IMV2ServerInfrastructure
import SQLKit

/// Seed historical database rows to verify rejection by the current runtime.
/// These helpers deliberately provide no legacy registration or commit service.
func v2SeedPendingPolicyChange(database: any Database, schema: String = "im_v2", owner: V2PolicyOwnerLease,
    operationKey: String, fingerprint: Data, commandJSON: String) async throws -> V2PolicyAuthorizationChange {
    v2PreconditionSQLSchema(schema)
    return try await database.transaction { transaction in
        guard let sql = transaction as? any SQLDatabase else {
            throw V2PolicyAuthorizationLifecycleError.invalidRequest
        }
        guard try await sql.raw("""
            UPDATE \(unsafeRaw: schema).policy_authorization_scopes
            SET pending_change_key=\(bind: operationKey)
            WHERE scope_key=\(bind: owner.scope.key) AND owner_id=\(bind: owner.ownerID)
              AND owner_epoch=\(bind: owner.epoch) AND revision=\(bind: owner.revision)
              AND pending_change_key IS NULL
            RETURNING scope_key
            """).first() != nil else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
        try await sql.raw("""
            INSERT INTO \(unsafeRaw: schema).policy_authorization_changes
                (operation_key,scope_key,fingerprint,command,expected_revision,next_revision)
            VALUES (\(bind: operationKey),\(bind: owner.scope.key),\(bind: fingerprint),
                \(bind: commandJSON)::jsonb,\(bind: owner.revision),\(bind: owner.revision + 1))
            """).run()
        return .init(operationKey: operationKey, scopeKey: owner.scope.key, fingerprint: fingerprint,
            commandJSON: commandJSON, expectedRevision: owner.revision, nextRevision: owner.revision + 1,
            committed: false, receipt: nil)
    }
}

func v2SeedLegacyPolicyHolder(sql: any SQLDatabase, schema: String, owner: V2PolicyOwnerLease) async throws {
    v2PreconditionSQLSchema(schema)
    try await sql.raw("""
        INSERT INTO \(unsafeRaw: schema).policy_authorization_holders
            (scope_key,registration_id,room_id,activation_id,room_owner_epoch,generation,endpoint,
             policy_revision,policy_owner_epoch,valid_until)
        VALUES (\(bind: owner.scope.key),\(bind: UUID()),\(bind: UUID()),\(bind: UUID()),1,1,'legacy-room',
            \(bind: owner.revision),\(bind: owner.epoch),clock_timestamp()+interval '30 seconds')
        """).run()
}
