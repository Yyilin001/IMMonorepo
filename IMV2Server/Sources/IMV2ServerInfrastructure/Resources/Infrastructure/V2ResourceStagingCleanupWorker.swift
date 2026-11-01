import FluentKit
import Foundation
import IMV2Core
import IMV2ServerApplication
import SQLKit

package struct PostgresV2ResourceStagingCleanupPersistence: V2ResourceStagingCleanupPersistence {
    let database: any Database

    package func claim(limit: Int) async throws -> [V2ResourceStagingCleanupClaim] {
        guard (1...100).contains(limit), let sql = database as? any SQLDatabase else { throw V2ResourceProviderError.configurationInvalid }
        let token = UUID()
        let rows = try await sql.raw("""
            WITH candidates AS (
                SELECT session_id FROM im_v2.resource_upload_sessions
                WHERE staging_cleanup_pending AND state='completed' AND staging_cleanup_retry_at<=clock_timestamp()
                  AND (staging_cleanup_lease_expires_at IS NULL OR staging_cleanup_lease_expires_at<=clock_timestamp())
                ORDER BY staging_cleanup_retry_at,session_id LIMIT \(bind: limit) FOR UPDATE SKIP LOCKED
            )
            UPDATE im_v2.resource_upload_sessions s
            SET staging_cleanup_claim_token=\(bind: token),staging_cleanup_lease_expires_at=clock_timestamp()+interval '5 minutes'
            FROM candidates c WHERE s.session_id=c.session_id
            RETURNING s.session_id,s.request_json::text AS request_text,s.storage_binding_id,s.storage_configuration_revision
            """).all(decoding: CleanupRow.self)
        return rows.map { row in
            .init(sessionID: row.sessionID, token: token, source: Result {
                (try JSONDecoder().decode(V2ResourceUploadRequest.self, from: Data(row.request.utf8)),
                 try V2StorageBinding(id: row.bindingID, configurationRevision: row.revision))
            })
        }
    }

    package func complete(_ claim: V2ResourceStagingCleanupClaim) async throws {
        guard let sql = database as? any SQLDatabase else { throw V2ResourceProviderError.configurationInvalid }
        try await sql.raw("""
            UPDATE im_v2.resource_upload_sessions SET staging_cleanup_pending=false,
                staging_cleanup_claim_token=NULL,staging_cleanup_lease_expires_at=NULL
            WHERE session_id=\(bind: claim.sessionID) AND staging_cleanup_claim_token=\(bind: claim.token)
              AND staging_cleanup_pending AND state='completed'
            """).run()
    }

    package func retry(_ claim: V2ResourceStagingCleanupClaim) async throws {
        guard let sql = database as? any SQLDatabase else { throw V2ResourceProviderError.configurationInvalid }
        try await sql.raw("""
            UPDATE im_v2.resource_upload_sessions SET staging_cleanup_retry_at=clock_timestamp()+interval '30 seconds',
                staging_cleanup_claim_token=NULL,staging_cleanup_lease_expires_at=NULL
            WHERE session_id=\(bind: claim.sessionID) AND staging_cleanup_claim_token=\(bind: claim.token)
              AND staging_cleanup_pending AND state='completed'
            """).run()
    }
}

public extension V2ResourceStagingCleanupWorker {
    init(database: any Database, service: V2ResourceService) {
        self.init(persistence: PostgresV2ResourceStagingCleanupPersistence(database: database), service: service)
    }
}

private struct CleanupRow: Decodable {
    let sessionID: UUID
    let request: String
    let bindingID: String
    let revision: Int
    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", request = "request_text", bindingID = "storage_binding_id", revision = "storage_configuration_revision"
    }
}
