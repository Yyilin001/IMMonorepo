import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// All state transitions share the media mutex with binding and GC. Provider I/O
/// happens outside transactions. Retention is deliberately persistent: this store
/// cannot release old locations without a separate delivery/reader drain proof.
public struct PostgresV2ResourceMigrationStore: Sendable {
    let database: any Database
    let authorize: @Sendable (any Database, V2ResourceMigrationRequest) async throws -> Void
    public init(database: any Database,
                authorize: @escaping @Sendable (any Database, V2ResourceMigrationRequest) async throws -> Void) {
        self.database=database; self.authorize=authorize
    }

    public func prepare(_ request: V2ResourceMigrationRequest, maximumBytes: Int64,
                        allocate: @escaping @Sendable (V2StoredObjectFacts) throws -> V2StoredObjectReference) async throws -> V2ResourceMigrationStatus {
        guard request.generation > 0, maximumBytes > 0 else { throw V2ResourceProviderError.preconditionFailed }
        return try await database.transaction { transaction in
            let sql = try sql(transaction)
            try await authorize(transaction, request)
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: "resource-migration:" + request.operationID.uuidString),0))").run()
            try await authorize(transaction, request)
            if let prior = try await row(request.operationID, sql: sql) {
                guard try prior.status().request == request else { throw V2MediaStoreError.idempotencyConflict }
                return try prior.status()
            }
            try await lockMedia(request, sql: sql)
            try await authorize(transaction, request)
            guard try await sql.raw("SELECT 1 FROM im_v2.resource_storage_migrations WHERE media_id=\(bind: request.mediaID) AND state IN ('pending','copying')").first() == nil
            else { throw V2ResourceProviderError.throttled(retryAfter: 1) }
            let source = try await current(request, sql: sql)
            guard source.byteCount <= maximumBytes, source.reference.binding != request.targetBinding
            else { throw V2ResourceProviderError.preconditionFailed }
            let destination = try allocate(source)
            guard destination.binding == request.targetBinding, destination.placementID != source.reference.placementID
            else { throw V2ResourceProviderError.configurationInvalid }
            try await sql.raw("""
                INSERT INTO im_v2.resource_storage_migrations(operation_id,media_id,generation,variant_id,request_json,
                    source_json,destination_json,destination_placement_id,byte_count,sha256,state,retry_at,created_at,updated_at)
                VALUES(\(bind: request.operationID),\(bind: request.mediaID),\(bind: request.generation),\(bind: request.variantID),
                    \(bind: encode(request))::jsonb,\(bind: encode(source.reference))::jsonb,\(bind: encode(destination))::jsonb,
                    \(bind: destination.placementID),\(bind: source.byteCount),\(bind: source.sha256),'pending',
                    clock_timestamp(),clock_timestamp(),clock_timestamp())
                """).run()
            guard let inserted = try await row(request.operationID, sql: sql) else { throw V2ResourceProviderError.configurationInvalid }
            return try inserted.status()
        }
    }

    public func status(_ operationID: UUID) async throws -> V2ResourceMigrationStatus {
        try await database.transaction { transaction in
            guard let found = try await row(operationID, sql: sql(transaction)) else { throw V2ResourceProviderError.notFound }
            let status = try found.status()
            try await authorize(transaction, status.request)
            return status
        }
    }

    public func claim(_ operationID: UUID) async throws -> V2ResourceMigrationClaim? {
        try await database.transaction { transaction in
            let sql = try sql(transaction)
            guard let observed = try await row(operationID, sql: sql) else { throw V2ResourceProviderError.notFound }
            let request = try observed.status().request
            try await authorize(transaction, request)
            if observed.state == .switched { return nil }
            try await lockMedia(request, sql: sql)
            try await authorize(transaction, request)
            if try await row(operationID, sql: sql)?.state == .switched { return nil }
            // New statement after the media lock observes a claimant which committed
            // while this transaction waited. Expiry does not permit a new destination.
            let token = UUID()
            guard try await sql.raw("""
                UPDATE im_v2.resource_storage_migrations SET state='copying',claim_token=\(bind: token),
                    lease_expires_at=clock_timestamp()+interval '60 seconds',attempt_count=attempt_count+1,updated_at=clock_timestamp()
                WHERE operation_id=\(bind: operationID)
                  AND ((state='pending' AND retry_at<=clock_timestamp())
                    OR (state='copying' AND lease_expires_at<=clock_timestamp()))
                RETURNING operation_id
                """).first() != nil else { throw V2ResourceProviderError.throttled(retryAfter: 1) }
            guard let claimed = try await row(operationID, sql: sql) else { throw V2ResourceProviderError.configurationInvalid }
            let status = try claimed.status()
            guard try await current(request, sql: sql) == status.source else { throw V2ResourceProviderError.preconditionFailed }
            return .init(status: status, token: token)
        }
    }

    public func publish(_ claim: V2ResourceMigrationClaim, observed: V2StoredObjectFacts) async throws {
        guard observed == claim.status.destination else { throw V2ResourceProviderError.integrityMismatch }
        let request = claim.status.request
        try await database.transaction { transaction in
            let sql = try sql(transaction)
            try await authorize(transaction, request)
            try await lockMedia(request, sql: sql)
            try await authorize(transaction, request)
            guard try await sql.raw("""
                SELECT 1 FROM im_v2.resource_storage_migrations WHERE operation_id=\(bind: request.operationID)
                  AND state='copying' AND claim_token=\(bind: claim.token) AND lease_expires_at>clock_timestamp()
                """).first() != nil,
                try await current(request, sql: sql) == claim.status.source
            else { throw V2ResourceProviderError.preconditionFailed }
            let destination = try encode(observed.reference)
            let changed: (any SQLRow)?
            if let variant = request.variantID {
                changed = try await sql.raw("""
                    UPDATE im_v2.resource_variants SET reference_json=\(bind: destination)::jsonb
                    WHERE media_id=\(bind: request.mediaID) AND generation=\(bind: request.generation)
                      AND variant_id=\(bind: variant) AND state='ready' RETURNING variant_id
                    """).first()
            } else {
                changed = try await sql.raw("""
                    UPDATE im_v2.resource_blob_placements SET placement_id=\(bind: observed.reference.placementID),
                        reference_json=\(bind: destination)::jsonb,verified_at=clock_timestamp()
                    WHERE media_id=\(bind: request.mediaID) AND generation=\(bind: request.generation)
                      AND state='active' RETURNING placement_id
                    """).first()
            }
            guard changed != nil else { throw V2ResourceProviderError.preconditionFailed }
            try await sql.raw("""
                UPDATE im_v2.resource_storage_migrations SET state='switched',claim_token=NULL,lease_expires_at=NULL,
                    switched_at=clock_timestamp(),updated_at=clock_timestamp()
                WHERE operation_id=\(bind: request.operationID) AND claim_token=\(bind: claim.token)
                """).run()
        }
    }

    public func retry(_ claim: V2ResourceMigrationClaim) async throws {
        try await sql(database).raw("""
            UPDATE im_v2.resource_storage_migrations SET state='pending',claim_token=NULL,lease_expires_at=NULL,
                retry_at=clock_timestamp()+LEAST(attempt_count,60)*interval '1 second',updated_at=clock_timestamp()
            WHERE operation_id=\(bind: claim.status.request.operationID) AND state='copying' AND claim_token=\(bind: claim.token)
            """).run()
    }

    public func recoverable(limit: Int) async throws -> [UUID] {
        guard (1...100).contains(limit) else { throw V2ResourceProviderError.preconditionFailed }
        return try await sql(database).raw("""
            SELECT operation_id FROM im_v2.resource_storage_migrations
            WHERE (state='pending' AND retry_at<=clock_timestamp()) OR (state='copying' AND lease_expires_at<=clock_timestamp())
            ORDER BY updated_at,operation_id LIMIT \(bind: limit)
            """).all(decoding: MigrationIDRow.self).map(\.operationID)
    }

    private func lockMedia(_ request: V2ResourceMigrationRequest, sql: any SQLDatabase) async throws {
        guard try await sql.raw("SELECT 1 FROM im_v2.media_objects WHERE media_id=\(bind: request.mediaID) AND state='available' FOR UPDATE").first() != nil,
              try await sql.raw("SELECT 1 FROM im_v2.resource_catalog WHERE media_id=\(bind: request.mediaID) AND generation=\(bind: request.generation)").first() != nil
        else { throw V2ResourceProviderError.preconditionFailed }
    }

    private func current(_ request: V2ResourceMigrationRequest, sql: any SQLDatabase) async throws -> V2StoredObjectFacts {
        let query: SQLQueryString
        if let variant = request.variantID {
            query = """
                SELECT reference_json::text AS reference,byte_count,sha256 FROM im_v2.resource_variants
                WHERE media_id=\(bind: request.mediaID) AND generation=\(bind: request.generation)
                  AND variant_id=\(bind: variant) AND state='ready'
                """
        } else {
            query = """
                SELECT reference_json::text AS reference,byte_count,sha256 FROM im_v2.resource_blob_placements
                WHERE media_id=\(bind: request.mediaID) AND generation=\(bind: request.generation) AND state='active'
                """
        }
        guard let value = try await sql.raw(query).first(decoding: MigrationFactsRow.self) else { throw V2ResourceProviderError.notFound }
        return try .init(reference: JSONDecoder().decode(V2StoredObjectReference.self, from: Data(value.reference.utf8)),
                         byteCount: value.byteCount, sha256: value.sha256)
    }
    private func row(_ operationID: UUID, sql: any SQLDatabase) async throws -> MigrationRow? {
        try await sql.raw("""
            SELECT request_json::text AS request,source_json::text AS source,destination_json::text AS destination,
                byte_count,sha256,state FROM im_v2.resource_storage_migrations WHERE operation_id=\(bind: operationID)
            """).first(decoding: MigrationRow.self)
    }
    private func sql(_ database: any Database) throws -> any SQLDatabase {
        guard let sql = database as? any SQLDatabase else { throw V2ResourceProviderError.configurationInvalid }
        return sql
    }
    private func encode<T: Encodable>(_ value: T) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
}
private struct MigrationIDRow: Decodable {
    let operationID: UUID
    enum CodingKeys: String, CodingKey { case operationID="operation_id" }
}
private struct MigrationFactsRow: Decodable {
    let reference: String; let byteCount: Int64; let sha256: Data
    enum CodingKeys: String, CodingKey { case reference,byteCount="byte_count",sha256 }
}
private struct MigrationRow: Decodable {
    let request: String; let source: String; let destination: String
    let byteCount: Int64; let sha256: Data; let state: V2ResourceMigrationStatus.State
    enum CodingKeys: String, CodingKey { case request,source,destination,byteCount="byte_count",sha256,state }
    func status() throws -> V2ResourceMigrationStatus {
        let decoder = JSONDecoder()
        let request = try decoder.decode(V2ResourceMigrationRequest.self, from: Data(request.utf8))
        let source = try V2StoredObjectFacts(reference: decoder.decode(V2StoredObjectReference.self, from: Data(source.utf8)), byteCount: byteCount, sha256: sha256)
        let destination = try V2StoredObjectFacts(reference: decoder.decode(V2StoredObjectReference.self, from: Data(destination.utf8)), byteCount: byteCount, sha256: sha256)
        guard request.generation > 0, destination.reference.binding == request.targetBinding,
              source.reference.binding != request.targetBinding, source.reference.placementID != destination.reference.placementID
        else { throw V2ResourceProviderError.configurationInvalid }
        return .init(request: request, state: state, source: source, destination: destination)
    }
}

extension PostgresV2ResourceMigrationStore: V2ResourceMigrationPort {}
