import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// PostgreSQL expiry transaction and candidate scan for resource recovery.
package struct PostgresV2ResourceRecoveryPersistence: V2ResourceRecoveryPersistence {
    let database: any Database

    package func prepare(limit: Int) async throws -> [V2ResourceRecoveryItem] {
        guard let sql = database as? any SQLDatabase else { throw V2ResourceProviderError.configurationInvalid }
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2ResourceProviderError.configurationInvalid }
            let rows = try await sql.raw("""
                SELECT session_id,media_id FROM im_v2.resource_upload_sessions
                WHERE state IN ('created','uploading','finalizing') AND expires_at <= clock_timestamp()
                ORDER BY expires_at,session_id LIMIT \(bind: limit) FOR UPDATE SKIP LOCKED
                """).all(decoding: ExpiredResourceRow.self)
            for row in rows {
                // Same resource mutex used by publication and business bindings.
                _ = try await sql.raw("SELECT 1 FROM im_v2.media_objects WHERE media_id=\(bind: row.mediaID) FOR UPDATE").first()
                try await sql.raw("UPDATE im_v2.resource_catalog SET generation=generation+1 WHERE media_id=\(bind:row.mediaID)").run()
                try await sql.raw("UPDATE im_v2.resource_upload_sessions SET state='expired',generation=generation+1,claim_token=NULL,lease_expires_at=NULL,updated_at=clock_timestamp() WHERE session_id=\(bind: row.sessionID)").run()
                try await sql.raw("UPDATE im_v2.media_objects SET state='expired',state_updated_at=clock_timestamp() WHERE media_id=\(bind: row.mediaID)").run()
                try await sql.raw("INSERT INTO im_v2.media_purge_outbox(media_id,reason,state,created_at) VALUES(\(bind: row.mediaID),'unreferenced_expired','pending',clock_timestamp()) ON CONFLICT(media_id) DO NOTHING").run()
            }
        }
        let rows = try await sql.raw("""
            SELECT session_id,generation,actor_user_id,device_id,request_json::text AS request_text
            FROM im_v2.resource_upload_sessions WHERE state='finalizing' AND expires_at>clock_timestamp()
              AND (lease_expires_at IS NULL OR lease_expires_at<=clock_timestamp())
            ORDER BY lease_expires_at,session_id LIMIT \(bind: limit)
            """).all(decoding: RecoverResourceRow.self)
        return rows.map { row in
            .init(sessionID: row.sessionID, generation: row.generation,
                  actorUserID: row.actorUserID, deviceID: row.deviceID,
                  request: Result {
                      try JSONDecoder().decode(V2ResourceUploadRequest.self, from: Data(row.requestText.utf8))
                  })
        }
    }
}

public extension V2ResourceRecoveryWorker {
    init(database: any Database, service: V2ResourceService) {
        self.init(persistence: PostgresV2ResourceRecoveryPersistence(database: database), service: service)
    }
}

private struct ExpiredResourceRow: Decodable {
    let sessionID: UUID; let mediaID: UUID
    enum CodingKeys: String,CodingKey { case sessionID="session_id",mediaID="media_id" }
}
private struct RecoverResourceRow: Decodable {
    let sessionID: UUID; let generation: Int64; let actorUserID: UUID; let deviceID: UUID; let requestText: String
    enum CodingKeys: String,CodingKey { case sessionID="session_id",generation,actorUserID="actor_user_id",deviceID="device_id",requestText="request_text" }
}
