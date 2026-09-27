import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// Explicit cross-home copies retain a source hold until the target persistently closes copying.
/// Unknown outcomes never release the source merely because a lease or a network deadline elapsed.
public struct V2ResourceImportService:Sendable {
    let resources:V2ResourceService
    let resolve:V2ResourceStoreResolving
    let sources:V2ResourceImportSourceResolver
    let registry:V2ResourceStorageRegistry
    let transports:[V2StorageBinding:any V2UploadTransport]
    public init(resources:V2ResourceService,resolve:@escaping V2ResourceStoreResolving,sources:V2ResourceImportSourceResolver,
                registry:V2ResourceStorageRegistry,transports:[any V2UploadTransport]) {
        self.resources=resources;self.resolve=resolve;self.sources=sources;self.registry=registry
        self.transports=Dictionary(uniqueKeysWithValues:transports.map {($0.binding,$0)})
    }
    public func create(_ request:V2ResourceImportRequest,actor:UserID,device:DeviceID) async throws -> V2ResourceImportStatus {
        guard actor.uuidValue != nil, device.uuidValue != nil, request.operationID.uuidValue != nil, request.targetMediaID.uuidValue != nil, request.source.mediaID.uuidValue != nil else { throw V2ResourceProviderError.preconditionFailed }
        let home=request.targetUsage.home(actorUserID:actor)
        let locator=V2ResourceImportLocator(home:home,operationID:request.operationID)
        let store=try await resolve(home,request.targetUsage,actor,device)
        let json=try encode(request),homeJSON=try encode(home)
        try await store.database.transaction { transaction in
            try await store.authorize(transaction)
            guard let sql=transaction as? any SQLDatabase else { throw V2ResourceProviderError.configurationInvalid }
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: "resource-import:\(actor.rawValue):\(request.operationID.rawValue)"),0))").run()
            if let prior=try await load(locator,actor:actor,device:device,sql:sql) {
                guard try JSONDecoder().decode(V2ResourceImportRequest.self,from:Data(prior.requestText.utf8))==request else { throw V2MediaStoreError.idempotencyConflict }
            } else {
                try await sql.raw("""
                    INSERT INTO im_v2.resource_imports(actor_user_id,device_id,operation_id,home_json,request_json,target_media_id,created_at,updated_at)
                    VALUES(\(bind: actor.uuidValue!),\(bind: device.uuidValue!),\(bind: request.operationID.uuidValue!),\(bind: homeJSON)::jsonb,\(bind: json)::jsonb,\(bind: request.targetMediaID.uuidValue!),clock_timestamp(),clock_timestamp())
                    """).run()
            }
        }
        return try await resume(locator,actor:actor,device:device)
    }
    public func resume(_ locator:V2ResourceImportLocator,actor:UserID,device:DeviceID) async throws -> V2ResourceImportStatus {
        let (store,row,request)=try await context(locator,actor:actor,device:device)
        if row.state=="cancelled" || row.state=="failed" { return try outcome(row,locator:locator) }
        if let sessionText=row.sessionText {
            let session=try JSONDecoder().decode(V2ResourceUploadSession.self,from:Data(sessionText.utf8))
            let current=try await resources.status(session.locator,actor:actor,device:device)
            if current.state == .completed {
                let state = current.resourceState == .ready ? "ready" : (current.resourceState == .rejected || current.resourceState == .deletionPending ? "failed" : "processing")
                try await mark(store:store,locator:locator,actor:actor,state:state)
                try await releaseHold(request,actor:actor)
                return try .init(locator:locator,mediaID:request.targetMediaID,state:V2ResourceImportState(rawValue:state)!,
                    bindableUntil:current.resourceState == .ready ? current.bindableUntil : nil)
            }
            if [.cancelled,.expired,.failed].contains(current.state) {
                try await mark(store:store,locator:locator,actor:actor,state:"failed")
                try await releaseHold(request,actor:actor)
                return try .init(locator:locator,mediaID:request.targetMediaID,state:.failed,bindableUntil:nil)
            }
        }
        let source=try await sources.authorize(request.source,actor:actor,device:device)
        let facts=try await hold(request,actor:actor,database:source.database)
        try await source.recheck()
        let upload=try V2ResourceUploadRequest(operationID:.init(request.operationID.rawValue),mediaID:request.targetMediaID,usage:request.targetUsage,
            contentType:facts.contentType,byteCount:facts.facts.byteCount,checksum:.init(value:facts.facts.sha256.map {String(format:"%02x",$0)}.joined()),clientModes:[.httpPut])
        let session=try await resources.create(upload,actor:actor,device:device)
        let sessionJSON=try encode(session)
        try await store.database.transaction { transaction in
            try await store.authorize(transaction)
            guard let sql=transaction as? any SQLDatabase,
                  try await sql.raw("UPDATE im_v2.resource_imports SET session_json=\(bind: sessionJSON)::jsonb,state='copying',updated_at=clock_timestamp() WHERE actor_user_id=\(bind: actor.uuidValue!) AND operation_id=\(bind: locator.operationID.uuidValue!) AND state NOT IN ('cancelled','failed') RETURNING operation_id").first() != nil
            else { throw V2ResourceProviderError.preconditionFailed }
        }
        let target=try await store.status(session:session.locator.sessionID.uuidValue!,actor:actor.uuidValue!,device:device.uuidValue!)
        guard let transport=transports[target.placement.binding] else { throw V2ResourceProviderError.configurationInvalid }
        let bytes=try await registry.storage(for:facts.facts.reference.binding).read(facts.facts.reference)
        try await transport.importBytes(mediaID:request.targetMediaID,contentType:facts.contentType,byteCount:facts.facts.byteCount,bytes:bytes)
        try await source.recheck()
        let completed=try await resources.finalize(.init(locator:session.locator,generation:session.generation),actor:actor,device:device)
        try await mark(store:store,locator:locator,actor:actor,state:"processing")
        try await releaseHold(request,actor:actor)
        return try .init(locator:locator,mediaID:request.targetMediaID,state:completed.resourceState == .ready ? .ready : .processing,
            bindableUntil:completed.resourceState == .ready ? completed.bindableUntil : nil)
    }
    public func status(_ locator:V2ResourceImportLocator,actor:UserID,device:DeviceID) async throws -> V2ResourceImportStatus {
        let (_,row,request)=try await context(locator,actor:actor,device:device)
        guard let sessionText=row.sessionText,row.state != "cancelled",row.state != "failed" else { return try outcome(row,locator:locator) }
        let session=try JSONDecoder().decode(V2ResourceUploadSession.self,from:Data(sessionText.utf8))
        let current=try await resources.status(session.locator,actor:actor,device:device)
        return try .init(locator:locator,mediaID:request.targetMediaID,
            state:current.resourceState == .ready ? .ready : ([.cancelled,.expired,.failed].contains(current.state) ? .failed : .processing),
            bindableUntil:current.resourceState == .ready ? current.bindableUntil : nil)
    }
    public func cancel(_ locator:V2ResourceImportLocator,actor:UserID,device:DeviceID) async throws -> V2ResourceImportStatus {
        let (store,row,request)=try await context(locator,actor:actor,device:device)
        if let sessionText=row.sessionText {
            let session=try JSONDecoder().decode(V2ResourceUploadSession.self,from:Data(sessionText.utf8))
            _ = try await resources.cancel(.init(locator:session.locator,generation:session.generation),actor:actor,device:device)
        }
        // Persistent target closure is committed before releasing the source.
        try await mark(store:store,locator:locator,actor:actor,state:"cancelled")
        try await releaseHold(request,actor:actor)
        return try .init(locator:locator,mediaID:request.targetMediaID,state:.cancelled,bindableUntil:nil)
    }
    public func runOnce(database:any Database,limit:Int=16) async throws {
        guard (1...100).contains(limit),let sql=database as? any SQLDatabase else { throw V2ResourceProviderError.configurationInvalid }
        let rows=try await sql.raw("""
            SELECT actor_user_id,device_id,request_json::text AS request_text
            FROM im_v2.resource_imports WHERE state IN ('pending','copying','processing')
            ORDER BY updated_at,operation_id LIMIT \(bind: limit)
            """).all(decoding:ImportRecoveryRow.self)
        for row in rows {
            try Task.checkCancellation()
            let request=try JSONDecoder().decode(V2ResourceImportRequest.self,from:Data(row.requestText.utf8))
            let actor=UserID(uuid:row.actorUserID),device=DeviceID(uuid:row.deviceID)
            let locator=V2ResourceImportLocator(home:request.targetUsage.home(actorUserID:actor),operationID:request.operationID)
            do { _ = try await resume(locator,actor:actor,device:device) }
            catch {
                // A missing/partitioned source is not proof of target closure. Only close persisted
                // expired target sessions (or an unallocated import under the same row mutex).
                let terminal=try await sql.raw("""
                    UPDATE im_v2.resource_imports i SET state='failed',updated_at=clock_timestamp()
                    WHERE actor_user_id=\(bind: row.actorUserID) AND operation_id=\(bind: request.operationID.uuidValue!)
                      AND i.state IN ('pending','copying','processing')
                      AND ((i.session_json IS NULL AND i.created_at < clock_timestamp()-interval '24 hours')
                           OR EXISTS (SELECT 1 FROM im_v2.resource_upload_sessions s WHERE s.media_id=i.target_media_id AND s.state IN ('cancelled','expired','failed')))
                    RETURNING operation_id
                    """).first() != nil
                if terminal { try await releaseHold(request,actor:actor) }
                else {
                    try await sql.raw("UPDATE im_v2.resource_imports SET updated_at=clock_timestamp() WHERE actor_user_id=\(bind: row.actorUserID) AND operation_id=\(bind: request.operationID.uuidValue!) AND state IN ('pending','copying','processing')").run()
                }
            }
        }
    }
    private func context(_ locator:V2ResourceImportLocator,actor:UserID,device:DeviceID) async throws -> (PostgresV2ResourceLifecycleStore,ResourceImportRow,V2ResourceImportRequest) {
        guard actor.uuidValue != nil,device.uuidValue != nil,locator.operationID.uuidValue != nil else { throw V2ResourceProviderError.preconditionFailed }
        let store=try await resolve(locator.home,nil,actor,device)
        let row=try await store.database.transaction { transaction in
            try await store.authorize(transaction)
            guard let sql=transaction as? any SQLDatabase,let row=try await load(locator,actor:actor,device:device,sql:sql) else { throw V2MediaStoreError.uploadNotAuthorized }
            return row
        }
        let request=try JSONDecoder().decode(V2ResourceImportRequest.self,from:Data(row.requestText.utf8))
        guard request.targetUsage.home(actorUserID:actor)==locator.home else { throw V2MediaStoreError.uploadNotAuthorized }
        return (try await resolve(locator.home,request.targetUsage,actor,device),row,request)
    }
    private func load(_ locator:V2ResourceImportLocator,actor:UserID,device:DeviceID,sql:any SQLDatabase) async throws -> ResourceImportRow? {
        try await sql.raw("SELECT request_json::text AS request_text,session_json::text AS session_text,target_media_id,state FROM im_v2.resource_imports WHERE actor_user_id=\(bind: actor.uuidValue!) AND device_id=\(bind: device.uuidValue!) AND operation_id=\(bind: locator.operationID.uuidValue!)").first(decoding:ResourceImportRow.self)
    }
    private func mark(store:PostgresV2ResourceLifecycleStore,locator:V2ResourceImportLocator,actor:UserID,state:String) async throws {
        try await store.database.transaction { transaction in
            try await store.authorize(transaction)
            guard let sql=transaction as? any SQLDatabase else { throw V2ResourceProviderError.configurationInvalid }
            try await sql.raw("UPDATE im_v2.resource_imports SET state=\(bind: state),updated_at=clock_timestamp() WHERE actor_user_id=\(bind: actor.uuidValue!) AND operation_id=\(bind: locator.operationID.uuidValue!) AND state NOT IN ('cancelled','failed')").run()
        }
    }
    private func hold(_ request:V2ResourceImportRequest,actor:UserID,database:any Database) async throws -> ImportSourceFacts {
        try await database.transaction { transaction in
            guard let sql=transaction as? any SQLDatabase,
                  let media=try await sql.raw("SELECT content_type FROM im_v2.media_objects WHERE media_id=\(bind: request.source.mediaID.uuidValue!) AND state='available' FOR UPDATE").first(decoding:ImportContentType.self)
            else { throw V2ResourceProviderError.notFound }
            // The hold is the durable input of this operation. Resolving the current
            // placement again on retry could read bytes which this operation never held.
            if let previous = try await heldSource(request, actor: actor, sql: sql) { return previous }
            let variant:ResourceVariantID?
            switch request.source {case .message(_,_,let value):variant=value;case .avatar(_,_,let value):variant=value}
            let query:SQLQueryString
            if let variant {
                guard let variantID = variant.uuidValue else { throw V2ResourceProviderError.preconditionFailed }
                query="""
                    SELECT v.reference_json::text AS reference,v.byte_count,v.sha256
                    FROM im_v2.resource_variants v JOIN im_v2.resource_catalog c
                      ON c.media_id=v.media_id AND c.generation=v.generation
                    WHERE v.media_id=\(bind: request.source.mediaID.uuidValue!)
                      AND v.variant_id=\(bind: variantID) AND v.state='ready'
                    """
            } else {
                query="""
                    SELECT p.reference_json::text AS reference,p.byte_count,p.sha256
                    FROM im_v2.resource_blob_placements p JOIN im_v2.resource_catalog c
                      ON c.media_id=p.media_id AND c.generation=p.generation
                    WHERE p.media_id=\(bind: request.source.mediaID.uuidValue!) AND p.state='active'
                    """
            }
            guard let row=try await sql.raw(query).first(decoding:ImportSourceRow.self) else { throw V2ResourceProviderError.notFound }
            let json=try encode(request)
            try await sql.raw("""
                INSERT INTO im_v2.resource_import_holds(actor_user_id,operation_id,media_id,reference_json,
                    request_json,byte_count,sha256,content_type,created_at)
                VALUES(\(bind: actor.uuidValue!),\(bind: request.operationID.uuidValue!),\(bind: request.source.mediaID.uuidValue!),
                    \(bind: row.reference)::jsonb,\(bind: json)::jsonb,\(bind: row.byteCount),\(bind: row.sha256),
                    \(bind: variant == nil ? media.contentType : "image/png"),clock_timestamp()) ON CONFLICT DO NOTHING
                """).run()
            guard let held = try await heldSource(request, actor: actor, sql: sql)
            else { throw V2ResourceProviderError.preconditionFailed }
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
    private func releaseHold(_ request:V2ResourceImportRequest,actor:UserID) async throws {
        guard let sql=try await sources.database(for:request.source) as? any SQLDatabase else { throw V2ResourceProviderError.configurationInvalid }
        try await sql.raw("UPDATE im_v2.resource_import_holds SET released_at=clock_timestamp() WHERE actor_user_id=\(bind: actor.uuidValue!) AND operation_id=\(bind: request.operationID.uuidValue!) AND released_at IS NULL").run()
    }
    private func outcome(_ row:ResourceImportRow,locator:V2ResourceImportLocator) throws -> V2ResourceImportStatus {
        try .init(locator:locator,mediaID:.init(uuid:row.targetMediaID),state:V2ResourceImportState(rawValue:row.state) ?? .failed,bindableUntil:nil)
    }
    private func encode<T:Encodable>(_ value:T) throws -> String { String(decoding:try JSONEncoder().encode(value),as:UTF8.self) }
}
private struct ResourceImportRow:Decodable {
    let requestText:String;let sessionText:String?;let targetMediaID:UUID;let state:String
    enum CodingKeys:String,CodingKey {case requestText="request_text",sessionText="session_text",targetMediaID="target_media_id",state}
}
private struct ImportContentType:Decodable {let contentType:String;enum CodingKeys:String,CodingKey {case contentType="content_type"}}
private struct ImportSourceFacts {let contentType:String;let facts:V2StoredObjectFacts}
private struct ImportSourceRow:Decodable {let reference:String;let byteCount:Int64;let sha256:Data;enum CodingKeys:String,CodingKey{case reference,byteCount="byte_count",sha256}}
private struct ImportHoldRow: Decodable {
    let requestText: String; let reference: String; let byteCount: Int64; let sha256: Data
    let contentType: String; let releasedAt: Date?
    enum CodingKeys: String, CodingKey {
        case requestText="request_text",reference,byteCount="byte_count",sha256,contentType="content_type",releasedAt="released_at"
    }
}

private struct ImportRecoveryRow:Decodable {
    let actorUserID:UUID;let deviceID:UUID;let requestText:String
    enum CodingKeys:String,CodingKey {case actorUserID="actor_user_id",deviceID="device_id",requestText="request_text"}
}
