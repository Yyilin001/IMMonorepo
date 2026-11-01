import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2ServerApplication
import IMV2ServerContracts
import IMV2ServerInfrastructure
import SQLKit
import Testing

struct V2SendCompletionCapacityTests {
    @Test(arguments: [false, true])
    func aggregateCapacityPreservesUnknownEstimatesAndMissingOwners(unknown: Bool) async {
        let first = V2DurableWorkMetricsSnapshot(isAvailable: true, sendCompletionStorage: .init(
            estimatedRows: 10, heapBytes: 1_000, indexBytes: 200, totalBytes: 1_300))
        let second = V2DurableWorkMetricsSnapshot(isAvailable: true, sendCompletionStorage: .init(
            estimatedRows: unknown ? nil : 20, heapBytes: 2_000, indexBytes: 400, totalBytes: 2_600))
        let aggregate = V2AggregateDurableWorkMetricsSource(sources: [CapacitySource(first), CapacitySource(second),
            CapacitySource(.init(isAvailable: true))])
        let result = await aggregate.durableWorkMetricsSnapshot()
        #expect(result.isAvailable)
        #expect(result.sendCompletionStorage == .init(estimatedRows: unknown ? nil : 30,
            heapBytes: 3_000, indexBytes: 600, totalBytes: 3_900))
        let rendered = v2RenderPrometheusDurableWorkMetrics(result)
        #expect(rendered.contains("im_v2_send_completions_estimate_available \(unknown ? 0 : 1)\n"))
        #expect(rendered.contains("im_v2_send_completions_relation_bytes{component=\"total\"} 3900\n"))
        #expect(rendered.contains("im_v2_send_completions_estimated_rows 30\n") == !unknown)
        #expect(!rendered.contains("owner_id") && !rendered.contains("room_id") && !rendered.contains("user_id"))
        let failed = await V2AggregateDurableWorkMetricsSource(sources: [CapacitySource(first),
            CapacitySource(.unavailable)]).durableWorkMetricsSnapshot()
        #expect(!failed.isAvailable && failed.sendCompletionStorage == nil)
        #expect(!v2RenderPrometheusDurableWorkMetrics(failed).contains("im_v2_send_completions_relation_bytes"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil))
    func postgresCatalogCapacityIsReadOnlyAndRejectsMissingTable() async throws {
        let resources = makeV2DatabaseTestResources()
        resources.databases.use(try .postgres(url: #require(ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"])),
                                as: .psql, isDefault: true)
        let database = resources.database(.psql)
        let sql = try #require(database as? any SQLDatabase)
        let schema = "capacity_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        do {
            try await sql.raw("CREATE SCHEMA \(unsafeRaw: schema)").run()
            try await sql.raw("CREATE TABLE \(unsafeRaw: schema).message_send_completions (LIKE im_v2.message_send_completions INCLUDING ALL)").run()
            let source = PostgresV2SendCompletionMetricsSource(database: database, schema: schema)
            let empty = try #require(try await source.loadDurableWorkMetrics().sendCompletionStorage)
            #expect(empty.estimatedRows == nil && empty.heapBytes == 0)
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).message_send_completions
                    (room_id,sender_user_id,client_message_id,fingerprint_version,request_fingerprint,
                     message_id,event_id,room_sequence,timeline_sequence,accepted_membership_revision,created_at)
                SELECT md5('room')::uuid,md5('sender')::uuid,md5(i::text)::uuid,3,decode(repeat('ab',32),'hex'),
                       md5('message'||i)::uuid,md5('event'||i)::uuid,i,i,1,clock_timestamp()
                FROM generate_series(1,128) i
                """).run()
            try await sql.raw("ANALYZE \(unsafeRaw: schema).message_send_completions").run()
            let value = try await database.transaction { transaction in
                let readonly = try #require(transaction as? any SQLDatabase)
                try await readonly.raw("SET TRANSACTION READ ONLY").run()
                return try await PostgresV2SendCompletionMetricsSource(database: transaction, schema: schema).loadDurableWorkMetrics()
            }
            let measured = try #require(value.sendCompletionStorage)
            #expect(measured.estimatedRows == 128)
            #expect(measured.heapBytes > 0 && measured.indexBytes > 0)
            #expect(measured.totalBytes >= measured.heapBytes + measured.indexBytes)
            #expect(!v2RenderPrometheusDurableWorkMetrics(value).contains(schema))
            try await sql.raw("ALTER TABLE \(unsafeRaw: schema).message_send_completions RENAME TO absent_completion").run()
            let missing = await source.durableWorkMetricsSnapshot()
            #expect(!missing.isAvailable && missing.sendCompletionStorage == nil)
            try await sql.raw("DROP SCHEMA \(unsafeRaw: schema) CASCADE").run()
            try await resources.shutdown()
        } catch {
            try? await sql.raw("DROP SCHEMA IF EXISTS \(unsafeRaw: schema) CASCADE").run()
            try? await resources.shutdown()
            throw error
        }
    }
}

private struct CapacitySource: V2DurableWorkMetricsSource {
    let value: V2DurableWorkMetricsSnapshot
    init(_ value: V2DurableWorkMetricsSnapshot) { self.value = value }
    func durableWorkMetricsSnapshot() async -> V2DurableWorkMetricsSnapshot { value }
}
