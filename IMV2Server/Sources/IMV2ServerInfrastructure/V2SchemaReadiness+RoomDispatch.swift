import FluentKit
import SQLKit

extension V2SchemaReadiness {
    static func verifyRoomDispatch(sql: any SQLDatabase, schema: String) async throws {
        guard try await sql.raw("""
            SELECT (
            NOT EXISTS (SELECT 1 FROM (VALUES ('source_event_id','uuid','NO'),
            ('room_id','uuid','NO'),
            ('room_sequence','int8','NO'),
            ('membership_revision','int8','NO'),
            ('created_at','timestamptz','NO'),
            ('next_attempt_at','timestamptz','NO'),
            ('claim_token','uuid','YES'),
            ('lease_expires_at','timestamptz','YES'),
            ('attempt','int4','NO'),
            ('message_id','uuid','YES'),
            ('sender_user_id','uuid','YES'),
            ('mentioned_user_ids','_uuid','NO'),
            ('mentions_everyone','bool','NO'),
            ('recipient_cursor','uuid','YES')) AS required(name,type,nullable)
                WHERE NOT EXISTS (SELECT 1 FROM information_schema.columns c
                    WHERE c.table_schema=\(bind: schema) AND c.table_name='room_dispatch_outbox' AND c.column_name=required.name
                      AND c.udt_name=required.type AND c.is_nullable=required.nullable))
            AND NOT EXISTS (SELECT 1 FROM (VALUES ('CHECK ((room_sequence > 0))'),('CHECK ((membership_revision >= 0))'),('CHECK ((attempt >= 0))'),('CHECK (isfinite(created_at))'),('CHECK (isfinite(next_attempt_at))'),('CHECK (((claim_token IS NULL) = (lease_expires_at IS NULL)))'),('PRIMARY KEY (source_event_id)'),('UNIQUE (message_id)'),('CHECK (((message_id IS NULL) OR (sender_user_id IS NOT NULL)))'),('CHECK (((lease_expires_at IS NULL) OR isfinite(lease_expires_at)))')) AS required(definition)
                WHERE NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conrelid=to_regclass(\(bind: schema + ".room_dispatch_outbox"))
                    AND c.convalidated AND NOT c.condeferrable AND pg_get_constraintdef(c.oid)=required.definition
                    AND (c.contype='c' OR EXISTS (SELECT 1 FROM pg_index i WHERE i.indexrelid=c.conindid AND i.indisvalid AND i.indisready))))
            AND NOT EXISTS (SELECT 1 FROM (VALUES ('source_event_id','uuid','NO'),
            ('room_id','uuid','NO'),
            ('room_sequence','int8','NO'),
            ('membership_revision','int8','NO'),
            ('created_at','timestamptz','NO'),
            ('next_attempt_at','timestamptz','NO'),
            ('claim_token','uuid','YES'),
            ('lease_expires_at','timestamptz','YES'),
            ('attempt','int4','NO'),
            ('user_id','uuid','NO'),
            ('message_id','uuid','NO'),
            ('sender_user_id','uuid','NO'),
            ('is_mention','bool','NO')) AS required(name,type,nullable)
                WHERE NOT EXISTS (SELECT 1 FROM information_schema.columns c
                    WHERE c.table_schema=\(bind: schema) AND c.table_name='account_notification_outbox' AND c.column_name=required.name
                      AND c.udt_name=required.type AND c.is_nullable=required.nullable))
            AND NOT EXISTS (SELECT 1 FROM (VALUES ('CHECK ((room_sequence > 0))'),('CHECK ((membership_revision >= 0))'),('CHECK ((attempt >= 0))'),('CHECK (isfinite(created_at))'),('CHECK (isfinite(next_attempt_at))'),('CHECK (((claim_token IS NULL) = (lease_expires_at IS NULL)))'),('PRIMARY KEY (user_id, source_event_id)'),('CHECK ((user_id <> sender_user_id))'),('CHECK (isfinite(lease_expires_at))')) AS required(definition)
                WHERE NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conrelid=to_regclass(\(bind: schema + ".account_notification_outbox"))
                    AND c.convalidated AND NOT c.condeferrable AND pg_get_constraintdef(c.oid)=required.definition
                    AND (c.contype='c' OR EXISTS (SELECT 1 FROM pg_index i WHERE i.indexrelid=c.conindid AND i.indisvalid AND i.indisready))))
            AND EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid=to_regclass(\(bind: schema + ".room_dispatch_outbox"))
                AND i.indexrelid=to_regclass(\(bind: schema + ".room_dispatch_due_idx")) AND i.indisvalid AND i.indisready AND i.indpred IS NULL
                AND pg_get_indexdef(i.indexrelid) LIKE '%USING btree (next_attempt_at, created_at, source_event_id)')
            AND EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid=to_regclass(\(bind: schema + ".room_dispatch_outbox"))
                AND i.indexrelid=to_regclass(\(bind: schema + ".room_dispatch_room_idx")) AND i.indisvalid AND i.indisready AND i.indpred IS NULL
                AND pg_get_indexdef(i.indexrelid) LIKE '%USING btree (room_id, membership_revision, room_sequence)')
            AND EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid=to_regclass(\(bind: schema + ".account_notification_outbox"))
                AND i.indexrelid=to_regclass(\(bind: schema + ".account_notification_outbox_due_idx")) AND i.indisvalid AND i.indisready AND i.indpred IS NULL
                AND pg_get_indexdef(i.indexrelid) LIKE '%USING btree (next_attempt_at, created_at, user_id, source_event_id)')
            AND EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid=to_regclass(\(bind: schema + ".account_notification_outbox"))
                AND i.indexrelid=to_regclass(\(bind: schema + ".account_notification_outbox_room_idx")) AND i.indisvalid AND i.indisready AND i.indpred IS NULL
                AND pg_get_indexdef(i.indexrelid) LIKE '%USING btree (user_id, room_id, room_sequence)')
            AND EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid=to_regclass(\(bind: schema + ".account_notification_outbox"))
                AND i.indexrelid=to_regclass(\(bind: schema + ".account_notification_outbox_expiry_idx")) AND i.indisvalid AND i.indisready AND i.indpred IS NULL
                AND pg_get_indexdef(i.indexrelid) LIKE '%USING btree (created_at, user_id, source_event_id)')
            AND EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid
                WHERE t.tgrelid=to_regclass(\(bind: schema + ".room_events")) AND t.tgname='room_events_account_dispatch'
                  AND t.tgenabled='O' AND NOT t.tgisinternal AND t.tgtype=4 AND t.tgqual IS NULL
                  AND t.tgnewtable='inserted_room_changes' AND p.pronamespace=to_regnamespace(\(bind: schema))
                  AND p.proname='enqueue_room_change_dispatch' AND NOT p.prosecdef
                  AND regexp_replace(replace(p.prosrc, \(bind: schema + "."), 'im_v2.'), '[[:space:]]', '', 'g')='BEGININSERTINTOim_v2.room_dispatch_outbox(source_event_id,room_id,room_sequence,membership_revision,sender_user_id,created_at,next_attempt_at)SELECTevent_id,room_id,room_sequence,committed_membership_revision,actor_user_id,created_at,created_atFROMinserted_room_changesWHEREevent_type<>''message.accepted'';RETURNNULL;END;')
            AND EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conrelid=to_regclass(\(bind: schema + ".user_state_event_outbox"))
                AND c.contype='c' AND c.convalidated AND pg_get_constraintdef(c.oid) LIKE '%room_head%')
            AND EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conrelid=to_regclass(\(bind: schema + ".user_state_event_receipts"))
                AND c.contype='c' AND c.convalidated AND pg_get_constraintdef(c.oid) LIKE '%room_head%')
            ) AS ready
            """).first(decoding: RoomDispatchReadyRow.self)?.ready == true else {
            throw V2SchemaReadinessError.unavailableTable("\(schema).room_dispatch[contract]")
        }
    }
}
private struct RoomDispatchReadyRow: Decodable { let ready: Bool }
