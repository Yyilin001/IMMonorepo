import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// Called only after profile/group authorization and final authority rechecks.
/// Grants are signed in memory. The persistent row is an immutable variant, not a viewer grant.
public struct V2ResourceAvatarDelivery:Sendable {
    private let delivery:any V2ResourceDelivery
    public init(delivery:any V2ResourceDelivery) { self.delivery=delivery }
    public func authorizedAvatar(mediaID:MediaID,database:any Database,expiresAt:Date) async throws -> V2ResourceAvatarAccess {
        guard let result = try await authorizedAvatars(requests: [mediaID: expiresAt], database: database)[mediaID]
        else { throw V2ResourceProviderError.notFound }
        return result
    }
    public func authorizedAvatars(requests:[MediaID:Date],database:any Database) async throws -> [MediaID:V2ResourceAvatarAccess] {
        guard requests.count <= 100, let sql=database as? any SQLDatabase else { throw V2ResourceProviderError.configurationInvalid }
        guard !requests.isEmpty else { return [:] }
        let ids = try requests.keys.map { key -> UUID in
            guard let id = key.uuidValue else { throw V2ResourceProviderError.preconditionFailed }; return id
        }
        let json = String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)
        let rows = try await sql.raw("""
            SELECT v.media_id,v.variant_id,v.reference_json::text AS reference,v.byte_count,v.sha256,v.recipe_version
            FROM jsonb_array_elements_text(\(bind: json)::jsonb) requested(media_id)
            JOIN im_v2.resource_variants v ON v.media_id=requested.media_id::uuid
            JOIN im_v2.media_objects m ON m.media_id=v.media_id
            JOIN im_v2.resource_catalog resource ON resource.media_id=m.media_id AND resource.generation=v.generation
            WHERE v.recipe='avatar' AND v.recipe_version=1 AND v.size=128 AND v.state='ready'
              AND m.state='available' AND resource.usage_kind IN ('user_avatar','group_avatar')
            """).all(decoding:AvatarDeliveryRow.self)
        var result:[MediaID:V2ResourceAvatarAccess]=[:]
        for row in rows {
            let mediaID=MediaID(uuid:row.mediaID)
            guard let expiresAt=requests[mediaID] else { continue }
            let reference=try JSONDecoder().decode(V2StoredObjectReference.self,from:Data(row.reference.utf8))
            let facts=try V2StoredObjectFacts(reference:reference,byteCount:row.byteCount,sha256:row.sha256)
            let plan: V2ResourceTransferPlan?
            do {
                let issued = try await delivery.issue(.init(facts: facts, expiresAt: expiresAt))
                try issued.validateDownload(facts: facts, expiresAt: expiresAt)
                plan = issued
            } catch is CancellationError { throw CancellationError() }
            catch { plan = nil } // Valid content survives a transient signing failure.
            try Task.checkCancellation()
            result[mediaID]=try .init(mediaID:mediaID,variantID:.init(uuid:row.variantID),version:Int64(row.recipeVersion),
                checksum:.init(value:row.sha256.map { String(format:"%02x",$0) }.joined()),byteCount:row.byteCount,plan:plan)
        }
        return result
    }
}
private struct AvatarDeliveryRow:Decodable {
    let mediaID:UUID;let variantID:UUID;let reference:String;let byteCount:Int64;let sha256:Data;let recipeVersion:Int
    enum CodingKeys:String,CodingKey { case mediaID="media_id",variantID="variant_id",reference,byteCount="byte_count",sha256,recipeVersion="recipe_version" }
}
