-- Controlled schema-26 test-data migration; drain writers before applying.
-- Existing credentials are unchanged. Capability issuance is wired separately.
BEGIN;
DO $$ BEGIN
    IF (SELECT count(*) FROM im_v2.schema_contract WHERE schema_id = 'im-v2-current-26') <> 1 THEN
        RAISE EXCEPTION 'expected current-26 before device revocation capability migration';
    END IF;
END $$;
CREATE TABLE im_v2.device_revocation_capabilities (
    device_id uuid PRIMARY KEY,
    user_id uuid NOT NULL,
    credential_digest text NOT NULL UNIQUE,
    session_created_at timestamptz NOT NULL,
    session_expires_at timestamptz NOT NULL,
    expires_at timestamptz NOT NULL,
    CONSTRAINT device_revocation_capability_device FOREIGN KEY (user_id, device_id)
        REFERENCES im_v2.auth_devices (user_id, device_id) ON DELETE CASCADE,
    CONSTRAINT device_revocation_capability_digest CHECK (credential_digest ~ '^[0-9a-f]{64}$'),
    CONSTRAINT device_revocation_capability_expiry CHECK (
        isfinite(session_created_at) AND isfinite(session_expires_at) AND isfinite(expires_at)
        AND session_expires_at > session_created_at
        AND expires_at = session_expires_at + interval '10 minutes')
);

ALTER TABLE im_v2.schema_contract DROP CONSTRAINT schema_contract_schema_id_check;
ALTER TABLE im_v2.schema_contract ALTER COLUMN schema_id SET DEFAULT 'im-v2-current-27';
UPDATE im_v2.schema_contract SET schema_id = 'im-v2-current-27';
ALTER TABLE im_v2.schema_contract ADD CONSTRAINT schema_contract_schema_id_check CHECK (schema_id = 'im-v2-current-27');
COMMIT;
