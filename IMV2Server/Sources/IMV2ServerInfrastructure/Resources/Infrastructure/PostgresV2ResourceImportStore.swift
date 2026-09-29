import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// Owns import rows and durable source holds. Each target mutation rechecks authorization in its transaction.
public struct PostgresV2ResourceImportStore: V2ResourceImportPort {
    let resolve: V2ResourceStoreResolving
    let sources: V2ResourceImportSourceResolver
    let resolveConcrete: @Sendable (V2ResourceHome, V2ResourceUsage?, UserID, DeviceID) async throws -> PostgresV2ResourceLifecycleStore
    let ownerDatabases: [String: any Database]

    public init(resolve: @escaping @Sendable (V2ResourceHome, V2ResourceUsage?, UserID, DeviceID) async throws -> PostgresV2ResourceLifecycleStore,
                sources: V2ResourceImportSourceResolver, ownerDatabases: [String: any Database]) {
        self.resolveConcrete = resolve; self.resolve = { home, usage, actor, device in try await resolve(home, usage, actor, device) }
        self.sources = sources; self.ownerDatabases = ownerDatabases
    }

    public func create(_ request: V2ResourceImportRequest, actor: UserID, device: DeviceID) async throws {
        guard actor.uuidValue != nil, device.uuidValue != nil, request.operationID.uuidValue != nil,
              request.targetMediaID.uuidValue != nil, request.source.mediaID.uuidValue != nil
        else { throw V2ResourceProviderError.preconditionFailed }
        let home = request.targetUsage.home(actorUserID: actor)
        let locator = V2ResourceImportLocator(home: home, operationID: request.operationID)
        let store = try await resolveConcrete(home, request.targetUsage, actor, device)
        let json = try encode(request), homeJSON = try encode(home)
        try await store.database.transaction { transaction in
            try await store.authorize(transaction)
            guard let sql = transaction as? any SQLDatabase else { throw V2ResourceProviderError.configurationInvalid }
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: "resource-import:\(actor.rawValue):\(request.operationID.rawValue)"),0))").run()
            if let prior = try await load(locator, actor: actor, device: device, sql: sql) {
                guard try JSONDecoder().decode(V2ResourceImportRequest.self, from: Data(prior.requestText.utf8)) == request
                else { throw V2MediaStoreError.idempotencyConflict }
            } else {
                try await sql.raw("""
                    INSERT INTO im_v2.resource_imports(actor_user_id,device_id,operation_id,home_json,request_json,target_media_id,created_at,updated_at)
                    VALUES(\(bind: actor.uuidValue!),\(bind: device.uuidValue!),\(bind: request.operationID.uuidValue!),\(bind: homeJSON)::jsonb,\(bind: json)::jsonb,\(bind: request.targetMediaID.uuidValue!),clock_timestamp(),clock_timestamp())
                    """).run()
            }
        }
    }

    public func snapshot(_ locator: V2ResourceImportLocator, actor: UserID, device: DeviceID) async throws -> V2ResourceImportSnapshot {
        try await readSnapshot(locator, actor: actor, device: device, includeTerminalSession: false)
    }
    public func cancellationSnapshot(_ locator: V2ResourceImportLocator, actor: UserID, device: DeviceID) async throws -> V2ResourceImportSnapshot {
        try await readSnapshot(locator, actor: actor, device: device, includeTerminalSession: true)
    }
    private func readSnapshot(_ locator: V2ResourceImportLocator, actor: UserID, device: DeviceID,
                              includeTerminalSession: Bool) async throws -> V2ResourceImportSnapshot {
        let (_, row, request) = try await context(locator, actor: actor, device: device)
        guard let state = V2ResourceImportState(rawValue: row.state) else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let session: V2ResourceUploadSession?
        if !includeTerminalSession && (state == .cancelled || state == .failed) { session = nil }
        else { session = try row.sessionText.map { try JSONDecoder().decode(V2ResourceUploadSession.self, from: Data($0.utf8)) } }
        return .init(request: request, session: session, state: state)
    }

    public func acquireSource(_ request: V2ResourceImportRequest, actor: UserID, device: DeviceID) async throws -> V2ResourceImportSourceGrant {
        let source = try await sources.authorize(request.source, actor: actor, device: device)
        let facts = try await hold(request, actor: actor, database: source.database)
        return .init(contentType: facts.contentType, facts: facts.facts, recheck: source.recheck)
    }

    public func attach(_ session: V2ResourceUploadSession, locator: V2ResourceImportLocator, actor: UserID, device: DeviceID) async throws {
        let (store, _, _) = try await context(locator, actor: actor, device: device)
        let sessionJSON = try encode(session)
        try await store.database.transaction { transaction in
            try await store.authorize(transaction)
            guard let sql = transaction as? any SQLDatabase,
                  try await sql.raw("UPDATE im_v2.resource_imports SET session_json=\(bind: sessionJSON)::jsonb,state='copying',updated_at=clock_timestamp() WHERE actor_user_id=\(bind: actor.uuidValue!) AND operation_id=\(bind: locator.operationID.uuidValue!) AND state NOT IN ('cancelled','failed') RETURNING operation_id").first() != nil
            else { throw V2ResourceProviderError.preconditionFailed }
        }
    }

    public func mark(_ locator: V2ResourceImportLocator, actor: UserID, device: DeviceID, state: V2ResourceImportState) async throws {
        let (store, _, _) = try await context(locator, actor: actor, device: device)
        try await store.database.transaction { transaction in
            try await store.authorize(transaction)
            guard let sql = transaction as? any SQLDatabase else { throw V2ResourceProviderError.configurationInvalid }
            try await sql.raw("UPDATE im_v2.resource_imports SET state=\(bind: state.rawValue),updated_at=clock_timestamp() WHERE actor_user_id=\(bind: actor.uuidValue!) AND operation_id=\(bind: locator.operationID.uuidValue!) AND state NOT IN ('cancelled','failed')").run()
        }
    }

    public func releaseSource(_ request: V2ResourceImportRequest, actor: UserID) async throws {
        guard let sql = try await sources.database(for: request.source) as? any SQLDatabase else { throw V2ResourceProviderError.configurationInvalid }
        try await sql.raw("UPDATE im_v2.resource_import_holds SET released_at=clock_timestamp() WHERE actor_user_id=\(bind: actor.uuidValue!) AND operation_id=\(bind: request.operationID.uuidValue!) AND released_at IS NULL").run()
    }

    public func recoveryCandidates(ownerID: String, limit: Int) async throws -> [V2ResourceImportRecoveryItem] {
        guard (1...100).contains(limit), let sql = ownerDatabases[ownerID] as? any SQLDatabase else { throw V2ResourceProviderError.configurationInvalid }
        let rows = try await sql.raw("""
            SELECT actor_user_id,device_id,request_json::text AS request_text
            FROM im_v2.resource_imports WHERE state IN ('pending','copying','processing')
            ORDER BY updated_at,operation_id LIMIT \(bind: limit)
            """).all(decoding: ImportRecoveryRow.self)
        return try rows.map { row in
            let request = try JSONDecoder().decode(V2ResourceImportRequest.self, from: Data(row.requestText.utf8))
            let actor = UserID(uuid: row.actorUserID), device = DeviceID(uuid: row.deviceID)
            return .init(ownerID: ownerID, request: request, locator: .init(home: request.targetUsage.home(actorUserID: actor), operationID: request.operationID), actor: actor, device: device)
        }
    }

    public func recordRecoveryFailure(_ item: V2ResourceImportRecoveryItem) async throws -> Bool {
        guard let sql = ownerDatabases[item.ownerID] as? any SQLDatabase else { throw V2ResourceProviderError.configurationInvalid }
        let actorID = item.actor.uuidValue!, operationID = item.locator.operationID.uuidValue!
        let terminal = try await sql.raw("""
            UPDATE im_v2.resource_imports i SET state='failed',updated_at=clock_timestamp()
            WHERE actor_user_id=\(bind: actorID) AND operation_id=\(bind: operationID)
              AND i.state IN ('pending','copying','processing')
              AND ((i.session_json IS NULL AND i.created_at < clock_timestamp()-interval '24 hours')
                   OR EXISTS (SELECT 1 FROM im_v2.resource_upload_sessions s WHERE s.media_id=i.target_media_id AND s.state IN ('cancelled','expired','failed')))
            RETURNING operation_id
            """).first() != nil
        if !terminal {
            try await sql.raw("UPDATE im_v2.resource_imports SET updated_at=clock_timestamp() WHERE actor_user_id=\(bind: actorID) AND operation_id=\(bind: operationID) AND state IN ('pending','copying','processing')").run()
        }
        return terminal
    }

    private func context(_ locator: V2ResourceImportLocator, actor: UserID, device: DeviceID) async throws -> (PostgresV2ResourceLifecycleStore, ResourceImportRow, V2ResourceImportRequest) {
        guard actor.uuidValue != nil, device.uuidValue != nil, locator.operationID.uuidValue != nil else { throw V2ResourceProviderError.preconditionFailed }
        let lookup = try await resolveConcrete(locator.home, nil, actor, device)
        let row = try await lookup.database.transaction { transaction in
            try await lookup.authorize(transaction)
            guard let sql = transaction as? any SQLDatabase,
                  let row = try await load(locator, actor: actor, device: device, sql: sql)
            else { throw V2MediaStoreError.uploadNotAuthorized }
            return row
        }
        let request = try JSONDecoder().decode(V2ResourceImportRequest.self, from: Data(row.requestText.utf8))
        guard request.targetUsage.home(actorUserID: actor) == locator.home else { throw V2MediaStoreError.uploadNotAuthorized }
        return (try await resolveConcrete(locator.home, request.targetUsage, actor, device), row, request)
    }

    private func load(_ locator: V2ResourceImportLocator, actor: UserID, device: DeviceID, sql: any SQLDatabase) async throws -> ResourceImportRow? {
        try await sql.raw("SELECT request_json::text AS request_text,session_json::text AS session_text,target_media_id,state FROM im_v2.resource_imports WHERE actor_user_id=\(bind: actor.uuidValue!) AND device_id=\(bind: device.uuidValue!) AND operation_id=\(bind: locator.operationID.uuidValue!)").first(decoding: ResourceImportRow.self)
    }

    private func hold(_ request: V2ResourceImportRequest, actor: UserID, database: any Database) async throws -> ImportSourceFacts {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase,
                  let media = try await sql.raw("SELECT content_type FROM im_v2.media_objects WHERE media_id=\(bind: request.source.mediaID.uuidValue!) AND state='available' FOR UPDATE").first(decoding: ImportContentType.self)
            else { throw V2ResourceProviderError.notFound }
            if let previous = try await heldSource(request, actor: actor, sql: sql) { return previous }
            let variant: ResourceVariantID?
            switch request.source { case .message(_, _, let value): variant = value; case .avatar(_, _, let value): variant = value }
            let query: SQLQueryString
            if let variant {
                guard let variantID = variant.uuidValue else { throw V2ResourceProviderError.preconditionFailed }
                query = """
                    SELECT v.reference_json::text AS reference,v.byte_count,v.sha256
                    FROM im_v2.resource_variants v JOIN im_v2.resource_catalog c
                      ON c.media_id=v.media_id AND c.generation=v.generation
                    WHERE v.media_id=\(bind: request.source.mediaID.uuidValue!)
                      AND v.variant_id=\(bind: variantID) AND v.state='ready'
                    """
            } else {
                query = """
                    SELECT p.reference_json::text AS reference,p.byte_count,p.sha256
                    FROM im_v2.resource_blob_placements p JOIN im_v2.resource_catalog c
                      ON c.media_id=p.media_id AND c.generation=p.generation
                    WHERE p.media_id=\(bind: request.source.mediaID.uuidValue!) AND p.state='active'
                    """
            }
            guard let row = try await sql.raw(query).first(decoding: ImportSourceRow.self) else { throw V2ResourceProviderError.notFound }
            let json = try encode(request)
            try await sql.raw("""
                INSERT INTO im_v2.resource_import_holds(actor_user_id,operation_id,media_id,reference_json,
                    request_json,byte_count,sha256,content_type,created_at)
                VALUES(\(bind: actor.uuidValue!),\(bind: request.operationID.uuidValue!),\(bind: request.source.mediaID.uuidValue!),
                    \(bind: row.reference)::jsonb,\(bind: json)::jsonb,\(bind: row.byteCount),\(bind: row.sha256),
                    \(bind: variant == nil ? media.contentType : "image/png"),clock_timestamp()) ON CONFLICT DO NOTHING
                """).run()
            guard let held = try await heldSource(request, actor: actor, sql: sql) else { throw V2ResourceProviderError.preconditionFailed }
            return held
        }
    }

    private func heldSource(_ request: V2ResourceImportRequest, actor: UserID, sql: any SQLDatabase) async throws -> ImportSourceFacts? {
        guard let hold = try await sql.raw("""
            SELECT request_json::text AS request_text,reference_json::text AS reference,
                byte_count,sha256,content_type,released_at
            FROM im_v2.resource_import_holds
            WHERE actor_user_id=\(bind: actor.uuidValue!) AND operation_id=\(bind: request.operationID.uuidValue!)
            """).first(decoding: ImportHoldRow.self) else { return nil }
        guard hold.releasedAt == nil,
              try JSONDecoder().decode(V2ResourceImportRequest.self, from: Data(hold.requestText.utf8)) == request
        else { throw V2MediaStoreError.idempotencyConflict }
        return try .init(contentType: hold.contentType, facts: .init(
            reference: JSONDecoder().decode(V2StoredObjectReference.self, from: Data(hold.reference.utf8)),
            byteCount: hold.byteCount, sha256: hold.sha256))
    }

    private func encode<T: Encodable>(_ value: T) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
}

