-- Controlled schema-28 migration. Drain credential writers before applying.
-- Existing server-minted session capabilities remain valid. This adds the
-- pre-issuance cancellation journal; transport/client cutover is separate.
BEGIN;
DO $$ BEGIN
    IF (SELECT count(*) FROM im_v2.schema_contract WHERE schema_id = 'im-v2-current-28') <> 1 THEN
        RAISE EXCEPTION 'expected current-28 before registration cancellation migration';
    END IF;
END $$;
CREATE TABLE im_v2.device_registration_cancellations (
    request_digest text PRIMARY KEY,
    device_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    issue_before timestamptz NOT NULL,
    created_at timestamptz NOT NULL,
    cancelled_at timestamptz,
    user_id uuid,
    session_created_at timestamptz,
    session_expires_at timestamptz,
    CONSTRAINT registration_cancellation_digest CHECK (request_digest ~ '^[0-9a-f]{64}$'),
    CONSTRAINT registration_cancellation_times CHECK (
        isfinite(created_at) AND isfinite(issue_before) AND issue_before > created_at
        AND issue_before <= created_at + interval '1 day'
        AND (cancelled_at IS NULL OR isfinite(cancelled_at))),
    CONSTRAINT registration_cancellation_binding CHECK (
        (user_id IS NULL AND session_created_at IS NULL AND session_expires_at IS NULL AND cancelled_at IS NOT NULL)
        OR (user_id IS NOT NULL AND session_created_at IS NOT NULL AND session_expires_at IS NOT NULL
            AND isfinite(session_created_at) AND isfinite(session_expires_at) AND session_expires_at > session_created_at)),
    CONSTRAINT registration_cancellation_device FOREIGN KEY (user_id, device_id)
        REFERENCES im_v2.auth_devices (user_id, device_id) ON DELETE RESTRICT
);
CREATE UNIQUE INDEX registration_cancellation_issued_device_idx ON im_v2.device_registration_cancellations (device_id) WHERE user_id IS NOT NULL;
CREATE INDEX registration_cancellation_pending_expiry_idx ON im_v2.device_registration_cancellations (issue_before) WHERE user_id IS NULL;

ALTER TABLE im_v2.schema_contract DROP CONSTRAINT schema_contract_schema_id_check;
ALTER TABLE im_v2.schema_contract ALTER COLUMN schema_id SET DEFAULT 'im-v2-current-29';
UPDATE im_v2.schema_contract SET schema_id = 'im-v2-current-29';
ALTER TABLE im_v2.schema_contract ADD CONSTRAINT schema_contract_schema_id_check CHECK (schema_id = 'im-v2-current-29');
COMMIT;
