-- Stop old account-edge writers before installing the push intent contract.
BEGIN;
DO $$ BEGIN
    IF (SELECT count(*) FROM im_v2.schema_contract WHERE schema_id = 'im-v2-current-18') <> 1 THEN
        RAISE EXCEPTION 'expected current-18 before push intent migration';
    END IF;
END $$;
CREATE TABLE im_v2.push_device_intents (
    device_id uuid PRIMARY KEY REFERENCES im_v2.auth_devices(device_id) ON DELETE RESTRICT,
    session_epoch bigint NOT NULL CHECK (session_epoch > 0),
    session_claim_id uuid NOT NULL,
    intent_revision bigint NOT NULL CHECK (intent_revision >= 0),
    intent_digest bytea,
    updated_at timestamp with time zone NOT NULL,
    CONSTRAINT push_device_intents_digest_check CHECK (
        (intent_revision = 0 AND intent_digest IS NULL)
        OR (intent_revision > 0 AND intent_digest IS NOT NULL AND octet_length(intent_digest) = 32)
    )
);

ALTER TABLE im_v2.schema_contract DROP CONSTRAINT schema_contract_schema_id_check;
ALTER TABLE im_v2.schema_contract ALTER COLUMN schema_id SET DEFAULT 'im-v2-current-19';
UPDATE im_v2.schema_contract SET schema_id = 'im-v2-current-19';
ALTER TABLE im_v2.schema_contract ADD CONSTRAINT schema_contract_schema_id_check CHECK (schema_id = 'im-v2-current-19');
COMMIT;
