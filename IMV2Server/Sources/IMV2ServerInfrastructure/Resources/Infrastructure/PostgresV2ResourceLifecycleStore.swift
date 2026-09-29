import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// Every mutation runs the owner's authorization/fence check in the same SQL transaction.
public typealias V2ResourceTransactionAuthorization = @Sendable (any Database) async throws -> Void

public struct V2PersistedResourceUpload: Sendable {
    public let sessionID: UUID
    public let mediaID: UUID
    public let generation: Int64
    public let state: String
    public let mediaState: String
    public let requestJSON: String
    public let placement: V2StoredObjectReference
    public let expiresAt: Date
    public let claimToken: UUID?
}

public struct PostgresV2ResourceLifecycleStore: Sendable {
    package let database: any Database
    package let authorize: V2ResourceTransactionAuthorization
    public let authorizationExpiresAt: Date?
    public let backgroundDelegationExpiresAt: Date?
    public init(database: any Database, authorizationExpiresAt: Date? = nil, backgroundDelegationExpiresAt: Date? = nil, authorize: @escaping V2ResourceTransactionAuthorization) {
        self.database = database; self.authorize = authorize; self.authorizationExpiresAt = authorizationExpiresAt; self.backgroundDelegationExpiresAt = backgroundDelegationExpiresAt
    }
    public func create(homeKind: String, homeID: UUID, usageKind: String, actor: UUID, device: UUID, operation: UUID,
                       mediaID: UUID, contentType: String, byteCount: Int64, requestJSON: String,
                       allocate: @escaping @Sendable () throws -> V2StoredObjectReference,
                       expiresAt: Date, now: Date) async throws -> V2PersistedResourceUpload {
        return try await database.transaction { transaction in
            try await authorize(transaction)
            guard let sql = transaction as? any SQLDatabase else { throw V2ResourceProviderError.configurationInvalid }
            let key = "resource-upload:\(homeKind):\(homeID):\(actor)"
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: key), 0))").run()
            if let row = try await sql.raw("""
                SELECT s.*, s.request_json::text AS request_text, s.placement_json::text AS placement_text, m.state AS media_state
                FROM im_v2.resource_upload_sessions s JOIN im_v2.media_objects m ON m.media_id = s.media_id
                WHERE s.home_kind = \(bind: homeKind) AND s.home_id = \(bind: homeID)
                  AND s.actor_user_id = \(bind: actor) AND s.operation_id = \(bind: operation)
                """).first(decoding: ResourceUploadRow.self) {
                guard row.deviceID == device, row.mediaID == mediaID,
                      try JSONSerialization.jsonObject(with: Data(row.requestText.utf8)) as? NSDictionary == JSONSerialization.jsonObject(with: Data(requestJSON.utf8)) as? NSDictionary
                else { throw V2MediaStoreError.idempotencyConflict }
                return try row.value()
            }
            guard v2PostgresTimestampPrecedes(now, expiresAt) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            // Admission and allocation apply only to a new operation. A replay must
            // keep its persisted binding even if the new default has different limits.
            // This closure is pure configuration/identity work, never provider I/O.
            let placement = try allocate()
            let referenceJSON = String(decoding: try JSONEncoder().encode(placement), as: UTF8.self)
            // A bounded staging reservation serialized by home + actor. Terminal rows release it.
            guard let quota = try await sql.raw("""
                SELECT COUNT(*)::bigint AS count, COALESCE(SUM(m.byte_count),0)::bigint AS bytes
                FROM im_v2.resource_upload_sessions s JOIN im_v2.media_objects m ON m.media_id=s.media_id
                WHERE s.home_kind=\(bind: homeKind) AND s.home_id=\(bind: homeID) AND s.actor_user_id=\(bind: actor)
                  AND s.state IN ('created','uploading','finalizing')
                """).first(decoding: ResourceReservationRow.self), quota.count < 8,
                  byteCount > 0, byteCount <= 256 * 1_024 * 1_024 - quota.bytes
            else { throw V2ResourceProviderError.throttled(retryAfter: 30) }
            let session = UUID()
            try await sql.raw("""
                INSERT INTO im_v2.media_objects(media_id,owner_user_id,content_type,byte_count,state,upload_session_id,expires_at,state_updated_at,created_at)
                VALUES(\(bind: mediaID),\(bind: actor),\(bind: contentType),\(bind: byteCount),'pending_upload',\(bind: session),\(bind: expiresAt),\(bind: now),\(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.resource_catalog(media_id,home_kind,home_id,usage_kind,generation,created_at)
                VALUES(\(bind:mediaID),\(bind:homeKind),\(bind:homeID),\(bind:usageKind),1,\(bind:now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.resource_upload_sessions(session_id,media_id,home_kind,home_id,actor_user_id,device_id,operation_id,request_json,storage_binding_id,storage_configuration_revision,placement_json,expires_at,created_at,updated_at)
                VALUES(\(bind: session),\(bind: mediaID),\(bind: homeKind),\(bind: homeID),\(bind: actor),\(bind: device),\(bind: operation),\(bind: requestJSON)::jsonb,\(bind: placement.binding.id),\(bind: placement.binding.configurationRevision),\(bind: referenceJSON)::jsonb,\(bind: expiresAt),\(bind: now),\(bind: now))
                """).run()
            return try await load(session: session, actor: actor, device: device, on: transaction, lock: false).value()
        }
    }
    public func status(session: UUID, actor: UUID, device: UUID) async throws -> V2PersistedResourceUpload {
        try await database.transaction { transaction in
            try await authorize(transaction)
            return try await load(session: session, actor: actor, device: device, on: transaction, lock: false).value()
        }
    }
    /// Claim is persisted before storage I/O. Expired leases reuse the same output identity.
    public func claimFinalize(session: UUID, generation: Int64, actor: UUID, device: UUID, now: Date) async throws -> V2PersistedResourceUpload {
        try await database.transaction { transaction in
            try await authorize(transaction)
            let row = try await load(session: session, actor: actor, device: device, on: transaction, lock: true)
            guard row.generation == generation else { throw V2ResourceProviderError.preconditionFailed }
            if row.state == "completed" { return try row.value() }
            let currentTime = try V2PersistenceTimestamp(date: now)
            guard let leaseExpiry = v2PostgresFutureTimestamp(now: now, interval: 60) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard row.expiresAt.microseconds > currentTime.microseconds, ["created", "uploading", "finalizing"].contains(row.state),
                  row.claimToken == nil || row.leaseExpiresAt.map({ $0.microseconds <= currentTime.microseconds }) == true
            else { throw V2ResourceProviderError.preconditionFailed }
            guard let sql = transaction as? any SQLDatabase else { throw V2ResourceProviderError.configurationInvalid }
            let token = UUID()
            try await sql.raw("UPDATE im_v2.resource_upload_sessions SET state='finalizing',claim_token=\(bind: token),lease_expires_at=\(bind: leaseExpiry),updated_at=\(bind: now) WHERE session_id=\(bind: session)").run()
            return try row.value(state: "finalizing", claimToken: token)
        }
    }
    public func publish(_ claim: V2PersistedResourceUpload, facts: V2StoredObjectFacts, actor: UUID, device: UUID, now: Date) async throws {
        try await publishUploadClaim(sessionID: claim.sessionID, mediaID: claim.mediaID,
            generation: claim.generation, placement: claim.placement, claimToken: claim.claimToken,
            facts: facts, actor: actor, device: device, now: now)
    }
    func publishUploadClaim(sessionID: UUID, mediaID: UUID, generation: Int64, placement: V2StoredObjectReference,
                            claimToken: UUID?, facts: V2StoredObjectFacts, actor: UUID, device: UUID, now: Date) async throws {
        try await database.transaction { transaction in
            try await authorize(transaction)
            let row = try await load(session: sessionID, actor: actor, device: device, on: transaction, lock: true)
            let currentTime = try V2PersistenceTimestamp(date: now)
            guard row.state == "finalizing", row.generation == generation, row.claimToken == claimToken,
                  row.expiresAt.microseconds > currentTime.microseconds,
                  row.leaseExpiresAt.map({ $0.microseconds > currentTime.microseconds }) == true, facts.reference == placement,
                  let sql = transaction as? any SQLDatabase else { throw V2ResourceProviderError.preconditionFailed }
            let reference = String(decoding: try JSONEncoder().encode(facts.reference), as: UTF8.self)
            try await sql.raw("""
                INSERT INTO im_v2.resource_blob_placements(placement_id,media_id,generation,reference_json,byte_count,sha256,state,verified_at)
                VALUES(\(bind: facts.reference.placementID),\(bind: mediaID),\(bind: generation),\(bind: reference)::jsonb,\(bind: facts.byteCount),\(bind: facts.sha256),'active',\(bind: now))
                ON CONFLICT(placement_id) DO NOTHING
                """).run()
            try await sql.raw("UPDATE im_v2.media_objects SET state='scanning',state_updated_at=\(bind: now) WHERE media_id=\(bind: mediaID) AND state='pending_upload'").run()
            try await sql.raw("INSERT INTO im_v2.media_scan_outbox(media_id,state,created_at) VALUES(\(bind: mediaID),'pending',\(bind: now)) ON CONFLICT(media_id) DO NOTHING").run()
            try await sql.raw("UPDATE im_v2.resource_upload_sessions SET state='completed',claim_token=NULL,lease_expires_at=NULL,updated_at=\(bind: now) WHERE session_id=\(bind: sessionID)").run()
        }
    }
    public func cancel(session: UUID, generation: Int64, actor: UUID, device: UUID, now: Date) async throws -> V2PersistedResourceUpload {
        try await database.transaction { transaction in
            try await authorize(transaction)
            let row = try await load(session: session, actor: actor, device: device, on: transaction, lock: true)
            let successor = generation.addingReportingOverflow(1)
            guard generation > 0,
                  row.generation == generation || (row.state == "cancelled" && !successor.overflow && row.generation == successor.partialValue)
            else { throw V2ResourceProviderError.preconditionFailed }
            guard row.state != "completed" else { throw V2ResourceProviderError.preconditionFailed }
            guard let sql = transaction as? any SQLDatabase else { throw V2ResourceProviderError.configurationInvalid }
            if row.state != "cancelled" {
                guard !successor.overflow else { throw V2ResourceProviderError.preconditionFailed }
                _ = try V2PersistenceTimestamp(date: now)
                try await sql.raw("UPDATE im_v2.resource_catalog SET generation=generation+1 WHERE media_id=\(bind:row.mediaID)").run()
                try await sql.raw("UPDATE im_v2.resource_upload_sessions SET state='cancelled',generation=generation+1,claim_token=NULL,lease_expires_at=NULL,updated_at=\(bind: now) WHERE session_id=\(bind: session)").run()
                try await sql.raw("UPDATE im_v2.media_objects SET state='expired',state_updated_at=\(bind: now) WHERE media_id=\(bind: row.mediaID)").run()
                try await sql.raw("INSERT INTO im_v2.media_purge_outbox(media_id,reason,state,created_at) VALUES(\(bind: row.mediaID),'unreferenced_expired','pending',\(bind: now)) ON CONFLICT(media_id) DO NOTHING").run()
            }
            return try await load(session: session, actor: actor, device: device, on: transaction, lock: false).value()
        }
    }
    private func load(session: UUID, actor: UUID, device: UUID, on database: any Database, lock: Bool) async throws -> ResourceUploadRow {
        guard let sql = database as? any SQLDatabase else { throw V2ResourceProviderError.configurationInvalid }
        let suffix: SQLQueryString = lock ? "FOR UPDATE OF s, m" : ""
        guard let row = try await sql.raw("""
            SELECT s.*,s.request_json::text AS request_text,s.placement_json::text AS placement_text,m.state AS media_state
            FROM im_v2.resource_upload_sessions s JOIN im_v2.media_objects m ON m.media_id=s.media_id
            WHERE s.session_id=\(bind: session) AND s.actor_user_id=\(bind: actor) AND s.device_id=\(bind: device)
            \(suffix)
            """).first(decoding: ResourceUploadRow.self) else { throw V2MediaStoreError.uploadNotAuthorized }
        return row
    }
}
private struct ResourceReservationRow: Decodable { let count: Int64; let bytes: Int64 }
private struct ResourceUploadRow: Decodable {
    let sessionID: UUID; let mediaID: UUID; let deviceID: UUID; let generation: Int64
    let state: String; let mediaState: String; let requestText: String; let placementText: String; let expiresAt: V2PersistenceTimestamp
    let claimToken: UUID?; let leaseExpiresAt: V2PersistenceTimestamp?
    enum CodingKeys: String, CodingKey {
        case sessionID="session_id",mediaID="media_id",deviceID="device_id",generation,state,mediaState="media_state",requestText="request_text",placementText="placement_text",expiresAt="expires_at",claimToken="claim_token",leaseExpiresAt="lease_expires_at"
    }
    func value(state override: String? = nil, claimToken token: UUID? = nil) throws -> V2PersistedResourceUpload {
        try .init(sessionID: sessionID,mediaID: mediaID,generation: generation,state: override ?? state,mediaState: mediaState,requestJSON: requestText,placement: JSONDecoder().decode(V2StoredObjectReference.self,from: Data(placementText.utf8)),expiresAt: expiresAt.date,claimToken: token ?? claimToken)
    }
}