private struct ResourceImportRow: Decodable {
    let requestText: String; let sessionText: String?; let targetMediaID: UUID; let state: String
    enum CodingKeys: String, CodingKey { case requestText = "request_text", sessionText = "session_text", targetMediaID = "target_media_id", state }
}
private struct ImportContentType: Decodable { let contentType: String; enum CodingKeys: String, CodingKey { case contentType = "content_type" } }
private struct ImportSourceFacts { let contentType: String; let facts: V2StoredObjectFacts }
private struct ImportSourceRow: Decodable {
    let reference: String; let byteCount: Int64; let sha256: Data
    enum CodingKeys: String, CodingKey { case reference, byteCount = "byte_count", sha256 }
}
private struct ImportHoldRow: Decodable {
    let requestText: String; let reference: String; let byteCount: Int64; let sha256: Data
    let contentType: String; let releasedAt: Date?
    enum CodingKeys: String, CodingKey {
        case requestText = "request_text", reference, byteCount = "byte_count", sha256, contentType = "content_type", releasedAt = "released_at"
    }
}
private struct ImportRecoveryRow: Decodable {
    let actorUserID: UUID; let deviceID: UUID; let requestText: String
    enum CodingKeys: String, CodingKey { case actorUserID = "actor_user_id", deviceID = "device_id", requestText = "request_text" }
}
