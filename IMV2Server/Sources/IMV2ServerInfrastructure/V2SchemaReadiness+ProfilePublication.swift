import SQLKit

extension V2SchemaReadiness {
    static func verifyProfilePublication(sql: any SQLDatabase, schema: String) async throws {
        struct Row: Decodable { let valid: Bool }
        guard let row = try await sql.raw("""
            SELECT (
                (SELECT array_agg(attname::text ORDER BY attnum) = ARRAY['publication_sequence','source_event_id','source_user_id','revision','created_at']
                    FROM pg_attribute WHERE attrelid=to_regclass(\(bind: schema + ".public_profile_update_outbox")) AND attnum>0 AND NOT attisdropped)
                AND (SELECT count(*)=5 FROM pg_attribute WHERE attrelid=to_regclass(\(bind: schema + ".public_profile_update_outbox"))
                    AND attnum>0 AND NOT attisdropped AND attnotnull
                    AND ((attname IN ('publication_sequence','revision') AND atttypid='bigint'::regtype)
                      OR (attname IN ('source_event_id','source_user_id') AND atttypid='uuid'::regtype)
                      OR (attname='created_at' AND atttypid='timestamptz'::regtype)))
                AND (SELECT count(*)=8 FROM pg_constraint WHERE conrelid=to_regclass(\(bind: schema + ".profile_security_invalidation_outbox"))
                    AND convalidated AND NOT condeferrable AND pg_get_constraintdef(oid) IN
                    ('PRIMARY KEY (source_event_id)','CHECK ((revision > 0))','CHECK ((retry_count >= 0))',
                     'CHECK ((profile_state = ANY (ARRAY[''deleted''::text, ''suspended''::text, ''hidden''::text])))',
                     'CHECK ((state = ANY (ARRAY[''pending''::text, ''claimed''::text, ''completed''::text])))',
                     'CHECK (((state = ''claimed''::text) = (claim_token IS NOT NULL)))',
                     'CHECK (((state = ''claimed''::text) = (lease_expires_at IS NOT NULL)))',
                     'CHECK (((state = ''completed''::text) = (completed_at IS NOT NULL)))'))
                AND (SELECT array_agg(attname::text ORDER BY attnum) = ARRAY['source_event_id','source_user_id','revision','profile_state','profile_updated_at','state','claim_token','lease_expires_at','enumeration_checkpoint','retry_count','created_at','completed_at']
                    FROM pg_attribute WHERE attrelid=to_regclass(\(bind: schema + ".profile_security_invalidation_outbox")) AND attnum>0 AND NOT attisdropped)
                AND (SELECT count(*)=12 FROM pg_attribute WHERE attrelid=to_regclass(\(bind: schema + ".profile_security_invalidation_outbox"))
                    AND attnum>0 AND NOT attisdropped
                    AND attnotnull = (attname IN ('source_event_id','source_user_id','revision','profile_state','profile_updated_at','state','retry_count','created_at'))
                    AND ((attname IN ('source_event_id','source_user_id','claim_token','enumeration_checkpoint') AND atttypid='uuid'::regtype)
                      OR (attname IN ('revision','retry_count') AND atttypid='bigint'::regtype)
                      OR (attname IN ('profile_state','state') AND atttypid='text'::regtype)
                      OR (attname IN ('profile_updated_at','lease_expires_at','created_at','completed_at') AND atttypid='timestamptz'::regtype)))
                AND (SELECT count(*)=2 FROM pg_index WHERE indrelid=to_regclass(\(bind: schema + ".profile_security_invalidation_outbox"))
                    AND indisvalid AND indisready AND replace(pg_get_indexdef(indexrelid),\(bind: schema + "."),'im_v2.') IN
                      ('CREATE INDEX profile_security_invalidation_claim_idx ON im_v2.profile_security_invalidation_outbox USING btree (state, lease_expires_at, created_at) WHERE (state <> ''completed''::text)',
                       'CREATE INDEX profile_security_invalidation_cleanup_idx ON im_v2.profile_security_invalidation_outbox USING btree (completed_at, source_event_id) WHERE (state = ''completed''::text)'))
                AND EXISTS (SELECT 1 FROM pg_index WHERE indrelid=to_regclass(\(bind: schema + ".public_profile_update_outbox"))
                    AND indisvalid AND indisready AND replace(pg_get_indexdef(indexrelid),\(bind: schema + "."),'im_v2.') =
                      'CREATE INDEX public_profile_update_cleanup_idx ON im_v2.public_profile_update_outbox USING btree (created_at, publication_sequence)')
                AND EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid=to_regclass(\(bind: schema + ".public_profile_update_outbox"))
                    AND attname='publication_sequence' AND atttypid='bigint'::regtype AND attnotnull AND NOT attisdropped)
                AND EXISTS (SELECT 1 FROM pg_constraint c JOIN pg_index i ON i.indexrelid=c.conindid
                    WHERE c.conrelid=to_regclass(\(bind: schema + ".public_profile_update_outbox")) AND c.contype='u'
                      AND pg_get_constraintdef(c.oid)='UNIQUE (publication_sequence)' AND i.indisvalid AND i.indisready)
                AND (SELECT count(*)=2 FROM pg_attribute WHERE attrelid=to_regclass(\(bind: schema + ".author_presentation_change_head"))
                    AND attnum>0 AND NOT attisdropped AND attnotnull
                    AND ((attname='singleton' AND atttypid='boolean'::regtype) OR (attname='sequence' AND atttypid='bigint'::regtype)))
                AND (SELECT count(*)=3 FROM pg_constraint WHERE conrelid=to_regclass(\(bind: schema + ".author_presentation_change_head"))
                    AND pg_get_constraintdef(oid) IN ('PRIMARY KEY (singleton)','CHECK (singleton)','CHECK ((sequence >= 0))'))
                AND EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid
                    WHERE t.tgrelid=to_regclass(\(bind: schema + ".public_profile_update_outbox")) AND t.tgname='public_profile_update_sequence'
                      AND t.tgenabled='O' AND NOT t.tgisinternal AND t.tgtype=7 AND t.tgqual IS NULL
                      AND p.pronamespace=to_regnamespace(\(bind: schema)) AND p.proname='sequence_public_profile_update'
                      AND p.pronargs=0 AND p.prorettype='trigger'::regtype AND NOT p.prosecdef
                      AND p.proconfig=ARRAY[\(bind: "search_path=pg_catalog, " + schema)]
                      AND encode(sha256(convert_to(replace(p.prosrc,\(bind: schema + "."),'im_v2.'),'UTF8')),'hex')='41054a10c68f0a1d937826a14bcbf9d426bf8633219ce1d192d8d27b244d25cc')
                AND EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid
                    WHERE t.tgrelid=to_regclass(\(bind: schema + ".group_join_requests")) AND t.tgname='group_join_review_authority'
                      AND t.tgenabled='O' AND NOT t.tgisinternal AND t.tgtype=29 AND t.tgqual IS NULL
                      AND NOT t.tgdeferrable AND NOT t.tginitdeferred AND t.tgattr=''::int2vector
                      AND p.pronamespace=to_regnamespace(\(bind: schema)) AND p.proname='advance_group_join_review_authority'
                      AND p.pronargs=0 AND p.prorettype='trigger'::regtype AND p.provolatile='v' AND NOT p.prosecdef
                      AND p.proconfig=ARRAY[\(bind: "search_path=pg_catalog, " + schema)]
                      AND encode(sha256(convert_to(replace(p.prosrc,\(bind: schema + "."),'im_v2.'),'UTF8')),'hex')='1f9e3ff9b37bbed027c37a530ad8e131481329d43dd0883020caafee26786f68')
                AND (SELECT count(*)=6 FROM pg_attribute WHERE attrelid=to_regclass(\(bind: schema + ".author_presentation_control_changes"))
                    AND attnum>0 AND NOT attisdropped AND attnotnull
                    AND ((attname IN ('publication_sequence','revision') AND atttypid='bigint'::regtype)
                      OR (attname IN ('owner_user_id','target_user_id') AND atttypid='uuid'::regtype)
                      OR (attname='kind' AND atttypid='text'::regtype)
                      OR (attname='created_at' AND atttypid='timestamptz'::regtype)))
                AND (SELECT count(*)=6 FROM pg_constraint WHERE conrelid=to_regclass(\(bind: schema + ".author_presentation_control_changes"))
                    AND convalidated AND NOT condeferrable AND pg_get_constraintdef(oid) IN
                    ('PRIMARY KEY (publication_sequence)','CHECK ((publication_sequence > 0))','CHECK ((revision > 0))',
                     'CHECK (isfinite(created_at))','CHECK ((owner_user_id <> target_user_id))',
                     'CHECK ((kind = ANY (ARRAY[''contact_alias''::text, ''relationship''::text, ''user_block''::text])))'))
                AND EXISTS (SELECT 1 FROM pg_index WHERE indrelid=to_regclass(\(bind: schema + ".author_presentation_control_changes"))
                    AND indisvalid AND indisready AND replace(pg_get_indexdef(indexrelid),\(bind: schema + "."),'im_v2.') =
                      'CREATE INDEX author_presentation_control_changes_cleanup_idx ON im_v2.author_presentation_control_changes USING btree (created_at, publication_sequence)')
                AND (SELECT count(*)=3 FROM (VALUES
                    ('user_contact_aliases','contact_alias_presentation_change','capture_contact_alias_presentation_change','d3b1965f81b79af4fb7107efca3d73ca896dbdb5a45a91227d8b0db6a4d03b8a'),
                    ('social_relationship_revisions','relationship_presentation_change','capture_social_presentation_change','051804cab55b7a849a157fdc787472a4b21caaff9077dc4c9016f474132a0039'),
                    ('social_block_revisions','user_block_presentation_change','capture_social_presentation_change','051804cab55b7a849a157fdc787472a4b21caaff9077dc4c9016f474132a0039')
                    ) expected(table_name,trigger_name,function_name,body_hash)
                    JOIN pg_trigger t ON t.tgrelid=to_regclass(\(bind: schema + ".")||expected.table_name) AND t.tgname=expected.trigger_name
                    JOIN pg_proc p ON p.oid=t.tgfoid
                    WHERE t.tgenabled='O' AND NOT t.tgisinternal AND t.tgtype=21 AND t.tgqual IS NULL
                      AND t.tgdeferrable AND t.tginitdeferred AND t.tgattr=''::int2vector
                      AND p.pronamespace=to_regnamespace(\(bind: schema)) AND p.proname=expected.function_name
                      AND p.pronargs=0 AND p.prorettype='trigger'::regtype AND p.provolatile='v' AND NOT p.prosecdef
                      AND p.proconfig=ARRAY[\(bind: "search_path=pg_catalog, " + schema)]
                      AND encode(sha256(convert_to(replace(p.prosrc,\(bind: schema + "."),'im_v2.'),'UTF8')),'hex')=expected.body_hash)
                AND EXISTS (SELECT 1 FROM pg_proc p WHERE p.pronamespace=to_regnamespace(\(bind: schema))
                    AND p.proname='append_author_presentation_control_change'
                    AND p.proargtypes=ARRAY['text'::regtype,'uuid'::regtype,'uuid'::regtype,'bigint'::regtype]::oidvector
                    AND p.prorettype='void'::regtype AND p.provolatile='v' AND NOT p.prosecdef
                    AND p.proconfig=ARRAY[\(bind: "search_path=pg_catalog, " + schema)]
                    AND encode(sha256(convert_to(replace(p.prosrc,\(bind: schema + "."),'im_v2.'),'UTF8')),'hex')='fd476093685b6dab485ce234a34dd3b3603c37864b726a06accfad68df43027b')
            ) AS valid
            """).first(decoding: Row.self), row.valid else {
            throw V2SchemaReadinessError.unavailableTable(schema + ".public_profile_update_outbox.publication")
        }
    }
}
