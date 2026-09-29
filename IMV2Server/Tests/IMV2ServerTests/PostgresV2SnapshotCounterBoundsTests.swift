@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import FluentPostgresDriver
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

@Suite("Snapshot artifact counter boundaries", .serialized)
struct PostgresV2SnapshotCounterBoundsTests {
    @Test("canonical bounds allow the last page and reject the next without stranding reset state",
          arguments: ["item_count", "total_bytes", "next_page_index"], [false, true])
    func counterLimit(field: String, alreadyAtLimit: Bool) async throws {
        try await withUserEventDatabase { database, sql, schema in
            let user = UUID(), device = UUID(), snapshot = UUID(), source = UUID()
            let now = Date(timeIntervalSince1970: 1_750_000_000), expiry = now.addingTimeInterval(600)
            let payload = try #require(try await sql.raw("SELECT '{\"state\":\"accepted\"}'::jsonb::text AS value").first(decoding: CounterText.self)).value
            let item = try V2SnapshotProjectionItem(key: .init(projectionKind: "relationship", entityKey: "target"),
                sourceEventID: .init(uuid: source), sequence: 1, payload: Data(payload.utf8))
            let page = try V2SnapshotProjectionV3Page(items: [item])
            let bytes = try V2SnapshotProjectionV3Codec.encode(page).count
            let maximum: Int64 = field == "item_count" ? Int64(V2SnapshotProjectionV3Codec.maximumTotalItems)
                : field == "total_bytes" ? Int64(V2SnapshotProjectionV3Codec.maximumTotalBytes)
                : Int64(V2SnapshotProjectionV3Codec.maximumPageCount)
            let increment: Int64 = field == "total_bytes" ? Int64(bytes) : 1
            let initial = alreadyAtLimit ? maximum : maximum - increment
            try await sql.raw("INSERT INTO \(unsafeRaw: schema).user_projection_checkpoints(user_id,projected_sequence,updated_at) VALUES (\(bind: user),1,\(bind: now))").run()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).user_projection_versions
                    (user_id,projection_kind,entity_key,valid_from_sequence,source_event_id,payload,created_at)
                VALUES (\(bind: user),'relationship','target',1,\(bind: source),\(bind: payload)::jsonb,\(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).sync_snapshot_artifacts
                    (snapshot_id,user_id,base_user_sync_sequence,source_projected_sequence,schema_version,capability_profile,state,rolling_digest,expires_at,created_at)
                VALUES (\(bind: snapshot),\(bind: user),1,1,30,'base','building',
                    \(bind: V2SnapshotV3Digest.initial(baseSequence: 1, capabilityProfile: "base")),\(bind: expiry),\(bind: now))
                """).run()
            try await sql.raw("UPDATE \(unsafeRaw: schema).sync_snapshot_artifacts SET \(unsafeRaw: field) = \(bind: initial) WHERE snapshot_id = \(bind: snapshot)").run()
            // These real constraints are part of the arithmetic safety proof.
            for invalid in [Int64(-1), maximum + 1, Int64.max] {
                await #expect(throws: PSQLError.self) {
                    try await sql.raw("UPDATE \(unsafeRaw: schema).sync_snapshot_artifacts SET \(unsafeRaw: field) = \(bind: invalid) WHERE snapshot_id = \(bind: snapshot)").run()
                }
            }
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).device_snapshot_resets
                    (user_id,device_id,reset_generation,snapshot_id,state,next_sync_token,snapshot_receipt,expires_at,created_at)
                VALUES (\(bind: user),\(bind: device),2,\(bind: snapshot),'preparing','pending-token','receipt',\(bind: expiry),\(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).device_sync_cursors
                    (user_id,device_id,state,reset_generation,pending_snapshot_id,pending_base_sequence,pending_snapshot_expires_at)
                VALUES (\(bind: user),\(bind: device),'reset_preparing',2,\(bind: snapshot),1,\(bind: expiry))
                """).run()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).sync_tokens(token,user_id,device_id,reset_generation,watermark,expires_at,created_at)
                VALUES ('pending-token',\(bind: user),\(bind: device),2,1,\(bind: expiry),\(bind: now))
                """).run()
            let builder = PostgresV2SnapshotArtifactBuilder(database: database, schema: schema, pageItemLimit: 1, maximumCandidateItems: 1)
            let report = try await builder.runOnce(now: now)
            #expect(report.claimed && !report.published)
            let result = try #require(try await sql.raw("""
                SELECT state, failure_code AS code, \(unsafeRaw: field)::bigint AS value,
                       lease_token IS NULL AND lease_expires_at IS NULL AS released
                FROM \(unsafeRaw: schema).sync_snapshot_artifacts WHERE snapshot_id = \(bind: snapshot)
                """).first(decoding: CounterArtifact.self))
            #expect(result.value == maximum && result.released)
            #expect(result.state == (alreadyAtLimit ? "failed" : "building"))
            #expect(result.code == (alreadyAtLimit ? "snapshot_too_large" : nil))
            let pages = try #require(try await sql.raw("SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).sync_snapshot_pages").first(decoding: CounterValue.self)).value
            #expect(pages == (alreadyAtLimit ? 0 : 1))
            let cursor = try #require(try await sql.raw("SELECT state,reset_generation AS generation,pending_snapshot_id AS pending FROM \(unsafeRaw: schema).device_sync_cursors").first(decoding: CounterCursor.self))
            #expect(cursor.state == (alreadyAtLimit ? "ready" : "reset_preparing"))
            #expect(cursor.generation == (alreadyAtLimit ? 1 : 2))
            #expect(cursor.pending == (alreadyAtLimit ? nil : snapshot))
            for table in ["sync_tokens", "device_snapshot_resets"] {
                let count = try #require(try await sql.raw("SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).\(unsafeRaw: table)").first(decoding: CounterValue.self)).value
                #expect(count == (alreadyAtLimit ? 0 : 1))
            }
        }
    }
}

private struct CounterText: Decodable { let value: String }
private struct CounterValue: Decodable { let value: Int64 }
private struct CounterArtifact: Decodable { let state: String; let code: String?; let value: Int64; let released: Bool }
private struct CounterCursor: Decodable { let state: String; let generation: Int64; let pending: UUID? }
