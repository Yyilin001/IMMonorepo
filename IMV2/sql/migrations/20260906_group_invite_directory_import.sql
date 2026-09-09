-- Install on control and every room owner before enabling the importer.
-- Drain legacy invitation writers before paging historical links. New routed
-- writers always publish their own directory; UUID pagination is not a snapshot
-- of concurrent legacy inserts. No owner links or control bindings are rewritten.
BEGIN;
DO $$ BEGIN
    IF (SELECT count(*) FROM im_v2.schema_contract WHERE schema_id = 'im-v2-current-24') <> 1 THEN
        RAISE EXCEPTION 'expected current-24 before invite directory import migration';
    END IF;
END $$;
CREATE TABLE im_v2.group_invite_directory_import_audit (
    operation_id uuid PRIMARY KEY,
    operator_principal text NOT NULL,
    shard_id text NOT NULL,
    owner_epoch bigint NOT NULL,
    room_id uuid NOT NULL,
    after_invite_id uuid,
    page_size bigint NOT NULL,
    reason_code text NOT NULL,
    requested_at timestamptz NOT NULL,
    outcome text NOT NULL,
    source_snapshot jsonb NOT NULL,
    source_digest bytea NOT NULL,
    source_count bigint NOT NULL,
    inserted_count bigint NOT NULL,
    published_count bigint NOT NULL,
    unchanged_count bigint NOT NULL,
    next_cursor uuid,
    conflicting_invite_ids uuid[] NOT NULL,
    CONSTRAINT group_invite_import_principal_check CHECK (operator_principal ~ '^[A-Za-z0-9_.:-]{1,128}$'),
    CONSTRAINT group_invite_import_shard_check CHECK (octet_length(shard_id) BETWEEN 1 AND 128 AND shard_id = btrim(shard_id)),
    CONSTRAINT group_invite_import_epoch_check CHECK (owner_epoch >= 0),
    CONSTRAINT group_invite_import_page_check CHECK (page_size BETWEEN 1 AND 100),
    CONSTRAINT group_invite_import_reason_check CHECK (reason_code IN ('dependency_recovered','data_repaired','false_positive')),
    CONSTRAINT group_invite_import_outcome_check CHECK (outcome IN ('applied','conflict')),
    CONSTRAINT group_invite_import_snapshot_check CHECK (jsonb_typeof(source_snapshot) = 'array' AND jsonb_array_length(source_snapshot) = source_count AND source_count BETWEEN 0 AND page_size),
    CONSTRAINT group_invite_import_digest_check CHECK (source_digest = sha256(convert_to(source_snapshot::text, 'UTF8'))),
    CONSTRAINT group_invite_import_counts_check CHECK (
        inserted_count >= 0 AND published_count >= 0 AND unchanged_count >= 0
        AND ((outcome = 'applied' AND inserted_count + published_count + unchanged_count = source_count AND cardinality(conflicting_invite_ids) = 0)
          OR (outcome = 'conflict' AND inserted_count = 0 AND published_count = 0 AND unchanged_count = 0 AND cardinality(conflicting_invite_ids) BETWEEN 1 AND source_count))),
    CONSTRAINT group_invite_import_cursor_check CHECK (next_cursor IS NULL OR (source_count = page_size AND next_cursor = (source_snapshot->-1->>'invite_id')::uuid))
);
CREATE FUNCTION im_v2.reject_group_invite_import_audit_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'invite directory import audit is immutable';
END;
$$;
CREATE TRIGGER group_invite_import_audit_immutable BEFORE UPDATE OR DELETE ON im_v2.group_invite_directory_import_audit
    FOR EACH ROW EXECUTE FUNCTION im_v2.reject_group_invite_import_audit_mutation();
CREATE INDEX group_invite_links_import_page_idx ON im_v2.group_invite_links (room_id, invite_id);
ALTER TABLE im_v2.schema_contract DROP CONSTRAINT schema_contract_schema_id_check;
ALTER TABLE im_v2.schema_contract ALTER COLUMN schema_id SET DEFAULT 'im-v2-current-25';
UPDATE im_v2.schema_contract SET schema_id = 'im-v2-current-25';
ALTER TABLE im_v2.schema_contract ADD CONSTRAINT schema_contract_schema_id_check CHECK (schema_id = 'im-v2-current-25');
COMMIT;
