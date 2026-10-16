import Foundation
import FluentKit
import SQLKit

public enum V2RealtimeJournalSchemaReadinessError: Error, Equatable, Sendable {
    case invalidSchema, unsupportedDatabase, unavailableContract
}

/// Read-only readiness for a source database. Does not install migrations or
/// infer a deployment identity from a connection URL or process incarnation.
public enum V2RealtimeJournalSchemaReadiness {
    public static func verify(database: any Database, schema: String = "im_v2") async throws {
        guard schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
            throw V2RealtimeJournalSchemaReadinessError.invalidSchema
        }
        guard let sql = database as? any SQLDatabase else { throw V2RealtimeJournalSchemaReadinessError.unsupportedDatabase }
        struct Ready: Decodable { let ready: Bool }
        guard let row = try await sql.raw("""
            SELECT to_regclass(\(bind: schema) || '.room_event_wake_outbox') IS NULL AND NOT EXISTS (
                SELECT 1 FROM (VALUES
                    ('realtime_journal_source_identity','singleton','bool','NO'),
                    ('realtime_journal_source_identity','source_id','uuid','NO'),
                    ('realtime_journal_source_identity','database_incarnation','uuid','NO'),
                    ('realtime_journal_publisher_leases','partition_id','int4','NO'),
                    ('realtime_journal_publisher_leases','lease_epoch','int8','NO'),
                    ('realtime_journal_publisher_leases','lease_token','uuid','YES'),
                    ('realtime_journal_publisher_leases','expires_at','timestamptz','NO'),
                    ('realtime_journal_partitions','published_through','int8','NO'),
                    ('realtime_journal_partitions','trimmed_through','int8','NO'),
                    ('realtime_change_outbox','source_event_id','uuid','NO'),
                    ('realtime_change_outbox','room_control_version','int8','YES'),
                    ('realtime_change_outbox','user_control_version','int8','YES'),
                    ('realtime_change_outbox','owner_epoch','int8','YES'),
                    ('realtime_change_outbox','membership_room_id','uuid','YES'),
                    ('realtime_change_journal','sequence','int8','NO'),
                    ('realtime_change_journal','owner_epoch','int8','YES'),
                    ('realtime_change_journal','membership_room_id','uuid','YES'),
                    ('realtime_control_publication_floors','published_version','int8','NO'),
                    ('realtime_control_versions','version','int8','NO'),
                    ('realtime_dirty_room_heads','room_sequence','int8','NO'),
                    ('realtime_dirty_room_heads','room_control_version','int8','NO'),
                    ('realtime_dirty_room_heads','owner_epoch','int8','NO'),
                    ('realtime_dirty_room_heads','revision','int8','NO'),
                    ('realtime_dirty_room_heads','pending','bool','NO'),
                    ('realtime_control_versions','membership_discovery_version','int8','NO'),
                    ('realtime_control_versions','session_control_version','int8','NO'),
                    ('realtime_device_control_versions','latest_change_version','int8','NO')
                ) expected(table_name,column_name,udt_name,is_nullable)
                WHERE NOT EXISTS(SELECT 1 FROM information_schema.columns actual
                    WHERE actual.table_schema=\(bind: schema) AND actual.table_name=expected.table_name
                      AND actual.column_name=expected.column_name AND actual.udt_name=expected.udt_name
                      AND actual.is_nullable=expected.is_nullable)
            ) AND NOT EXISTS (
                SELECT 1 FROM (VALUES('rooms',29,'capture_realtime_change'),('room_memberships',29,'capture_realtime_change'),
                    ('room_events',4,'capture_realtime_room_events_heads'),('messages',4,'capture_realtime_messages_heads'),
                    ('auth_devices',29,'capture_realtime_change'),('device_refresh_sessions',29,'capture_realtime_change')) expected(table_name,trigger_type,function_name)
                WHERE NOT EXISTS(SELECT 1 FROM pg_trigger t JOIN pg_class r ON r.oid=t.tgrelid
                    JOIN pg_namespace n ON n.oid=r.relnamespace JOIN pg_proc p ON p.oid=t.tgfoid
                    WHERE n.nspname=\(bind: schema) AND r.relname=expected.table_name
                      AND t.tgname='realtime_journal_capture' AND t.tgtype=expected.trigger_type AND t.tgenabled IN('O','A')
                      AND NOT t.tgisinternal AND p.pronamespace=n.oid AND p.proname=expected.function_name
                      AND (expected.trigger_type<>4 OR t.tgnewtable='new_realtime_rows'))
            ) AND NOT EXISTS (
                SELECT 1 FROM (VALUES('realtime_change_outbox_partition_idx'),('realtime_change_outbox_topic_idx'),
                    ('realtime_dirty_room_heads_pending_idx')) expected(index_name)
                WHERE NOT EXISTS(SELECT 1 FROM pg_class r JOIN pg_namespace n ON n.oid=r.relnamespace
                    JOIN pg_index i ON i.indexrelid=r.oid WHERE n.nspname=\(bind: schema)
                    AND r.relname=expected.index_name AND i.indisvalid AND i.indisready)
            ) AND NOT EXISTS (
                SELECT 1 FROM (VALUES
                    ('realtime_journal_source_identity','singleton','p'),
                    ('realtime_journal_publisher_leases','partition_id','p'),
                    ('realtime_journal_partitions','partition_id','p'),
                    ('realtime_change_outbox','source_event_id','p'),
                    ('realtime_change_journal','partition_id,sequence','p'),
                    ('realtime_change_journal','source_event_id','u'),
                    ('realtime_control_publication_floors','topic_kind,topic_id','p'),
                    ('realtime_control_versions','topic_kind,topic_id','p'),
                    ('realtime_dirty_room_heads','room_id','p'),
                    ('realtime_device_control_versions','user_id,device_id','p')
                ) expected(table_name,key_columns,constraint_type)
                WHERE NOT EXISTS(SELECT 1 FROM pg_constraint c JOIN pg_class r ON r.oid=c.conrelid
                    JOIN pg_namespace n ON n.oid=r.relnamespace
                    WHERE n.nspname=\(bind: schema) AND r.relname=expected.table_name
                      AND c.contype::text=expected.constraint_type AND c.convalidated AND NOT c.condeferrable
                      AND (SELECT string_agg(a.attname,',' ORDER BY k.position)
                           FROM unnest(c.conkey) WITH ORDINALITY k(attnum,position)
                           JOIN pg_attribute a ON a.attrelid=c.conrelid AND a.attnum=k.attnum)=expected.key_columns)
            ) AS ready
            """).first(decoding: Ready.self), row.ready else {
            throw V2RealtimeJournalSchemaReadinessError.unavailableContract
        }
        // Exact normalized source hashes cover control-only dirty UPSERT,
        // monotonic H, current owner/control version and revision++/pending=true.
        // Mere function/trigger existence cannot establish those CAS semantics.
        guard let functions = try await sql.raw("""
            SELECT NOT EXISTS(SELECT 1 FROM (VALUES
                    ('realtime_topic_partition','77a3422e4f7dcd0100366a6c4b850dc7'),
                    ('capture_realtime_room_events_heads','77ab90c14e37f5c1e45fc77e4c956ad5'),
                    ('capture_realtime_messages_heads','932e8761ec89980ce1894e150e0d823f'),
                    ('capture_realtime_change','9ac9e0b999285c37e8d169a676c33cfb')
                ) expected(function_name,source_hash)
                WHERE NOT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                    WHERE n.nspname=\(bind: schema) AND p.proname=expected.function_name
                      AND md5(replace(p.prosrc,\(bind: schema),'im_v2'))=expected.source_hash)) AS ready
            """).first(decoding: Ready.self), functions.ready else {
            throw V2RealtimeJournalSchemaReadinessError.unavailableContract
        }

    }
}
