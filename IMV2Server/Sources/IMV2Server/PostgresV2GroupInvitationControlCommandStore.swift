import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// Opaque metadata only. No invitation bearer is stored in the control recovery journal.
struct PostgresV2GroupInvitationControlCommandStore: Sendable {
    let database: any Database
    func save(_ command: V2GroupInvitationOperationCommand) async throws {
        guard let sql = database as? any SQLDatabase else { throw V2GroupInvitationServiceError.corruptPersistenceState }
        let text = String(decoding:try JSONEncoder().encode(command),as:UTF8.self)
        guard text.utf8.count <= 8_192 else { throw V2GroupInvitationServiceError.invalidRequest }
        try await sql.raw("INSERT INTO im_v2.group_invitation_control_commands(actor_user_id,operation_id,command) VALUES (\(bind: command.identity.accountID.uuidValue!),\(bind: UUID(uuidString:command.identity.operation.rawOperationID)!),\(bind: text)::jsonb) ON CONFLICT DO NOTHING").run()
        guard let stored = try await load(actor:command.identity.accountID.uuidValue!,operation:UUID(uuidString:command.identity.operation.rawOperationID)!),stored == command else { throw V2GroupInvitationServiceError.conflict }
    }
    func finishUncreatedDirectory(_ command: V2GroupInvitationOperationCommand, now: Date) async throws {
        guard case .create = command.intent.action, let sql = database as? any SQLDatabase else { throw V2GroupInvitationServiceError.corruptPersistenceState }
        try await sql.raw("UPDATE im_v2.group_invite_creation_recovery SET state = 'completed',claim_token = NULL,lease_expires_at = NULL,last_error_code = NULL,completed_at = \(bind: now),updated_at = \(bind: now) WHERE actor_user_id = \(bind: command.identity.accountID.uuidValue!) AND operation_id = \(bind: UUID(uuidString:command.identity.operation.rawOperationID)!) AND state <> 'completed'").run()
    }
    func load(actor:UUID,operation:UUID) async throws -> V2GroupInvitationOperationCommand? {
        guard let sql = database as? any SQLDatabase else { throw V2GroupInvitationServiceError.corruptPersistenceState }
        guard let row = try await sql.raw("SELECT command::text AS value FROM im_v2.group_invitation_control_commands WHERE actor_user_id = \(bind: actor) AND operation_id = \(bind: operation)").first(decoding:Text.self) else { return nil }
        return try JSONDecoder().decode(V2GroupInvitationOperationCommand.self,from:Data(row.value.utf8))
    }
    private struct Text: Decodable { let value: String }
}
